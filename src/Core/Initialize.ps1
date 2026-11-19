function Initialize-A3Workflow {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)][string]$ProjectRoot,[string]$ConfigPath,[string]$FrameworkRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,[switch]$EnableConsoleLog)
 foreach($file in @('Logging.ps1','Configuration.ps1','ModuleManager.ps1')){$component=Join-Path $PSScriptRoot $file;if(-not(Test-Path -LiteralPath $component -PathType Leaf)){throw "Missing core component: $component"};. $component}
 $loaded=Get-A3WorkflowConfiguration -ProjectRoot $ProjectRoot -ConfigPath $ConfigPath
 $defaultsPath=Join-Path $FrameworkRoot 'config/defaults/configuration.json'
 if(Test-Path -LiteralPath $defaultsPath -PathType Leaf){$defaults=Read-A3WorkflowConfigurationFile -Path $defaultsPath;$loaded.Values=Merge-A3WorkflowConfiguration -Base $defaults -Override $loaded.Values}
 $reportDir='.arma3-workflows/reports';if($loaded.Values.paths -is [hashtable] -and $loaded.Values.paths.report_output){$reportDir=[string]$loaded.Values.paths.report_output}
 if(-not [IO.Path]::IsPathRooted($reportDir)){$reportDir=Join-Path $loaded.ProjectRoot $reportDir}
 $logger=New-A3WorkflowLogger -LogPath (Join-Path $reportDir 'framework.log') -MinimumLevel Info -Console:$EnableConsoleLog
 $registry=New-A3WorkflowModuleRegistry
 $context=[pscustomobject]@{ProjectRoot=$loaded.ProjectRoot;FrameworkRoot=(Resolve-Path -LiteralPath $FrameworkRoot -ErrorAction Stop).Path;FrameworkVersion='0.1.0-dev';Configuration=$loaded.Values;ConfigurationPath=$loaded.ConfigPath;Logger=$logger;Registry=$registry;ModuleDiscovery=$null;StartedAt=[DateTime]::UtcNow}
 Write-A3WorkflowLog -Logger $logger -Level Info -Message 'Framework initialized.' -Module Core -Data @{ProjectRoot=$context.ProjectRoot;ConfigurationPath=$context.ConfigurationPath;SchemaVersion=$loaded.Values.schema_version}
 $modulesRoot=Join-Path $context.FrameworkRoot 'src/Modules'
 $context.ModuleDiscovery=$null
 if(Test-Path -LiteralPath $modulesRoot -PathType Container){$context.ModuleDiscovery=Import-A3WorkflowModules -Registry $registry -ModulesRoot $modulesRoot -Configuration $context.Configuration -Logger $logger}
 return $context
}