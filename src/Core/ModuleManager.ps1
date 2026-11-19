function New-A3WorkflowModuleRegistry { [CmdletBinding()] param() [pscustomobject]@{Modules=@{}} }
function Register-A3WorkflowModule {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)]$Registry,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)][scriptblock]$Invoke,[string[]]$DependsOn=@(),[string[]]$Operations=@('Run'),[string]$Version='0.1.0',[string]$ConfigKey)
 if($Registry.Modules.ContainsKey($Id)){throw "Module '$Id' is already registered."}
 if($Id -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$'){throw "Invalid module identifier '$Id'."}
 if($Operations.Count -eq 0 -or @($Operations | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0){throw "Module '$Id' must declare at least one non-empty operation."}
 $Registry.Modules[$Id]=[pscustomobject]@{Id=$Id;Version=$Version;DependsOn=@($DependsOn);Operations=@($Operations);ConfigKey=$ConfigKey;Invoke=$Invoke}
}
function Import-A3WorkflowModules {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)]$Registry,[Parameter(Mandatory=$true)][string]$ModulesRoot,[Parameter(Mandatory=$true)][hashtable]$Configuration,[object]$Logger)
 if(-not(Test-Path -LiteralPath $ModulesRoot -PathType Container)){return [pscustomobject]@{Registered=@();Skipped=@();Discovered=0}}
 $registered=New-Object System.Collections.Generic.List[string]
 $skipped=New-Object System.Collections.Generic.List[object]
 $moduleFiles=@(Get-ChildItem -LiteralPath $ModulesRoot -Directory | Sort-Object Name | ForEach-Object { Join-Path $_.FullName 'Module.ps1' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
 foreach($moduleFile in $moduleFiles){
  $descriptor=& $moduleFile
  if($descriptor -isnot [System.Collections.IDictionary]){throw "Module descriptor '$moduleFile' must return a hashtable."}
  foreach($required in @('Id','Invoke','ConfigKey')){if(-not $descriptor.Contains($required)){throw "Module descriptor '$moduleFile' is missing '$required'."}}
  if($descriptor.Invoke -isnot [scriptblock]){throw "Module '$($descriptor.Id)' must provide an Invoke scriptblock."}
  if([string]$descriptor.ConfigKey -notmatch '^[A-Za-z][A-Za-z0-9_]*$'){throw "Module '$($descriptor.Id)' has invalid ConfigKey '$($descriptor.ConfigKey)'."}
  $enabled=$true
  if($Configuration.modules -is [hashtable] -and $Configuration.modules.ContainsKey([string]$descriptor.ConfigKey)){
   $setting=$Configuration.modules[[string]$descriptor.ConfigKey]
   if($setting -isnot [hashtable] -or ($setting.ContainsKey('enabled') -and $setting.enabled -isnot [bool])){throw "Configuration modules.$($descriptor.ConfigKey) must contain a boolean enabled property."}
   if($setting.ContainsKey('enabled')){$enabled=$setting.enabled}
  }
  if(-not $enabled){
   $skipped.Add([pscustomobject]@{Id=[string]$descriptor.Id;Reason="Disabled by configuration key modules.$($descriptor.ConfigKey).enabled"})
   if($Logger){Write-A3WorkflowLog -Logger $Logger -Level Info -Module ([string]$descriptor.Id) -Message 'Module disabled by configuration.'}
   continue
  }
  $dependsOn=@();if($descriptor.Contains('DependsOn')){$dependsOn=@($descriptor.DependsOn)}
  $operations=@('Run');if($descriptor.Contains('Operations')){$operations=@($descriptor.Operations)}
  $version='0.1.0';if($descriptor.Contains('Version')){$version=[string]$descriptor.Version}
  Register-A3WorkflowModule -Registry $Registry -Id ([string]$descriptor.Id) -Invoke $descriptor.Invoke -DependsOn $dependsOn -Operations $operations -Version $version -ConfigKey ([string]$descriptor.ConfigKey)
  $registered.Add([string]$descriptor.Id)
  if($Logger){Write-A3WorkflowLog -Logger $Logger -Level Info -Module ([string]$descriptor.Id) -Message 'Module discovered and registered.' -Data @{ConfigKey=$descriptor.ConfigKey;Version=$version}}
 }
 [pscustomobject]@{Registered=@($registered.ToArray());Skipped=@($skipped.ToArray());Discovered=$moduleFiles.Count}
}
function Resolve-A3WorkflowModuleOrder {
 [CmdletBinding()] param([Parameter(Mandatory=$true)]$Registry,[string[]]$ModuleIds)
 if(-not $ModuleIds){$ModuleIds=@($Registry.Modules.Keys)}
 $ordered=New-Object System.Collections.Generic.List[object];$state=@{}
 $visit={
  param([string]$Id)
  if(-not $Registry.Modules.ContainsKey($Id)){throw "Required module '$Id' is not registered."}
  if($state[$Id] -eq 'Visiting'){throw "Circular module dependency at '$Id'."}
  if($state[$Id] -eq 'Visited'){return}
  $state[$Id]='Visiting'
  foreach($dependency in $Registry.Modules[$Id].DependsOn){& $visit $dependency}
  $state[$Id]='Visited';$ordered.Add($Registry.Modules[$Id])
 }
 foreach($id in $ModuleIds){& $visit $id}
 return ,@($ordered.ToArray())
}
function New-A3WorkflowModuleResult {
 [CmdletBinding()]
 param([string]$Module,[string]$Operation,[ValidateSet('Passed','Warning','Failed','Skipped')][string]$Status,[string]$Summary,[object[]]$Errors=@(),[object[]]$Warnings=@(),[datetime]$StartedAt=[DateTime]::UtcNow,[long]$DurationMs=0,$Data)
 [pscustomobject]@{Module=$Module;Operation=$Operation;Status=$Status;Summary=$Summary;Errors=@($Errors);Warnings=@($Warnings);StartedAt=$StartedAt.ToString('o');DurationMs=$DurationMs;Data=$Data}
}
function Invoke-A3WorkflowModules {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)]$Registry,[Parameter(Mandatory=$true)]$Context,[string]$Operation='Run',[string[]]$ModuleIds)
 if(-not $ModuleIds){$ModuleIds=@($Registry.Modules.Keys)}
 $results=New-Object System.Collections.Generic.List[object];$moduleStatuses=@{};$modules=Resolve-A3WorkflowModuleOrder -Registry $Registry -ModuleIds $ModuleIds
 foreach($module in $modules){
  $failedDependency=$null
  foreach($dependency in $module.DependsOn){if($moduleStatuses[$dependency] -in @('Failed','Skipped')){$failedDependency=$dependency;break}}
  if($failedDependency){$moduleStatuses[$module.Id]='Skipped';$results.Add((New-A3WorkflowModuleResult -Module $module.Id -Operation $Operation -Status Skipped -Summary "Dependency '$failedDependency' did not complete successfully."));continue}
  if($Operation -notin $module.Operations){$moduleStatuses[$module.Id]='Skipped';$results.Add((New-A3WorkflowModuleResult -Module $module.Id -Operation $Operation -Status Skipped -Summary "Operation '$Operation' is unsupported."));continue}
  $started=[DateTime]::UtcNow
  try{$data=& $module.Invoke $Context $Operation;$elapsed=[long]([DateTime]::UtcNow-$started).TotalMilliseconds
   if($data -and $data.PSObject.Properties['Status']){$moduleStatuses[$module.Id]=$data.Status;$results.Add($data)}else{$moduleStatuses[$module.Id]='Passed';$results.Add((New-A3WorkflowModuleResult -Module $module.Id -Operation $Operation -Status Passed -Summary 'Module completed.' -StartedAt $started -DurationMs $elapsed -Data $data))}
  }catch{$elapsed=[long]([DateTime]::UtcNow-$started).TotalMilliseconds;$diagnostic=[pscustomobject]@{Message=$_.Exception.Message;Category=$_.CategoryInfo.Category.ToString()};$moduleStatuses[$module.Id]='Failed';$results.Add((New-A3WorkflowModuleResult -Module $module.Id -Operation $Operation -Status Failed -Summary 'Module execution failed.' -Errors @($diagnostic) -StartedAt $started -DurationMs $elapsed));if($Context.Logger){Write-A3WorkflowLog -Logger $Context.Logger -Level Error -Module $module.Id -Message $_.Exception.Message}}
 }
 return ,@($results.ToArray())
}
