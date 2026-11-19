[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ConfigPath,
    [string]$Operation = 'Run',
    [string[]]$Module,
    [switch]$ListModules,
    [switch]$EnableConsoleLog,
    [switch]$FailOnWarning
)

$ErrorActionPreference = 'Stop'

try {
    $manifestPath = Join-Path $PSScriptRoot 'Arma3ModWorkflows.psd1'
    Import-Module $manifestPath -Force -ErrorAction Stop

    $frameworkRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $context = Initialize-A3Workflow -ProjectRoot $ProjectRoot -ConfigPath $ConfigPath -FrameworkRoot $frameworkRoot -EnableConsoleLog:$EnableConsoleLog

    if ($ListModules) {
        foreach ($item in ($context.Registry.Modules.Values | Sort-Object Id)) {
            [pscustomobject]@{
                Id = $item.Id
                Version = $item.Version
                ConfigKey = $item.ConfigKey
                Operations = @($item.Operations)
                DependsOn = @($item.DependsOn)
            }
        }
        exit 0
    }

    $results = Invoke-A3WorkflowModules -Registry $context.Registry -Context $context -Operation $Operation -ModuleIds $Module
    $results | ConvertTo-Json -Depth 12

    $failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0
    $warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count -gt 0
    if ($failed -or ($FailOnWarning -and $warnings)) {
        exit 1
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.ToString())
    exit 2
}
