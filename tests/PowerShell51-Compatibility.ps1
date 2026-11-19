$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("A3Workflow-PS51-" + [guid]::NewGuid().ToString('N'))
$toolDirectory = Join-Path $projectRoot 'tools'
$hemttDirectory = Join-Path $projectRoot '.hemtt'

try {
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $hemttDirectory -Force | Out-Null

    @'
if ($args -contains '--version') {
    Write-Output 'HEMTT v1.2.3'
    exit 0
}
if ($args -contains 'build') {
    Write-Output 'Mock HEMTT build passed.'
    exit 0
}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $toolDirectory 'hemtt.ps1') -Encoding UTF8

    'name = "PS51Compatibility"' | Set-Content -LiteralPath (Join-Path $hemttDirectory 'project.toml') -Encoding UTF8
    @{
        schema_version = 1
        tools = @{
            hemtt = @{
                path = 'tools/hemtt.ps1'
                version = '1.2.3'
                required = $true
            }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $projectRoot 'arma3-workflows.json') -Encoding UTF8

    Import-Module (Join-Path $repositoryRoot 'src/Arma3ModWorkflows.psd1') -Force
    $context = Initialize-A3Workflow -ProjectRoot $projectRoot -FrameworkRoot $repositoryRoot

    foreach ($operation in @('Detect', 'Build')) {
        $results = @(Invoke-A3WorkflowModules -Registry $context.Registry -Context $context -Operation $operation -ModuleIds @('Build.HEMTT'))
        if ($results.Count -ne 1 -or $results[0].Status -ne 'Passed') {
            $details = if ($results.Count -gt 0) { $results[0] | ConvertTo-Json -Depth 10 } else { 'No module result returned.' }
            throw "PowerShell 5.1 compatibility check failed for $operation. $details"
        }
    }

    Write-Output 'Windows PowerShell 5.1 compatibility check passed.'
}
finally {
    Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
}
