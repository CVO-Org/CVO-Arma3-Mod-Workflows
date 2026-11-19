function Merge-A3WorkflowConfiguration {
 [CmdletBinding()]
 param([hashtable]$Base,[hashtable]$Override)
 $merged=@{}
 if($Base){foreach($key in $Base.Keys){$merged[$key]=$Base[$key]}}
 if($Override){foreach($key in $Override.Keys){if($merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]){$merged[$key]=Merge-A3WorkflowConfiguration -Base $merged[$key] -Override $Override[$key]}else{$merged[$key]=$Override[$key]}}}
 return ,$merged
}
function ConvertTo-A3WorkflowHashtable {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)]$InputObject)
 if($InputObject -is [System.Collections.IDictionary]){$result=@{};foreach($key in $InputObject.Keys){$result[[string]$key]=ConvertTo-A3WorkflowValue $InputObject[$key]};return ,$result}
 if($InputObject -is [pscustomobject]){$result=@{};foreach($property in $InputObject.PSObject.Properties){$result[$property.Name]=ConvertTo-A3WorkflowValue $property.Value};return ,$result}
 return $InputObject
}
function ConvertTo-A3WorkflowValue { param($Value)
 if($null -eq $Value){return $null}
 if($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]){return ConvertTo-A3WorkflowHashtable $Value}
 if($Value -is [System.Array]){$items=@();foreach($item in $Value){$items+=,(ConvertTo-A3WorkflowValue $item)};return ,$items}
 return $Value
}
function Read-A3WorkflowConfigurationFile {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Path)
 $extension=[IO.Path]::GetExtension($Path).ToLowerInvariant();$raw=Get-Content -LiteralPath $Path -Raw
 switch($extension){
  '.json'{try{return ConvertTo-A3WorkflowHashtable (ConvertFrom-Json -InputObject $raw -ErrorAction Stop)}catch{throw "Invalid configuration JSON: $($_.Exception.Message)"}}
  {$_ -in '.yml','.yaml'}{if(-not(Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)){throw "YAML requires powershell-yaml. Install with Install-Module powershell-yaml -Scope CurrentUser"};try{return ConvertTo-A3WorkflowHashtable (ConvertFrom-Yaml -Yaml $raw -ErrorAction Stop)}catch{throw "Invalid configuration YAML: $($_.Exception.Message)"}}
  default{throw "Unsupported configuration extension '$extension'."}
 }
}
function Resolve-A3WorkflowSchemaReference {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)]$Schema,[Parameter(Mandatory=$true)][string]$Reference)
 if($Reference -notmatch '^#/(.+)$'){throw "Unsupported JSON Schema reference '$Reference'."}
 $node=$Schema
 foreach($part in $Matches[1].Split('/')){$key=$part.Replace('~1','/').Replace('~0','~');if($node -is [System.Collections.IDictionary]){$node=$node[$key]}else{$node=$node.PSObject.Properties[$key].Value}}
 return $node
}
function Test-A3WorkflowSchemaNode {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)]$Rule,[Parameter(Mandatory=$true)]$RootSchema,[string]$Path='$')
 $errors=New-Object System.Collections.Generic.List[string]
 if($Rule -is [System.Collections.IDictionary] -and $Rule.ContainsKey('$ref')){$Rule=Resolve-A3WorkflowSchemaReference -Schema $RootSchema -Reference ([string]$Rule['$ref'])}
 $types=@();if($Rule.type -is [array]){$types=@($Rule.type)}elseif($Rule.type){$types=@([string]$Rule.type)}
 if($types.Count -gt 0){
  $matchesType=$false
  foreach($type in $types){switch([string]$type){
   'object' {if($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]){$matchesType=$true}}
   'array' {if($Value -is [array]){$matchesType=$true}}
   'string' {if($Value -is [string]){$matchesType=$true}}
   'integer' {if(($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [long]) -or ($Value -is [double] -and [math]::Truncate($Value) -eq $Value)){$matchesType=$true}}
   'number' {if($Value -is [ValueType] -and $Value -isnot [bool] -and $Value -isnot [datetime]){$matchesType=$true}}
   'boolean' {if($Value -is [bool]){$matchesType=$true}}
   'null' {if($null -eq $Value){$matchesType=$true}}
  }}
  if(-not $matchesType){$errors.Add("$Path must be of type $($types -join ' or ').");return @($errors.ToArray())}
 }
 if($Rule.ContainsKey('const') -and $Value -cne $Rule.const){$errors.Add("$Path must equal '$($Rule.const)'.")}
 if($Rule.enum -and $Value -notin @($Rule.enum)){$errors.Add("$Path must be one of: $(@($Rule.enum) -join ', ').")}
 if($Value -is [string]){
  if($Rule.minLength -and $Value.Length -lt [int]$Rule.minLength){$errors.Add("$Path must contain at least $($Rule.minLength) characters.")}
  if($Rule.pattern -and $Value -notmatch [string]$Rule.pattern){$errors.Add("$Path does not match the required pattern.")}
 }
 if(($Value -is [ValueType]) -and $Value -isnot [bool] -and $Value -isnot [datetime]){
  if($Rule.ContainsKey('minimum') -and [double]$Value -lt [double]$Rule.minimum){$errors.Add("$Path must be greater than or equal to $($Rule.minimum).")}
  if($Rule.ContainsKey('maximum') -and [double]$Value -gt [double]$Rule.maximum){$errors.Add("$Path must be less than or equal to $($Rule.maximum).")}
 }
 if($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]){
  $map=ConvertTo-A3WorkflowHashtable $Value
  foreach($required in @($Rule.required)){if($required -and -not $map.ContainsKey([string]$required)){$errors.Add("$Path is missing required property '$required'.")}}
  $properties=@{};if($Rule.properties){$properties=ConvertTo-A3WorkflowHashtable $Rule.properties}
  foreach($key in $map.Keys){
   if($properties.ContainsKey([string]$key)){$childErrors=Test-A3WorkflowSchemaNode -Value $map[$key] -Rule $properties[$key] -RootSchema $RootSchema -Path "$Path.$key";foreach($e in $childErrors){$errors.Add($e)}}
   elseif($Rule.additionalProperties -eq $false){$errors.Add("$Path contains unknown property '$key'.")}
   elseif($Rule.additionalProperties -is [System.Collections.IDictionary]){$childErrors=Test-A3WorkflowSchemaNode -Value $map[$key] -Rule $Rule.additionalProperties -RootSchema $RootSchema -Path "$Path.$key";foreach($e in $childErrors){$errors.Add($e)}}
  }
 }
 if($Value -is [array] -and $Rule.items){for($i=0;$i -lt $Value.Count;$i++){$childErrors=Test-A3WorkflowSchemaNode -Value $Value[$i] -Rule $Rule.items -RootSchema $RootSchema -Path "$Path[$i]";foreach($e in $childErrors){$errors.Add($e)}}}
 return @($errors.ToArray())
}
function Test-A3WorkflowConfiguration {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)][hashtable]$Configuration,[string]$SchemaPath)
 if(-not $SchemaPath){$SchemaPath=Join-Path $PSScriptRoot '..\..\config\schema\arma3-workflows.schema.json'}
 $errors=New-Object System.Collections.Generic.List[string]
 if(-not(Test-Path -LiteralPath $SchemaPath -PathType Leaf)){$errors.Add("Configuration schema not found: $SchemaPath")}
 else{try{$schema=ConvertTo-A3WorkflowHashtable (ConvertFrom-Json -InputObject (Get-Content -LiteralPath $SchemaPath -Raw) -ErrorAction Stop);$schemaErrors=Test-A3WorkflowSchemaNode -Value $Configuration -Rule $schema -RootSchema $schema;foreach($e in $schemaErrors){$errors.Add($e)}}catch{$errors.Add("Schema validation could not be completed: $($_.Exception.Message)")}}
 [pscustomobject]@{IsValid=($errors.Count -eq 0);Errors=@($errors.ToArray())}
}
function Get-A3WorkflowConfiguration {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$ProjectRoot,[string]$ConfigPath)
 $root=(Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
 if(-not $ConfigPath){foreach($name in @('arma3-workflows.yml','arma3-workflows.yaml','arma3-workflows.json')){$candidate=Join-Path $root $name;if(Test-Path -LiteralPath $candidate -PathType Leaf){$ConfigPath=$candidate;break}}}elseif(-not [IO.Path]::IsPathRooted($ConfigPath)){$ConfigPath=Join-Path $root $ConfigPath}
 if(-not $ConfigPath -or -not(Test-Path -LiteralPath $ConfigPath -PathType Leaf)){throw "No configuration file found in '$root'."}
 $resolved=(Resolve-Path -LiteralPath $ConfigPath).Path;$values=Read-A3WorkflowConfigurationFile -Path $resolved;$validation=Test-A3WorkflowConfiguration -Configuration $values
 if(-not $validation.IsValid){throw ("Configuration validation failed: " + ($validation.Errors -join '; '))}
 [pscustomobject]@{ProjectRoot=$root;ConfigPath=$resolved;Values=$values}
}
