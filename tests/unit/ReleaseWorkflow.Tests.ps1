BeforeAll {
    $repositoryRoot = (Get-Location).Path
    $workflowPath = Join-Path $repositoryRoot '.github/workflows/release.yml'
    $workflow = Get-Content -LiteralPath $workflowPath -Raw
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
        $workflow | Should -Match 'addons'
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
        $lines = $workflow -split "\\r?\\n"
        $stepIndex = [array]::FindIndex($lines, [Predicate[string]]{ param($line) $line -match '^      - name: Validate release configuration$' })
        if ($stepIndex -lt 0) { throw 'Unable to locate release validation step.' }
        $runIndex = $stepIndex + 1
        while ($runIndex -lt $lines.Length -and $lines[$runIndex] -notmatch '^        run: \\|$') { $runIndex++ }
        if ($runIndex -ge $lines.Length) { throw 'Unable to locate release validation script block.' }
        $scriptLines = @()
        for ($lineIndex = $runIndex + 1; $lineIndex -lt $lines.Length; $lineIndex++) {
            if ($lines[$lineIndex] -match '^      - name: ') { break }
            $scriptLines += $lines[$lineIndex]
        }
        $scriptLines = @($scriptLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($scriptLines.Count -eq 0) { throw 'Release validation script block is empty.' }
        $indent = ([regex]::Match($scriptLines[0], '^\\s*')).Length
        $validationScript = ($scriptLines | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_ } }) -join "\\n"
        $validationScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.ps1')
        Set-Content -LiteralPath $validationScriptPath -Value $validationScript -Encoding utf8
        $validBase = @{
            RELEASE_TAG = 'v1.2.3'
            WORKSHOP_ID = '123456789'
            WORKSHOP_NAME = 'Test Mod'
            RELEASE_FOLDER = '@TestMod'
            PUBLISH_GITHUB = 'true'
            PUBLISH_STEAM = 'false'
            STEAM_USERNAME = ''
            STEAM_PASSWORD = ''
        }
    }

    It 'accepts valid GitHub-only publishing configuration' {
        $names = $validBase.Keys
        $old = @{}
        foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $validBase[$name]) }
        try { & pwsh -NoProfile -File $validationScriptPath; $LASTEXITCODE | Should -Be 0 }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) } }
    }

    It 'rejects invalid release tags' {
        $envs = $validBase.Clone(); $envs.RELEASE_TAG = 'latest'
        $names = $envs.Keys; $old = @{}
        foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $envs[$name]) }
        try { & pwsh -NoProfile -File $validationScriptPath; $LASTEXITCODE | Should -Not -Be 0 }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) } }
    }

    It 'rejects non-numeric Workshop IDs' {
        $envs = $validBase.Clone(); $envs.WORKSHOP_ID = 'abc'
        $names = $envs.Keys; $old = @{}
        foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $envs[$name]) }
        try { & pwsh -NoProfile -File $validationScriptPath; $LASTEXITCODE | Should -Not -Be 0 }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) } }
    }

    It 'rejects empty Workshop names' {
        $envs = $validBase.Clone(); $envs.WORKSHOP_NAME = ' '
        $names = $envs.Keys; $old = @{}
        foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $envs[$name]) }
        try { & pwsh -NoProfile -File $validationScriptPath; $LASTEXITCODE | Should -Not -Be 0 }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) } }
    }

    It 'rejects release-folder paths' {
        $envs = $validBase.Clone(); $envs.RELEASE_FOLDER = 'folder/subfolder'
        $names = $envs.Keys; $old = @{}
        foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $envs[$name]) }
        try { & pwsh -NoProfile -File $validationScriptPath; $LASTEXITCODE | Should -Not -Be 0 }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) } }
    }

    It 'rejects disabling both release destinations' {
        $envs = $validBase.Clone(); $envs.PUBLISH_GITHUB = 'false'
        $names = $envs.Keys; $old = @{}
        foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $envs[$name]) }
        try { & pwsh -NoProfile -File $validationScriptPath; $LASTEXITCODE | Should -Not -Be 0 }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) } }
    }

    It 'requires Steam credentials when Steam publishing is enabled' {
        $envs = $validBase.Clone(); $envs.PUBLISH_STEAM = 'true'
        $names = $envs.Keys; $old = @{}
        foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $envs[$name]) }
        try { & pwsh -NoProfile -File $validationScriptPath; $LASTEXITCODE | Should -Not -Be 0 }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) } }
    }

    AfterAll {
        Remove-Item -LiteralPath $validationScriptPath -Force -ErrorAction SilentlyContinue
    }
}
