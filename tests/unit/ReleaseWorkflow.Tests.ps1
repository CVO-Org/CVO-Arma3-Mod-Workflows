BeforeAll {
    $repositoryRoot = (Get-Location).Path
    $workflowPath = Join-Path $repositoryRoot '.github/workflows/release.yml'
    $workflow = Get-Content -LiteralPath $workflowPath -Raw
}

function Invoke-ReleaseValidationTest {
    param(
        [hashtable]$Environment
    )

    $lines = $workflow -split "\r?\n"
    $runIndex = [Array]::FindIndex($lines, [Predicate[string]]{
        param($line) $line -match '^      - name: Validate release configuration
    It 'validates release tag, Workshop ID, release folder, and destinations before publishing' {
        $validation = $workflow.Substring(0, $workflow.IndexOf('      - name: Set up HEMTT'))
        $validation | Should -Match 'RELEASE_TAG'
        $validation | Should -Match 'WORKSHOP_ID'
        $validation | Should -Match 'RELEASE_FOLDER'
        $validation | Should -Match 'At least one release destination'
        $validation | Should -Match 'STEAM_USERNAME and STEAM_PASSWORD'
    }

    It 'requires HEMTT output to contain at least one PBO before packaging' {
        $workflow | Should -Match "addons"
        $workflow.Contains('.pbo') | Should -BeTrue
        $workflow | Should -Match 'at least one PBO'
    }

    It 'creates a GitHub release draft before final publication' {
        $draftStep = $workflow.IndexOf('draft: true')
        $publishStep = $workflow.IndexOf('name: Publish GitHub Release')
        $draftStep | Should -BeGreaterThan -1
        $publishStep | Should -BeGreaterThan $draftStep
        $workflow.Contains("inputs['publish-github'] && inputs['finalize-github']") | Should -BeTrue
    }

    It 'preserves the release-folder root in the archive' {
        $workflow | Should -Match 'CreateFromDirectory'
        $workflow.Contains('$true') | Should -BeTrue
    }

    It 'verifies packaged ZIP file count and SHA-256 hashes against the release folder' {
        $workflow | Should -Match 'Get-FileHash.*SHA256'
        $workflow | Should -Match 'Archive file count mismatch'
        $workflow | Should -Match 'Archive hash mismatch'
        $workflow | Should -Match 'Unexpected archive entry'
        $workflow | Should -Match 'Archive integrity verified'
    }


    It 'only uploads to Steam when Steam publishing is enabled' {
        $workflow.Contains('if: ${{ inputs[''publish-steam''] }}') | Should -BeTrue
        $workflow | Should -Match 'workshop-upload@v1'
    }

    It 'does not contain a direct Steam publish step in the test workflow' {
        $testWorkflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-tests.yml') -Raw
        $testWorkflow | Should -Not -Match 'workshop-upload'
        $testWorkflow | Should -Not -Match 'Publish GitHub Release'
    }
}

    })
    if ($runIndex -lt 0) { throw 'Validation step not found.' }
    $runLine = $runIndex + 1
    while ($runLine -lt $lines.Count -and $lines[$runLine] -notmatch '^        run: \|
    It 'validates release tag, Workshop ID, release folder, and destinations before publishing' {
        $validation = $workflow.Substring(0, $workflow.IndexOf('      - name: Set up HEMTT'))
        $validation | Should -Match 'RELEASE_TAG'
        $validation | Should -Match 'WORKSHOP_ID'
        $validation | Should -Match 'RELEASE_FOLDER'
        $validation | Should -Match 'At least one release destination'
        $validation | Should -Match 'STEAM_USERNAME and STEAM_PASSWORD'
    }

    It 'requires HEMTT output to contain at least one PBO before packaging' {
        $workflow | Should -Match "addons"
        $workflow.Contains('.pbo') | Should -BeTrue
        $workflow | Should -Match 'at least one PBO'
    }

    It 'creates a GitHub release draft before final publication' {
        $draftStep = $workflow.IndexOf('draft: true')
        $publishStep = $workflow.IndexOf('name: Publish GitHub Release')
        $draftStep | Should -BeGreaterThan -1
        $publishStep | Should -BeGreaterThan $draftStep
        $workflow.Contains("inputs['publish-github'] && inputs['finalize-github']") | Should -BeTrue
    }

    It 'preserves the release-folder root in the archive' {
        $workflow | Should -Match 'CreateFromDirectory'
        $workflow.Contains('$true') | Should -BeTrue
    }

    It 'verifies packaged ZIP file count and SHA-256 hashes against the release folder' {
        $workflow | Should -Match 'Get-FileHash.*SHA256'
        $workflow | Should -Match 'Archive file count mismatch'
        $workflow | Should -Match 'Archive hash mismatch'
        $workflow | Should -Match 'Unexpected archive entry'
        $workflow | Should -Match 'Archive integrity verified'
    }


    It 'only uploads to Steam when Steam publishing is enabled' {
        $workflow.Contains('if: ${{ inputs[''publish-steam''] }}') | Should -BeTrue
        $workflow | Should -Match 'workshop-upload@v1'
    }

    It 'does not contain a direct Steam publish step in the test workflow' {
        $testWorkflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-tests.yml') -Raw
        $testWorkflow | Should -Not -Match 'workshop-upload'
        $testWorkflow | Should -Not -Match 'Publish GitHub Release'
    }
}
) { $runLine++ }
    if ($runLine -ge $lines.Count) { throw 'Validation run block not found.' }
    $scriptLines = New-Object System.Collections.Generic.List[string]
    for ($i = $runLine + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^      - name:'; $i++) {
        $scriptLines.Add($lines[$i].Substring([Math]::Min(10, $lines[$i].Length)))
    }
    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.ps1')
    Set-Content -LiteralPath $scriptPath -Value ($scriptLines -join "\n") -Encoding utf8
    $names = @('RELEASE_TAG','WORKSHOP_ID','WORKSHOP_NAME','RELEASE_FOLDER','PUBLISH_GITHUB','PUBLISH_STEAM','STEAM_USERNAME','STEAM_PASSWORD')
    $oldValues = @{}
    foreach ($name in $names) { $oldValues[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        foreach ($name in $names) {
            if ($Environment.ContainsKey($name)) { [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name]) }
            else { [Environment]::SetEnvironmentVariable($name, $null) }
        }
        $output = & pwsh -NoProfile -File $scriptPath 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $oldValues[$name]) }
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reusable release workflow safety' {
    It 'validates release tag, Workshop ID, release folder, and destinations before publishing' {
        $validation = $workflow.Substring(0, $workflow.IndexOf('      - name: Set up HEMTT'))
        $validation | Should -Match 'RELEASE_TAG'
        $validation | Should -Match 'WORKSHOP_ID'
        $validation | Should -Match 'RELEASE_FOLDER'
        $validation | Should -Match 'At least one release destination'
        $validation | Should -Match 'STEAM_USERNAME and STEAM_PASSWORD'
    }

    It 'requires HEMTT output to contain at least one PBO before packaging' {
        $workflow | Should -Match "addons"
        $workflow.Contains('.pbo') | Should -BeTrue
        $workflow | Should -Match 'at least one PBO'
    }

    It 'creates a GitHub release draft before final publication' {
        $draftStep = $workflow.IndexOf('draft: true')
        $publishStep = $workflow.IndexOf('name: Publish GitHub Release')
        $draftStep | Should -BeGreaterThan -1
        $publishStep | Should -BeGreaterThan $draftStep
        $workflow.Contains("inputs['publish-github'] && inputs['finalize-github']") | Should -BeTrue
    }

    It 'preserves the release-folder root in the archive' {
        $workflow | Should -Match 'CreateFromDirectory'
        $workflow.Contains('$true') | Should -BeTrue
    }

    It 'verifies packaged ZIP file count and SHA-256 hashes against the release folder' {
        $workflow | Should -Match 'Get-FileHash.*SHA256'
        $workflow | Should -Match 'Archive file count mismatch'
        $workflow | Should -Match 'Archive hash mismatch'
        $workflow | Should -Match 'Unexpected archive entry'
        $workflow | Should -Match 'Archive integrity verified'
    }


    It 'only uploads to Steam when Steam publishing is enabled' {
        $workflow.Contains('if: ${{ inputs[''publish-steam''] }}') | Should -BeTrue
        $workflow | Should -Match 'workshop-upload@v1'
    }

    It 'does not contain a direct Steam publish step in the test workflow' {
        $testWorkflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-tests.yml') -Raw
        $testWorkflow | Should -Not -Match 'workshop-upload'
        $testWorkflow | Should -Not -Match 'Publish GitHub Release'
    }
}


Describe 'Executable release configuration validation' {
    BeforeAll {
        $validBase = @{
            RELEASE_TAG = 'v1.2.3'
            WORKSHOP_ID = '123456789'
            WORKSHOP_NAME = 'Test Mod'
            RELEASE_FOLDER = '@TestMod'
            PUBLISH_GITHUB = 'true'
            PUBLISH_STEAM = 'false'
        }
    }

    It 'accepts valid GitHub-only publishing configuration' {
        $result = Invoke-ReleaseValidationTest -Environment $validBase
        $result.ExitCode | Should -Be 0
    }

    It 'rejects an invalid semantic version tag' {
        $envs = $validBase.Clone(); $envs.RELEASE_TAG = 'latest'
        (Invoke-ReleaseValidationTest -Environment $envs).ExitCode | Should -Not -Be 0
    }

    It 'rejects a non-numeric Workshop ID' {
        $envs = $validBase.Clone(); $envs.WORKSHOP_ID = 'abc'
        (Invoke-ReleaseValidationTest -Environment $envs).ExitCode | Should -Not -Be 0
    }

    It 'rejects an empty Workshop name' {
        $envs = $validBase.Clone(); $envs.WORKSHOP_NAME = ' '
        (Invoke-ReleaseValidationTest -Environment $envs).ExitCode | Should -Not -Be 0
    }

    It 'rejects a release folder containing a path' {
        $envs = $validBase.Clone(); $envs.RELEASE_FOLDER = 'folder/subfolder'
        (Invoke-ReleaseValidationTest -Environment $envs).ExitCode | Should -Not -Be 0
    }

    It 'rejects configuration with both publishing destinations disabled' {
        $envs = $validBase.Clone(); $envs.PUBLISH_GITHUB = 'false'
        (Invoke-ReleaseValidationTest -Environment $envs).ExitCode | Should -Not -Be 0
    }

    It 'requires Steam credentials when Steam publishing is enabled' {
        $envs = $validBase.Clone(); $envs.PUBLISH_STEAM = 'true'
        (Invoke-ReleaseValidationTest -Environment $envs).ExitCode | Should -Not -Be 0
    }
}
