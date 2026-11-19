@{
    RootModule = 'Arma3ModWorkflows.psm1'
    ModuleVersion = '0.1.0'
    GUID = '8f1c74b9-1d4e-4b30-ae92-2e0d77a3c1f6'
    Author = 'SkippieDippie'
    Description = 'Reusable PowerShell core for Arma 3 mod development workflows.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
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
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Arma3','Arma','PowerShell','Modding','HEMTT')
            ProjectUri = 'https://github.com/SkippieDippie/Arma3-Mod-Workflows'
        }
    }
}
