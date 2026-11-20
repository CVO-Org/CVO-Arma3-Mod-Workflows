$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$workflowPath = Join-Path $repositoryRoot '.github/workflows/release.yml'

Describe 'Reusable release workflow safety' {
    BeforeAll {
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
    }

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
        $workflow | Should -Match "\.pbo"
        $workflow | Should -Match 'at least one PBO'
    }

    It 'creates a GitHub release draft before final publication' {
        $draftStep = $workflow.IndexOf('draft: true')
        $publishStep = $workflow.IndexOf('name: Publish GitHub Release')
        $draftStep | Should -BeGreaterThan -1
        $publishStep | Should -BeGreaterThan $draftStep
        $workflow | Should -Match "inputs\['publish-github'\] && inputs\['finalize-github'\]"
    }

    It 'preserves the release-folder root in the archive' {
        $workflow | Should -Match 'CreateFromDirectory'
        $workflow | Should -Match '\$true'
    }

    It 'only uploads to Steam when Steam publishing is enabled' {
        $workflow | Should -Match "if: \$\{\{ inputs\['publish-steam'\] \}\}"
        $workflow | Should -Match 'workshop-upload@v1'
    }

    It 'does not contain a direct Steam publish step in the test workflow' {
        $testWorkflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-tests.yml') -Raw
        $testWorkflow | Should -Not -Match 'workshop-upload'
        $testWorkflow | Should -Not -Match 'Publish GitHub Release'
    }
}
