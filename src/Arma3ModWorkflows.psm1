$corePath = Join-Path $PSScriptRoot 'Core'
foreach ($file in @('Logging.ps1','Configuration.ps1','ModuleManager.ps1','Initialize.ps1')) {
    $path = Join-Path $corePath $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Arma3-Mod-Workflows core file is missing: $path"
    }
    . $path
}

Export-ModuleMember -Function @(
    'Initialize-A3Workflow',
    'New-A3WorkflowLogger',
    'Write-A3WorkflowLog',
    'Read-A3WorkflowConfigurationFile',
    'Test-A3WorkflowConfiguration',
    'Get-A3WorkflowConfiguration',
    'Merge-A3WorkflowConfiguration',
    'New-A3WorkflowModuleRegistry',
    'Register-A3WorkflowModule',
    'Import-A3WorkflowModules',
    'Resolve-A3WorkflowModuleOrder',
    'New-A3WorkflowModuleResult',
    'Invoke-A3WorkflowModules'
)
