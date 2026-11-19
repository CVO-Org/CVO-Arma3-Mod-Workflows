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
function Test-A3WorkflowConfiguration {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][hashtable]$Configuration)
 $errors=New-Object System.Collections.Generic.List[string]
 if(-not $Configuration.ContainsKey('schema_version')){$errors.Add("Missing required property 'schema_version'.")}elseif($Configuration.schema_version -ne 1){$errors.Add("Unsupported schema_version '$($Configuration.schema_version)'.")}
 $allowed=@('schema_version','project','paths','modules','tools','validation','testing','distribution')
 foreach($key in $Configuration.Keys){if($key -notin $allowed){$errors.Add("Unknown root property '$key'.")}}
 if($Configuration.ContainsKey('project') -and $null -ne $Configuration.project -and $Configuration.project -isnot [hashtable]){$errors.Add('project must be an object.')}
 if($Configuration.project -is [hashtable]){
  if($Configuration.project.ContainsKey('name') -and [string]::IsNullOrWhiteSpace([string]$Configuration.project.name)){$errors.Add('project.name must not be empty.')}
  if($Configuration.project.ContainsKey('version') -and [string]$Configuration.project.version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'){$errors.Add('project.version must be semantic version such as 1.2.3.')}
 }
 foreach($section in @('paths','modules','tools','validation','testing','distribution')){if($Configuration.ContainsKey($section) -and $null -ne $Configuration[$section] -and $Configuration[$section] -isnot [hashtable]){$errors.Add("$section must be an object.")}}
 foreach($section in @('modules','validation','testing')){if($Configuration[$section] -is [hashtable]){foreach($key in $Configuration[$section].Keys){$value=$Configuration[$section][$key];if($value -isnot [hashtable]){$errors.Add("$section.$key must be an object.")}elseif($value.ContainsKey('enabled') -and $value.enabled -isnot [bool]){$errors.Add("$section.$key.enabled must be boolean.")}}}}
 if($Configuration.distribution -is [hashtable]){foreach($target in @('github','steam')){if($Configuration.distribution[$target] -is [hashtable] -and $Configuration.distribution[$target].ContainsKey('enabled') -and $Configuration.distribution[$target].enabled -isnot [bool]){$errors.Add("distribution.$target.enabled must be boolean.")}}}
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