$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$coreRoot = Join-Path $repositoryRoot 'src/Core'

Describe 'Arma3 Mod Workflows core' {
    BeforeAll {
        . (Join-Path $coreRoot 'Logging.ps1')
        . (Join-Path $coreRoot 'Configuration.ps1')
        . (Join-Path $coreRoot 'ModuleManager.ps1')
        . (Join-Path $coreRoot 'Initialize.ps1')
    }

    It 'imports the public PowerShell module manifest' {
        $manifest = Join-Path $repositoryRoot 'src/Arma3ModWorkflows.psd1'
        { Import-Module $manifest -Force -ErrorAction Stop } | Should -Not -Throw
        Get-Command Initialize-A3Workflow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'accepts schema version 1 configuration' {
        $config = @{ schema_version = 1 }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeTrue
    }

    It 'rejects unsupported schema versions' {
        $config = @{ schema_version = 99 }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'rejects unknown root properties' {
        $config = @{ schema_version = 1; unexpected = $true }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'accepts the complete framework defaults against the JSON Schema' {
        $defaultsPath = Join-Path $repositoryRoot 'config/defaults/configuration.json'
        $defaults = Read-A3WorkflowConfigurationFile -Path $defaultsPath
        (Test-A3WorkflowConfiguration -Configuration $defaults).IsValid | Should -BeTrue
    }

    It 'accepts project-defined module configuration keys' {
        $config = @{ schema_version = 1; modules = @{ 'Custom.Analysis' = @{ enabled = $true; settings = @{ strict = $true } } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeTrue
    }

    It 'rejects unknown nested properties' {
        $config = @{ schema_version = 1; paths = @{ build_output = '.build'; unexpected = $true } }
        $result = Test-A3WorkflowConfiguration -Configuration $config
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'paths contains unknown property'
    }

    It 'rejects malformed semantic versions' {
        $config = @{ schema_version = 1; project = @{ version = '1.2' } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'rejects invalid module toggle types' {
        $config = @{ schema_version = 1; modules = @{ build = @{ enabled = 'yes' } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'rejects invalid Steam Workshop identifiers' {
        $config = @{ schema_version = 1; distribution = @{ steam = @{ enabled = $true; workshop_id = 'abc' } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'rejects invalid Steam visibility values' {
        $config = @{ schema_version = 1; distribution = @{ steam = @{ visibility = 'everyone' } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'rejects non-string tool arguments' {
        $config = @{ schema_version = 1; tools = @{ hemtt = @{ arguments = @('--release', 42) } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'discovers and registers enabled module descriptors' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $moduleDirectory = Join-Path $root 'Build'
        New-Item -ItemType Directory -Path $moduleDirectory -Force | Out-Null
        try {
            @'
@{
    Id = 'Build.Sample'
    ConfigKey = 'build'
    Operations = @('Run')
    Invoke = { param($Context, $Operation) return @{ Executed = $true } }
}
'@ | Set-Content -LiteralPath (Join-Path $moduleDirectory 'Module.ps1') -Encoding UTF8
            $registry = New-A3WorkflowModuleRegistry
            $configuration = @{ modules = @{ build = @{ enabled = $true } } }
            $discovery = Import-A3WorkflowModules -Registry $registry -ModulesRoot $root -Configuration $configuration
            $discovery.Registered | Should -Contain 'Build.Sample'
            $registry.Modules.ContainsKey('Build.Sample') | Should -BeTrue
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not register modules disabled by configuration' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $moduleDirectory = Join-Path $root 'Build'
        New-Item -ItemType Directory -Path $moduleDirectory -Force | Out-Null
        try {
            @'
@{
    Id = 'Build.Disabled'
    ConfigKey = 'build'
    Invoke = {
        param($Context, $Operation)
        throw 'A disabled module must not execute.'
    }
}
'@ | Set-Content -LiteralPath (Join-Path $moduleDirectory 'Module.ps1') -Encoding UTF8
            $registry = New-A3WorkflowModuleRegistry
            $configuration = @{ modules = @{ build = @{ enabled = $false } } }
            $discovery = Import-A3WorkflowModules -Registry $registry -ModulesRoot $root -Configuration $configuration
            $discovery.Registered.Count | Should -Be 0
            $discovery.Skipped[0].Id | Should -Be 'Build.Disabled'
            $registry.Modules.ContainsKey('Build.Disabled') | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects malformed module descriptors' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $moduleDirectory = Join-Path $root 'Broken'
        New-Item -ItemType Directory -Path $moduleDirectory -Force | Out-Null
        try {
            "@{ Id = 'Broken.Module' }" | Set-Content -LiteralPath (Join-Path $moduleDirectory 'Module.ps1') -Encoding UTF8
            $registry = New-A3WorkflowModuleRegistry
            { Import-A3WorkflowModules -Registry $registry -ModulesRoot $root -Configuration @{} } | Should -Throw
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'orders dependencies before dependent modules' {
        $registry = New-A3WorkflowModuleRegistry
        Register-A3WorkflowModule -Registry $registry -Id 'Core.First' -Invoke { }
        Register-A3WorkflowModule -Registry $registry -Id 'Feature.Second' -DependsOn @('Core.First') -Invoke { }
        $order = Resolve-A3WorkflowModuleOrder -Registry $registry -ModuleIds @('Feature.Second')
        $order[0].Id | Should -Be 'Core.First'
        $order[1].Id | Should -Be 'Feature.Second'
    }

    It 'detects circular dependencies' {
        $registry = New-A3WorkflowModuleRegistry
        Register-A3WorkflowModule -Registry $registry -Id 'Core.First' -DependsOn @('Feature.Second') -Invoke { }
        Register-A3WorkflowModule -Registry $registry -Id 'Feature.Second' -DependsOn @('Core.First') -Invoke { }
        { Resolve-A3WorkflowModuleOrder -Registry $registry -ModuleIds @('Core.First') } | Should -Throw
    }

    It 'rejects missing required dependencies before execution' {
        $registry = New-A3WorkflowModuleRegistry
        Register-A3WorkflowModule -Registry $registry -Id 'Feature.Orphan' -DependsOn @('Core.Missing') -Invoke { throw 'must not execute' }
        { Resolve-A3WorkflowModuleOrder -Registry $registry -ModuleIds @('Feature.Orphan') } | Should -Throw '*Required module*not registered*'
    }

    It 'rejects duplicate module identifiers' {
        $registry = New-A3WorkflowModuleRegistry
        Register-A3WorkflowModule -Registry $registry -Id 'Core.Sample' -Invoke { }
        { Register-A3WorkflowModule -Registry $registry -Id 'Core.Sample' -Invoke { } } | Should -Throw '*already registered*'
    }

    It 'rejects module identifiers outside the dotted identifier format' {
        $registry = New-A3WorkflowModuleRegistry
        { Register-A3WorkflowModule -Registry $registry -Id 'Invalid_Module' -Invoke { } } | Should -Throw '*Invalid module identifier*'
    }

    It 'rejects modules with no declared operations' {
        $registry = New-A3WorkflowModuleRegistry
        { Register-A3WorkflowModule -Registry $registry -Id 'Core.Empty' -Operations @() -Invoke { } } | Should -Throw '*at least one non-empty operation*'
    }

    It 'skips modules that do not support the requested operation' {
        $registry = New-A3WorkflowModuleRegistry
        Register-A3WorkflowModule -Registry $registry -Id 'Core.Build' -Operations @('Build') -Invoke { throw 'unsupported operation must not execute' }
        $context = [pscustomobject]@{ Logger = $null }
        $result = Invoke-A3WorkflowModules -Registry $registry -Context $context -Operation 'Validate'
        $result[0].Status | Should -Be 'Skipped'
        $result[0].Summary | Should -Match 'unsupported'
    }

    It 'normalizes successful module execution' {
        $registry = New-A3WorkflowModuleRegistry
        Register-A3WorkflowModule -Registry $registry -Id 'Core.Sample' -Invoke { param($Context, $Operation) return @{ Value = 42 } }
        $context = [pscustomobject]@{ Logger = $null }
        $result = Invoke-A3WorkflowModules -Registry $registry -Context $context
        $result[0].Status | Should -Be 'Passed'
    }
    It 'skips dependent modules after a dependency fails' {
        $registry = New-A3WorkflowModuleRegistry
        Register-A3WorkflowModule -Registry $registry -Id 'Core.Broken' -Invoke { throw 'intentional failure' }
        Register-A3WorkflowModule -Registry $registry -Id 'Feature.Dependent' -DependsOn @('Core.Broken') -Invoke { throw 'must not execute' }
        $context = [pscustomobject]@{ Logger = $null }
        $results = Invoke-A3WorkflowModules -Registry $registry -Context $context
        ($results | Where-Object Module -eq 'Core.Broken').Status | Should -Be 'Failed'
        ($results | Where-Object Module -eq 'Feature.Dependent').Status | Should -Be 'Skipped'
    }

    It 'initializes an integrated context with merged defaults' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            '{"schema_version":1}' | Set-Content -LiteralPath (Join-Path $projectRoot 'arma3-workflows.json') -Encoding UTF8
            $context = Initialize-A3Workflow -ProjectRoot $projectRoot -FrameworkRoot $repositoryRoot
            $context.ProjectRoot | Should -Be (Resolve-Path $projectRoot).Path
            $context.Configuration.paths.build_output | Should -Be '.build'
            $context.Registry | Should -Not -BeNullOrEmpty
            $context.Logger | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'provides a public command-line entry point' {
        Test-Path -LiteralPath (Join-Path $repositoryRoot 'src/Invoke-Arma3ModWorkflows.ps1') | Should -BeTrue
    }

    It 'lists modules through the command-line entry point' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            '{"schema_version":1}' | Set-Content -LiteralPath (Join-Path $projectRoot 'arma3-workflows.json') -Encoding UTF8
            $cli = Join-Path $repositoryRoot 'src/Invoke-Arma3ModWorkflows.ps1'
            $output = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $cli -ProjectRoot $projectRoot -ListModules 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Not -Match 'Exception|Error'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns exit code 2 when CLI initialization fails' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            '{"schema_version":99}' | Set-Content -LiteralPath (Join-Path $projectRoot 'arma3-workflows.json') -Encoding UTF8
            $cli = Join-Path $repositoryRoot 'src/Invoke-Arma3ModWorkflows.ps1'
            $null = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $cli -ProjectRoot $projectRoot 2>&1)
            $LASTEXITCODE | Should -Be 2
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns exit code 0 when no modules are enabled' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            '{"schema_version":1}' | Set-Content -LiteralPath (Join-Path $projectRoot 'arma3-workflows.json') -Encoding UTF8
            $cli = Join-Path $repositoryRoot 'src/Invoke-Arma3ModWorkflows.ps1'
            $null = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $cli -ProjectRoot $projectRoot 2>&1)
            $LASTEXITCODE | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'uses module result statuses to determine CLI exit codes' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $modulesRoot = Join-Path $repositoryRoot 'src/Modules'
        $modulesRootExisted = Test-Path -LiteralPath $modulesRoot -PathType Container
        $failureDirectory = Join-Path $modulesRoot 'TestFailure'
        $warningDirectory = Join-Path $modulesRoot 'TestWarning'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $failureDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $warningDirectory -Force | Out-Null
        try {
            @'
@{
    Id = 'Test.Failure'
    ConfigKey = 'testfailure'
    Invoke = {
        param($Context, $Operation)
        throw 'Intentional CLI failure test.'
    }
}
'@ | Set-Content -LiteralPath (Join-Path $failureDirectory 'Module.ps1') -Encoding UTF8
            @'
@{
    Id = 'Test.Warning'
    ConfigKey = 'testwarning'
    Invoke = {
        param($Context, $Operation)
        [pscustomobject]@{ Module = 'Test.Warning'; Operation = $Operation; Status = 'Warning'; Summary = 'Intentional warning test.' }
    }
}
'@ | Set-Content -LiteralPath (Join-Path $warningDirectory 'Module.ps1') -Encoding UTF8
            '{"schema_version":1,"modules":{"testfailure":{"enabled":true},"testwarning":{"enabled":true}}}' | Set-Content -LiteralPath (Join-Path $projectRoot 'arma3-workflows.json') -Encoding UTF8
            $cli = Join-Path $repositoryRoot 'src/Invoke-Arma3ModWorkflows.ps1'
            $pwsh = Join-Path $PSHOME 'pwsh.exe'

            $null = @(& $pwsh -NoProfile -File $cli -ProjectRoot $projectRoot -Module 'Test.Failure' 2>&1)
            $LASTEXITCODE | Should -Be 1

            $null = @(& $pwsh -NoProfile -File $cli -ProjectRoot $projectRoot -Module 'Test.Warning' 2>&1)
            $LASTEXITCODE | Should -Be 0

            $null = @(& $pwsh -NoProfile -File $cli -ProjectRoot $projectRoot -Module 'Test.Warning' -FailOnWarning 2>&1)
            $LASTEXITCODE | Should -Be 1
        }
        finally {
            Remove-Item -LiteralPath $failureDirectory -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $warningDirectory -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $modulesRootExisted) { Remove-Item -LiteralPath $modulesRoot -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns exit code 2 when a requested module is not registered' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            '{"schema_version":1}' | Set-Content -LiteralPath (Join-Path $projectRoot 'arma3-workflows.json') -Encoding UTF8
            $cli = Join-Path $repositoryRoot 'src/Invoke-Arma3ModWorkflows.ps1'
            $null = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $cli -ProjectRoot $projectRoot -Module 'Missing.Module' 2>&1)
            $LASTEXITCODE | Should -Be 2
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails HEMTT builds when the configured project file is missing' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ paths = @{ hemtt_config = '.hemtt/project.toml' }; tools = @{ hemtt = @{ path = (Join-Path $PSHOME 'pwsh.exe') } } }
                Logger = $null
            }
            $result = & $descriptor.Invoke $context 'Build'
            $result.Status | Should -Be 'Failed'
            $result.Summary | Should -Match 'configuration was not found'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'skips HEMTT when explicitly disabled in tool configuration' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $context = [pscustomobject]@{
            ProjectRoot = ([IO.Path]::GetTempPath())
            Configuration = @{ paths = @{}; tools = @{ hemtt = @{ enabled = $false } } }
            Logger = $null
        }
        $result = & $descriptor.Invoke $context 'Detect'
        $result.Status | Should -Be 'Skipped'
    }

    It 'skips an unavailable optional HEMTT executable' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $context = [pscustomobject]@{
            ProjectRoot = ([IO.Path]::GetTempPath())
            Configuration = @{ paths = @{}; tools = @{ hemtt = @{ path = 'missing-hemtt.exe'; required = $false } } }
            Logger = $null
        }
        $result = & $descriptor.Invoke $context 'Detect'
        $result.Status | Should -Be 'Skipped'
    }

    It 'fails when a required HEMTT executable is unavailable' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $context = [pscustomobject]@{
            ProjectRoot = ([IO.Path]::GetTempPath())
            Configuration = @{ paths = @{}; tools = @{ hemtt = @{ path = 'missing-hemtt.exe'; required = $true } } }
            Logger = $null
        }
        $result = & $descriptor.Invoke $context 'Detect'
        $result.Status | Should -Be 'Failed'
    }

    It 'invokes a mock HEMTT executable and captures version, output, and artifacts' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $hemttDirectory = Join-Path $projectRoot '.hemtt'
            New-Item -ItemType Directory -Path $hemttDirectory -Force | Out-Null
            'name = "MockProject"' | Set-Content -LiteralPath (Join-Path $hemttDirectory 'project.toml') -Encoding UTF8

            $mockExecutable = Join-Path $projectRoot 'mock-hemtt.ps1'
            @'
$global:LASTEXITCODE = 0
Write-Output 'HEMTT v1.2.3'
Write-Output ("Mock received: " + ($args -join ' '))
if ($args -contains '--fail') { $global:LASTEXITCODE = 7 }
'@ | Set-Content -LiteralPath $mockExecutable -Encoding UTF8

            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{
                    paths = @{ hemtt_config = '.hemtt/project.toml' }
                    tools = @{ hemtt = @{ path = $mockExecutable } }
                }
                Logger = $null
            }

            $detectResult = & $descriptor.Invoke $context 'Detect'
            $detectResult.Status | Should -Be 'Passed'
            $detectResult.Data.Version | Should -Be '1.2.3'
            $detectResult.Data.Arguments | Should -Contain '--version'
            $detectResult.Data.Output | Should -Match 'Mock received: --version'

            $artifactDirectory = Join-Path $projectRoot '.hemttout/build'
            New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
            'mock artifact' | Set-Content -LiteralPath (Join-Path $artifactDirectory 'test.pbo') -Encoding UTF8

            $buildResult = & $descriptor.Invoke $context 'Build'
            $buildResult.Status | Should -Be 'Passed'
            $buildResult.Data.Arguments | Should -Contain 'build'
            $buildResult.Data.Output | Should -Match 'Mock received: build'
            $buildResult.Data.Artifacts | Should -Contain (Join-Path $artifactDirectory 'test.pbo')

            $context.Configuration.tools.hemtt.arguments = @('--fail')
            $failureResult = & $descriptor.Invoke $context 'Build'
            $failureResult.Status | Should -Be 'Failed'
            $failureResult.Data.ExitCode | Should -Be 7
            $failureResult.Data.Output | Should -Match '--fail'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'merges project overrides over framework defaults' {
        $defaults = @{ paths = @{ build_output = '.build'; release_output = 'release' }; modules = @{ build = @{ enabled = $true } } }
        $project = @{ paths = @{ build_output = 'out' }; modules = @{ build = @{ enabled = $false } } }
        $merged = Merge-A3WorkflowConfiguration -Base $defaults -Override $project
        $merged.paths.build_output | Should -Be 'out'
        $merged.paths.release_output | Should -Be 'release'
        $merged.modules.build.enabled | Should -BeFalse
    }
}
