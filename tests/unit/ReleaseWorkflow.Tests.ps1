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


    It 'uploads to Steam before finalizing the GitHub release' {
        $steamStep = $workflow.IndexOf('name: Upload to Steam Workshop')
        $finalizeStep = $workflow.IndexOf('name: Publish GitHub Release')
        $steamStep | Should -BeGreaterThan -1
        $finalizeStep | Should -BeGreaterThan $steamStep
        $workflow.Contains('if: ${{ inputs[''publish-steam''] }}') | Should -BeTrue
        $workflow.Contains('if: ${{ inputs[''publish-github''] && inputs[''finalize-github''] }}') | Should -BeTrue
    }

    It 'does not contain a direct Steam publish step in the test workflow' {
        $testWorkflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-tests.yml') -Raw
        $testWorkflow | Should -Not -Match 'workshop-upload'
        $testWorkflow | Should -Not -Match 'Publish GitHub Release'
    }
}

Describe 'Executable release configuration validation' {
    BeforeAll {
        $lines = $workflow -split "`r?`n"
        $stepIndex = -1
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i].Trim() -eq '- name: Validate release configuration') { $stepIndex = $i; break }
        }
        if ($stepIndex -lt 0) { throw 'Unable to locate release validation step.' }
        $runIndex = $stepIndex + 1
        while ($runIndex -lt $lines.Length -and $lines[$runIndex].Trim() -ne 'run: |') { $runIndex++ }
        if ($runIndex -ge $lines.Length) { throw 'Unable to locate release validation script block.' }
        $scriptLines = @()
        for ($lineIndex = $runIndex + 1; $lineIndex -lt $lines.Length; $lineIndex++) {
            if ($lines[$lineIndex].TrimStart() -match '^- name: ') { break }
            $scriptLines += $lines[$lineIndex]
        }
        $scriptLines = @($scriptLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($scriptLines.Count -eq 0) { throw 'Release validation script block is empty.' }
        $indent = ([regex]::Match($scriptLines[0], '^\\s*')).Length
        $validationScript = ($scriptLines | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_ } }) -join "`n"
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

Describe 'Executable release packaging validation' {
    BeforeAll {
        $packageLines = $workflow -split "`r?`n"
        $packageStep = -1
        for ($i = 0; $i -lt $packageLines.Length; $i++) {
            if ($packageLines[$i].Trim() -eq '- name: Package release folder') { $packageStep = $i; break }
        }
        if ($packageStep -lt 0) { throw 'Unable to locate release packaging step.' }
        $runIndex = $packageStep + 1
        while ($runIndex -lt $packageLines.Length -and $packageLines[$runIndex].Trim() -ne 'run: |') { $runIndex++ }
        if ($runIndex -ge $packageLines.Length) { throw 'Unable to locate release packaging script block.' }
        $scriptLines = @()
        for ($lineIndex = $runIndex + 1; $lineIndex -lt $packageLines.Length; $lineIndex++) {
            if ($packageLines[$lineIndex].TrimStart() -match '^- name: ') { break }
            $scriptLines += $packageLines[$lineIndex]
        }
        $scriptLines = @($scriptLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($scriptLines.Count -eq 0) { throw 'Release packaging script block is empty.' }
        $indent = ([regex]::Match($scriptLines[0], '^\\s*')).Length
        $packagingScript = ($scriptLines | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_ } }) -join "`n"
    }

    It 'packages release files with root folder preserved and verifies archive integrity' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $release = Join-Path $root '.hemttout/release'
        $addons = Join-Path $release 'addons'
        New-Item -ItemType Directory -Path $addons -Force | Out-Null
        'fake-pbo-content' | Set-Content -LiteralPath (Join-Path $addons 'sample.pbo')
        'readme' | Set-Content -LiteralPath (Join-Path $release 'readme.txt')
        $oldFolder = $env:RELEASE_FOLDER; $oldTag = $env:RELEASE_TAG
        $env:RELEASE_FOLDER = '@Fixture'; $env:RELEASE_TAG = 'v1.2.3'
        try {
            Push-Location $root
            try { & ([scriptblock]::Create($packagingScript)) } finally { Pop-Location }
            $archivePath = Join-Path $root '@Fixture-v1.2.3.zip'
            Test-Path -LiteralPath $archivePath | Should -BeTrue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
            try {
                $names = @($zip.Entries | ForEach-Object FullName)
                $names | Should -Contain '@Fixture-v1.2.3/addons/sample.pbo'
                $names | Should -Contain '@Fixture-v1.2.3/readme.txt'
            } finally { $zip.Dispose() }
        } finally {
            $env:RELEASE_FOLDER = $oldFolder; $env:RELEASE_TAG = $oldTag
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails when HEMTT output has no PBO files' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $release = Join-Path $root '.hemttout/release'
        New-Item -ItemType Directory -Path (Join-Path $release 'addons') -Force | Out-Null
        'empty' | Set-Content -LiteralPath (Join-Path $release 'readme.txt')
        $oldFolder = $env:RELEASE_FOLDER; $oldTag = $env:RELEASE_TAG
        $env:RELEASE_FOLDER = '@Fixture'; $env:RELEASE_TAG = 'v1.2.3'
        try {
            Push-Location $root
            try { { & ([scriptblock]::Create($packagingScript)) } | Should -Throw -ExpectedMessage '*at least one PBO*' }
            finally { Pop-Location }
            Test-Path -LiteralPath (Join-Path $root '@Fixture-v1.2.3') | Should -BeFalse
        } finally {
            $env:RELEASE_FOLDER = $oldFolder; $env:RELEASE_TAG = $oldTag
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'fails when HEMTT release output is missing' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $oldFolder = $env:RELEASE_FOLDER; $oldTag = $env:RELEASE_TAG
        $env:RELEASE_FOLDER = '@Fixture'; $env:RELEASE_TAG = 'v1.2.3'
        try {
            Push-Location $root
            try { { & ([scriptblock]::Create($packagingScript)) } | Should -Throw -ExpectedMessage '*HEMTT release output not found*' }
            finally { Pop-Location }
        } finally {
            $env:RELEASE_FOLDER = $oldFolder; $env:RELEASE_TAG = $oldTag
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails when the HEMTT addons directory is missing' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $release = Join-Path $root '.hemttout/release'
        New-Item -ItemType Directory -Path $release -Force | Out-Null
        'readme' | Set-Content -LiteralPath (Join-Path $release 'readme.txt')
        $oldFolder = $env:RELEASE_FOLDER; $oldTag = $env:RELEASE_TAG
        $env:RELEASE_FOLDER = '@Fixture'; $env:RELEASE_TAG = 'v1.2.3'
        try {
            Push-Location $root
            try { { & ([scriptblock]::Create($packagingScript)) } | Should -Throw -ExpectedMessage '*addons*' }
            finally { Pop-Location }
            Test-Path -LiteralPath (Join-Path $root '@Fixture-v1.2.3') | Should -BeFalse
        } finally {
            $env:RELEASE_FOLDER = $oldFolder; $env:RELEASE_TAG = $oldTag
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

}
