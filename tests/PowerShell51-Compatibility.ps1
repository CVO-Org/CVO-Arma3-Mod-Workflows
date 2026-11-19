$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("A3Workflow-PS51-" + [guid]::NewGuid().ToString('N'))
$toolDirectory = Join-Path $projectRoot 'tools'
$hemttDirectory = Join-Path $projectRoot '.hemtt'
$sqfDirectory = Join-Path $projectRoot 'addons/example'

try {
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $hemttDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $sqfDirectory -Force | Out-Null

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
    'systemChat "PS51 SQF-VM smoke test";' | Set-Content -LiteralPath (Join-Path $sqfDirectory 'init.sqf') -Encoding UTF8
    @'
if ($args -contains '--input-sqf' -and $args -contains '--automated') {
    Write-Output 'Mock SQF-VM parse passed.'
    exit 0
}
exit 9
'@ | Set-Content -LiteralPath (Join-Path $toolDirectory 'sqfvm.ps1') -Encoding UTF8
    @{
        schema_version = 1
        tools = @{
            hemtt = @{
                path = 'tools/hemtt.ps1'
                version = '1.2.3'
                required = $true
            }
            sqfvm = @{
                path = 'tools/sqfvm.ps1'
                required = $true
                timeout_seconds = 10
            }
        }
        validation = @{ sqf = @{ files = @('addons/example/init.sqf') } }
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

    $sqfResults = @(Invoke-A3WorkflowModules -Registry $context.Registry -Context $context -Operation Validate -ModuleIds @('Validation.SQF'))
    if ($sqfResults.Count -ne 1 -or $sqfResults[0].Status -ne 'Passed') {
        $details = if ($sqfResults.Count -gt 0) { $sqfResults[0] | ConvertTo-Json -Depth 10 } else { 'No module result returned.' }
        throw "PowerShell 5.1 SQF-VM compatibility check failed. $details"
    }

    $testDirectory = Join-Path $projectRoot 'tests'
    New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
    'exitcode__ 0;' | Set-Content -LiteralPath (Join-Path $testDirectory 'smoke.sqf') -Encoding UTF8
    $testContext = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ testing = @{ sqfvm = @{ files = @('tests/smoke.sqf') } }; tools = @{ sqfvm = @{ path = 'tools/sqfvm.ps1'; required = $true; timeout_seconds = 10 } } } }
    $testResults = @(Invoke-A3WorkflowModules -Registry $context.Registry -Context $testContext -Operation Test -ModuleIds @('Testing.SQFVM'))
    if ($testResults.Count -ne 1 -or $testResults[0].Status -ne 'Passed') {
        $details = if ($testResults.Count -gt 0) { $testResults[0] | ConvertTo-Json -Depth 10 } else { 'No module result returned.' }
        throw "PowerShell 5.1 SQF-VM test compatibility check failed. $details"
    }

    $releaseDirectory = Join-Path $projectRoot 'release'
    New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
    $pboBytes = New-Object 'System.Collections.Generic.List[byte]'
    $pboBytes.AddRange([Text.Encoding]::ASCII.GetBytes('config.cpp'))
    $pboBytes.Add([byte]0)
    $pboBytes.AddRange([byte[]](0,0,0,0))
    $pboBytes.AddRange([BitConverter]::GetBytes([uint32]3))
    $pboBytes.AddRange([byte[]](0,0,0,0))
    $pboBytes.AddRange([byte[]](0,0,0,0))
    $pboBytes.AddRange([BitConverter]::GetBytes([uint32]3))
    $pboBytes.Add([byte]0)
    $pboBytes.AddRange([byte[]](0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    $pboBytes.AddRange([Text.Encoding]::ASCII.GetBytes('abc'))
    [IO.File]::WriteAllBytes((Join-Path $releaseDirectory 'smoke.pbo'), $pboBytes.ToArray())
    $packageContext = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ package = @{ artifacts = @('release/smoke.pbo') } } } }
    $packageResults = @(Invoke-A3WorkflowModules -Registry $context.Registry -Context $packageContext -Operation Validate -ModuleIds @('Validation.Package'))
    if ($packageResults.Count -ne 1 -or $packageResults[0].Status -ne 'Passed') {
        $details = if ($packageResults.Count -gt 0) { $packageResults[0] | ConvertTo-Json -Depth 10 } else { 'No module result returned.' }
        throw "PowerShell 5.1 PBO package validation compatibility check failed. $details"
    }

    Write-Output 'Windows PowerShell 5.1 compatibility check passed.'
}
finally {
    Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
}
