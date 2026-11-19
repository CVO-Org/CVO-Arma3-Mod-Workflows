function New-A3WorkflowModuleRegistry { [CmdletBinding()] param() [pscustomobject]@{Modules=@{}} }
function Register-A3WorkflowModule {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)]$Registry,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)][scriptblock]$Invoke,[string[]]$DependsOn=@(),[string[]]$Operations=@('Run'),[string]$Version='0.1.0')
 if($Registry.Modules.ContainsKey($Id)){throw "Module '$Id' is already registered."}
 if($Id -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$'){throw "Invalid module identifier '$Id'."}
 $Registry.Modules[$Id]=[pscustomobject]@{Id=$Id;Version=$Version;DependsOn=@($DependsOn);Operations=@($Operations);Invoke=$Invoke}
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
 $results=New-Object System.Collections.Generic.List[object];$modules=Resolve-A3WorkflowModuleOrder -Registry $Registry -ModuleIds $ModuleIds
 foreach($module in $modules){
  if($Operation -notin $module.Operations){$results.Add((New-A3WorkflowModuleResult -Module $module.Id -Operation $Operation -Status Skipped -Summary "Operation '$Operation' is unsupported."));continue}
  $started=[DateTime]::UtcNow
  try{$data=& $module.Invoke $Context $Operation;$elapsed=[long]([DateTime]::UtcNow-$started).TotalMilliseconds
   if($data -and $data.PSObject.Properties['Status']){$results.Add($data)}else{$results.Add((New-A3WorkflowModuleResult -Module $module.Id -Operation $Operation -Status Passed -Summary 'Module completed.' -StartedAt $started -DurationMs $elapsed -Data $data))}
  }catch{$elapsed=[long]([DateTime]::UtcNow-$started).TotalMilliseconds;$diagnostic=[pscustomobject]@{Message=$_.Exception.Message;Category=$_.CategoryInfo.Category.ToString()};$results.Add((New-A3WorkflowModuleResult -Module $module.Id -Operation $Operation -Status Failed -Summary 'Module execution failed.' -Errors @($diagnostic) -StartedAt $started -DurationMs $elapsed));if($Context.Logger){Write-A3WorkflowLog -Logger $Context.Logger -Level Error -Module $module.Id -Message $_.Exception.Message}}
 }
 return ,@($results.ToArray())
}