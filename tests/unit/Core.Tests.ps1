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

    It 'accepts HEMTT version pins and shared CLI arguments' {
        $config = @{ schema_version = 1; tools = @{ hemtt = @{ version = '1.21.0'; required = $true; arguments = @('--no-color'); timeout_seconds = 600 } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeTrue
    }

    It 'accepts HEMTT check-specific arguments' {
        $config = @{ schema_version = 1; tools = @{ hemtt = @{ check_arguments = @('--pedantic', '--error-on-all', '--lints', 's01-invalid-command') } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeTrue
    }

    It 'rejects non-string HEMTT check-specific arguments' {
        $config = @{ schema_version = 1; tools = @{ hemtt = @{ check_arguments = @('--pedantic', 42) } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'rejects malformed HEMTT version pins' {
        $config = @{ schema_version = 1; tools = @{ hemtt = @{ version = '1.21' } } }
        (Test-A3WorkflowConfiguration -Configuration $config).IsValid | Should -BeFalse
    }

    It 'rejects non-positive HEMTT process timeouts at execution time' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $hemttDirectory = Join-Path $projectRoot '.hemtt'
            New-Item -ItemType Directory -Path $hemttDirectory -Force | Out-Null
            'name = "MockProject"' | Set-Content -LiteralPath (Join-Path $hemttDirectory 'project.toml') -Encoding UTF8
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ paths = @{ hemtt_config = '.hemtt/project.toml' }; tools = @{ hemtt = @{ path = (Join-Path $PSHOME 'pwsh.exe'); timeout_seconds = 0 } } }
                Logger = $null
            }
            $result = & $descriptor.Invoke $context 'Build'
            $result.Status | Should -Be 'Failed'
            $result.Summary | Should -Match 'timeout_seconds must be at least 1'
            $result.DurationMs | Should -BeGreaterThan 0
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
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
            $context.Registry.Modules.ContainsKey('Build.HEMTT') | Should -BeTrue
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
            $result.DurationMs | Should -BeGreaterThan 0
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports HEMTT process startup failures with diagnostics' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $hemttDirectory = Join-Path $projectRoot '.hemtt'
            New-Item -ItemType Directory -Path $hemttDirectory -Force | Out-Null
            'name = "StartupFailure"' | Set-Content -LiteralPath (Join-Path $hemttDirectory 'project.toml') -Encoding UTF8
            $invalidExecutable = Join-Path $projectRoot 'not-an-executable.txt'
            'This file cannot be executed.' | Set-Content -LiteralPath $invalidExecutable -Encoding UTF8
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ paths = @{ hemtt_config = '.hemtt/project.toml' }; tools = @{ hemtt = @{ path = $invalidExecutable } } }
                Logger = $null
            }

            $result = & $descriptor.Invoke $context 'Build'
            $result.Status | Should -Be 'Failed'
            $result.Data.ExitCode | Should -Be 1
            $result.Data.VersionExitCode | Should -Be 1
            $result.Data.ProcessStartError | Should -Not -BeNullOrEmpty
            $result.Data.StandardError | Should -Not -BeNullOrEmpty
            $result.Errors.Count | Should -Be 1
            $result.Errors[0].Message | Should -Match 'exited with code 1'
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
        $result.DurationMs | Should -BeGreaterThan 0
    }

    It 'ignores PowerShell functions and aliases when discovering HEMTT on PATH' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        Mock Get-Command {
            [pscustomobject]@{ Name = $Name; CommandType = 'Function'; Source = 'MockFunction' }
        }
        $context = [pscustomobject]@{
            ProjectRoot = ([IO.Path]::GetTempPath())
            Configuration = @{ paths = @{}; tools = @{ hemtt = @{ required = $false } } }
            Logger = $null
        }
        $result = & $descriptor.Invoke $context 'Detect'
        $result.Status | Should -Be 'Skipped'
        $result.Summary | Should -Match 'executable was not found'
        $result.Warnings.Count | Should -Be 1
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
        $result.Warnings.Count | Should -Be 1
        $result.Errors.Count | Should -Be 0
        $result.DurationMs | Should -BeGreaterThan 0
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
        $result.Errors.Count | Should -Be 1
        $result.Warnings.Count | Should -Be 0
        $result.DurationMs | Should -BeGreaterThan 0
    }


    It 'resolves a relative configured HEMTT executable path against the project root' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("HEMTT Relative Path " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ paths = @{}; tools = @{ hemtt = @{ path = 'tools/missing-hemtt.exe'; required = $false } } }
                Logger = $null
            }
            $result = & $descriptor.Invoke $context 'Detect'
            $result.Status | Should -Be 'Skipped'
            $result.Summary | Should -Match ([regex]::Escape((Join-Path $projectRoot 'tools/missing-hemtt.exe')))
            $result.Warnings[0].Path | Should -Be (Join-Path $projectRoot 'tools/missing-hemtt.exe')
        }
        finally {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'resolves a configured HEMTT directory to hemtt.exe' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("HEMTT Directory Path " + [guid]::NewGuid().ToString('N'))
        $toolDirectory = Join-Path $projectRoot 'tools'
        New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
        try {
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ paths = @{}; tools = @{ hemtt = @{ path = 'tools'; required = $false } } }
                Logger = $null
            }
            $result = & $descriptor.Invoke $context 'Detect'
            $result.Status | Should -Be 'Skipped'
            $result.Summary | Should -Match ([regex]::Escape((Join-Path $toolDirectory 'hemtt.exe')))
            $result.Warnings[0].Path | Should -Be (Join-Path $toolDirectory 'hemtt.exe')
        }
        finally {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'executes hemtt.ps1 from a configured tool directory' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("HEMTT Directory Execution " + [guid]::NewGuid().ToString('N'))
        $toolDirectory = Join-Path $projectRoot 'tools'
        New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
        try {
            @'
if ($args -contains '--version') { Write-Output 'HEMTT v1.2.3'; exit 0 }
exit 0
'@ | Set-Content -LiteralPath (Join-Path $toolDirectory 'hemtt.ps1') -Encoding UTF8
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ paths = @{}; tools = @{ hemtt = @{ path = 'tools'; version = '1.2.3' } } }
                Logger = $null
            }
            $result = & $descriptor.Invoke $context 'Detect'
            $result.Status | Should -Be 'Passed'
            $result.Data.Executable | Should -Be (Join-Path $toolDirectory 'hemtt.ps1')
            $result.Data.Version | Should -Be '1.2.3'
        }
        finally {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'discovers and executes HEMTT from PATH' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("HEMTT PATH Discovery " + [guid]::NewGuid().ToString('N'))
        $toolDirectory = Join-Path $projectRoot 'tools'
        New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
        $originalPath = $env:PATH
        try {
            @'
if ($args -contains '--version') { Write-Output 'HEMTT v1.2.3'; exit 0 }
exit 0
'@ | Set-Content -LiteralPath (Join-Path $toolDirectory 'hemtt.ps1') -Encoding UTF8
            $env:PATH = $toolDirectory + [IO.Path]::PathSeparator + $originalPath
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ paths = @{}; tools = @{ hemtt = @{ version = '1.2.3' } } }
                Logger = $null
            }
            $result = & $descriptor.Invoke $context 'Detect'
            $result.Status | Should -Be 'Passed'
            $result.Data.Executable | Should -Be (Join-Path $toolDirectory 'hemtt.ps1')
            $result.Data.Version | Should -Be '1.2.3'
        }
        finally {
            $env:PATH = $originalPath
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'invokes a mock HEMTT executable and captures version, output, and artifacts' {
        $descriptor = & (Join-Path $repositoryRoot 'src/Modules/HEMTT/Module.ps1')
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("HEMTT Mock Project " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $hemttDirectory = Join-Path $projectRoot '.hemtt'
            New-Item -ItemType Directory -Path $hemttDirectory -Force | Out-Null
            'name = "MockProject"' | Set-Content -LiteralPath (Join-Path $hemttDirectory 'project.toml') -Encoding UTF8

            $mockExecutable = Join-Path $projectRoot 'mock-hemtt.ps1'
            @'
$global:LASTEXITCODE = 0
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'invocations.log') -Value ($args -join ' ')
if ($args -contains '--version') {
    $versionModePath = Join-Path $PSScriptRoot 'version-mode.txt'
    $versionMode = if (Test-Path -LiteralPath $versionModePath) { (Get-Content -LiteralPath $versionModePath -Raw).Trim() } else { 'normal' }
    switch ($versionMode) {
        'fail' { [Console]::Error.WriteLine('Mock version probe failed'); exit 9 }
        'unparseable' { Write-Output 'development build'; exit 0 }
        'sleep' { Start-Sleep -Seconds 3; Write-Output '1.2.3'; exit 0 }
        default { Write-Output '1.2.3' }
    }
}
else { Write-Output 'HEMTT v1.2.3' }
Write-Output ("Mock received: " + ($args -join ' '))
if ($args -contains 'build') {
    $outputDirectory = Join-Path $PSScriptRoot '.hemttout/build'
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $artifactPath = Join-Path $outputDirectory 'generated.pbo'
    if ($args -contains '--same-metadata-change' -and (Test-Path -LiteralPath $artifactPath)) {
        $originalTimestamp = (Get-Item -LiteralPath $artifactPath).LastWriteTimeUtc
        'rewritten by mock' | Set-Content -LiteralPath $artifactPath
        (Get-Item -LiteralPath $artifactPath).LastWriteTimeUtc = $originalTimestamp
    }
    else {
        'generated by mock' | Set-Content -LiteralPath $artifactPath
    }
}
if ($args -contains 'release') {
    $releaseOutput = Join-Path $PSScriptRoot '.hemttout/release'
    $releaseArchives = Join-Path $PSScriptRoot 'releases'
    New-Item -ItemType Directory -Path $releaseOutput -Force | Out-Null
    New-Item -ItemType Directory -Path $releaseArchives -Force | Out-Null
    'generated release pbo' | Set-Content -LiteralPath (Join-Path $releaseOutput 'generated-release.pbo')
    'generated release zip' | Set-Content -LiteralPath (Join-Path $releaseArchives 'MockProject-generated.zip')
}
[Console]::Error.WriteLine('Mock stderr')
if ($args -contains '--sleep') { Start-Sleep -Seconds 3 }
if ($args -contains '--fail') { exit 7 }
'@ | Set-Content -LiteralPath $mockExecutable -Encoding UTF8

            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{
                    paths = @{ hemtt_config = '.hemtt/project.toml' }
                    tools = @{ hemtt = @{ path = 'mock-hemtt.ps1'; version = '1.2.3'; arguments = @('--mock-option', 'value with spaces'); check_arguments = @('--pedantic', '--error-on-all', '--lints', 's01-invalid-command') } }
                }
                Logger = $null
            }

            $detectResult = & $descriptor.Invoke $context 'Detect'
            $detectResult.Status | Should -Be 'Passed'
            $detectResult.Data.Executable | Should -Be $mockExecutable
            $detectResult.Data.Version | Should -Be '1.2.3'
            $detectResult.Data.Arguments | Should -Contain '--version'
            $detectResult.Data.Arguments | Should -Contain '--mock-option'
            $detectResult.Data.Arguments | Should -Contain 'value with spaces'
            $detectResult.Data.StandardOutput | Should -Match 'Mock received: --version'
            $detectResult.Data.StandardError | Should -Match 'Mock stderr'
            $detectResult.Data.VersionStandardOutput | Should -Match '1.2.3'
            $detectResult.Data.VersionStandardError | Should -Match 'Mock stderr'
            $detectResult.Data.VersionOutput | Should -Match '1.2.3'
            $detectResult.Data.Output | Should -Match 'Mock received: --version'

            $context.Configuration.tools.hemtt.version = '2.0.0'
            $detectMismatch = & $descriptor.Invoke $context 'Detect'
            $detectMismatch.Status | Should -Be 'Failed'
            $detectMismatch.Data.VersionMismatch | Should -BeTrue
            $context.Configuration.tools.hemtt.version = '1.2.3'

            $artifactDirectory = Join-Path $projectRoot '.hemttout/build'
            New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
            'stale artifact' | Set-Content -LiteralPath (Join-Path $artifactDirectory 'stale.pbo') -Encoding UTF8

            $buildResult = & $descriptor.Invoke $context 'Build'
            $buildResult.Status | Should -Be 'Passed'
            $buildResult.Data.Version | Should -Be '1.2.3'
            $buildResult.Data.StandardOutput | Should -Match 'value with spaces'
            $buildResult.Data.StandardError | Should -Match 'Mock stderr'

            $versionModePath = Join-Path $projectRoot 'version-mode.txt'
            $invocationLog = Join-Path $projectRoot 'invocations.log'
            $buildInvocationsBeforeProbeFailures = @(Get-Content -LiteralPath $invocationLog | Where-Object { $_ -notmatch '^--version(?:\s|$)' })

            'fail' | Set-Content -LiteralPath $versionModePath -Encoding UTF8
            $detectProcessFailure = & $descriptor.Invoke $context 'Detect'
            $detectProcessFailure.Status | Should -Be 'Failed'
            $detectProcessFailure.Data.VersionExitCode | Should -Be 9
            $detectProcessFailure.Data.ExitCode | Should -Be 9
            $detectProcessFailure.Errors.Count | Should -Be 1
            $versionProbeFailure = & $descriptor.Invoke $context 'Build'
            $versionProbeFailure.Status | Should -Be 'Failed'
            $versionProbeFailure.Data.VersionExitCode | Should -Be 9
            $versionProbeFailure.Data.Output | Should -Match 'version query failed'
            $versionProbeFailure.Errors.Count | Should -Be 1
            @(Get-Content -LiteralPath $invocationLog | Where-Object { $_ -notmatch '^--version(?:\s|$)' }).Count | Should -Be $buildInvocationsBeforeProbeFailures.Count

            'unparseable' | Set-Content -LiteralPath $versionModePath -Encoding UTF8
            $context.Configuration.tools.hemtt.version = $null
            $detectUnparseable = & $descriptor.Invoke $context 'Detect'
            $detectUnparseable.Status | Should -Be 'Failed'
            $detectUnparseable.Data.VersionParseFailed | Should -BeTrue
            $detectUnparseable.Data.Output | Should -Match 'Unable to parse HEMTT version output'
            $detectUnparseable.Errors.Count | Should -Be 1
            $context.Configuration.tools.hemtt.version = '1.2.3'
            $versionProbeUnparseable = & $descriptor.Invoke $context 'Build'
            $versionProbeUnparseable.Status | Should -Be 'Failed'
            $versionProbeUnparseable.Data.VersionMismatch | Should -BeTrue
            $versionProbeUnparseable.Data.Output | Should -Match 'Unable to determine HEMTT version'
            $versionProbeUnparseable.Errors.Count | Should -Be 1
            @(Get-Content -LiteralPath $invocationLog | Where-Object { $_ -notmatch '^--version(?:\s|$)' }).Count | Should -Be $buildInvocationsBeforeProbeFailures.Count

            'normal' | Set-Content -LiteralPath $versionModePath -Encoding UTF8
            $context.Configuration.tools.hemtt.version = '2.0.0'
            $invocationLog = Join-Path $projectRoot 'invocations.log'
            $invocationsBeforeMismatch = @(Get-Content -LiteralPath $invocationLog | Where-Object { $_ -notmatch '^--version(?:\s|$)' })
            $versionMismatch = & $descriptor.Invoke $context 'Build'
            $versionMismatch.Status | Should -Be 'Failed'
            $versionMismatch.Data.Version | Should -Be '1.2.3'
            $versionMismatch.Data.ExpectedVersion | Should -Be '2.0.0'
            $versionMismatch.Data.Output | Should -Match 'version mismatch'
            $versionMismatch.Errors.Count | Should -Be 1
            $invocationsAfterMismatch = @(Get-Content -LiteralPath $invocationLog | Where-Object { $_ -notmatch '^--version(?:\s|$)' })
            $invocationsAfterMismatch.Count | Should -Be $invocationsBeforeMismatch.Count
            $context.Configuration.tools.hemtt.version = '1.2.3'
            $buildResult.Data.Arguments | Should -Contain 'build'
            $buildResult.Data.Output | Should -Match 'Mock received: build'
            $buildResult.Data.StandardOutput | Should -Match 'Mock received: build'
            $buildResult.Data.StandardError | Should -Match 'Mock stderr'
            $buildResult.Data.TimedOut | Should -BeFalse
            $buildResult.Data.Artifacts | Should -Contain (Join-Path $artifactDirectory 'generated.pbo')
            $buildResult.Data.Artifacts | Should -Not -Contain (Join-Path $artifactDirectory 'stale.pbo')

            foreach ($operationCase in @(
                @{ Operation = 'Check'; Command = 'check' },
                @{ Operation = 'Dev'; Command = 'dev' },
                @{ Operation = 'Release'; Command = 'release' },
                @{ Operation = 'Run'; Command = 'build' }
            )) {
                $locationBefore = (Get-Location).Path
                $operationResult = & $descriptor.Invoke $context $operationCase.Operation
                $operationResult.Status | Should -Be 'Passed'
                $operationResult.Data.Arguments[0] | Should -Be $operationCase.Command
                if ($operationCase.Operation -eq 'Check') {
                    $operationResult.Data.Arguments | Should -Contain '--pedantic'
                    $operationResult.Data.Arguments | Should -Contain '--error-on-all'
                    $operationResult.Data.Arguments | Should -Contain '--lints'
                    $operationResult.Data.Arguments | Should -Contain 's01-invalid-command'
                }
                else {
                    $operationResult.Data.Arguments | Should -Not -Contain '--pedantic'
                }
                (Get-Location).Path | Should -Be $locationBefore
            }

            $releaseOutput = Join-Path $projectRoot '.hemttout/release'
            $releaseArchives = Join-Path $projectRoot 'releases'
            New-Item -ItemType Directory -Path $releaseOutput -Force | Out-Null
            New-Item -ItemType Directory -Path $releaseArchives -Force | Out-Null
            'stale release pbo' | Set-Content -LiteralPath (Join-Path $releaseOutput 'stale-release.pbo') -Encoding UTF8
            'stale release zip' | Set-Content -LiteralPath (Join-Path $releaseArchives 'MockProject-stale.zip') -Encoding UTF8
            $releaseResult = & $descriptor.Invoke $context 'Release'
            $releaseResult.Status | Should -Be 'Passed'
            $releaseResult.Data.Artifacts | Should -Contain (Join-Path $releaseOutput 'generated-release.pbo')
            $releaseResult.Data.Artifacts | Should -Contain (Join-Path $releaseArchives 'MockProject-generated.zip')
            $releaseResult.Data.Artifacts | Should -Not -Contain (Join-Path $releaseOutput 'stale-release.pbo')
            $releaseResult.Data.Artifacts | Should -Not -Contain (Join-Path $releaseArchives 'MockProject-stale.zip')

            $context.Configuration.tools.hemtt.arguments = @('--same-metadata-change')
            $sameMetadataResult = & $descriptor.Invoke $context 'Build'
            $sameMetadataResult.Status | Should -Be 'Passed'
            $sameMetadataResult.Data.Artifacts | Should -Contain (Join-Path $artifactDirectory 'generated.pbo')

            $context.Configuration.tools.hemtt.arguments = @('--fail')
            $failureResult = & $descriptor.Invoke $context 'Build'
            $failureResult.Status | Should -Be 'Failed'
            $failureResult.Data.ExitCode | Should -Be 7
            $failureResult.Data.Output | Should -Match '--fail'
            $failureResult.Errors.Count | Should -Be 1

            'sleep' | Set-Content -LiteralPath $versionModePath -Encoding UTF8
            $context.Configuration.tools.hemtt.timeout_seconds = 1
            $versionProbeTimeout = & $descriptor.Invoke $context 'Build'
            $versionProbeTimeout.Status | Should -Be 'Failed'
            $versionProbeTimeout.Data.TimedOut | Should -BeTrue
            $versionProbeTimeout.Data.VersionExitCode | Should -Be 124
            $versionProbeTimeout.Data.Output | Should -Match 'version query timed out'
            $versionProbeTimeout.Errors.Count | Should -Be 1

            'normal' | Set-Content -LiteralPath $versionModePath -Encoding UTF8
            $context.Configuration.tools.hemtt.arguments = @('--sleep')
            $timeoutResult = & $descriptor.Invoke $context 'Build'
            $timeoutResult.Status | Should -Be 'Failed'
            $timeoutResult.Data.TimedOut | Should -BeTrue
            $timeoutResult.Data.ExitCode | Should -Be 124
            $timeoutResult.Errors.Count | Should -Be 1

            'sleep' | Set-Content -LiteralPath $versionModePath -Encoding UTF8
            $detectTimeoutResult = & $descriptor.Invoke $context 'Detect'
            $detectTimeoutResult.Status | Should -Be 'Failed'
            $detectTimeoutResult.Data.TimedOut | Should -BeTrue
            $detectTimeoutResult.Data.VersionExitCode | Should -Be 124
            $detectTimeoutResult.Data.ExitCode | Should -Be 124
            $detectTimeoutResult.Errors.Count | Should -Be 1
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

Describe 'Validation.Assets module' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repositoryRoot 'src/Core/ModuleManager.ps1')
        $assetDescriptor = & (Join-Path $repositoryRoot 'src/Modules/ValidationAssets/Module.ps1')
    }

    It 'passes when every configured project-relative asset exists' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Asset Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'addons/example') -Force | Out-Null
        'asset' | Set-Content -LiteralPath (Join-Path $projectRoot 'addons/example/model.p3d')
        try {
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ validation = @{ assets = @{ enabled = $true; severity = 'error'; references = @('addons/example/model.p3d') } } }
            }
            $result = & $assetDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Passed'
            $result.Data.CheckedCount | Should -Be 1
            $result.Data.Findings.Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails with a structured finding when an asset reference is missing' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Asset Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ validation = @{ assets = @{ enabled = $true; severity = 'error'; references = @('addons/missing.p3d') } } }
            }
            $result = & $assetDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Failed'
            $result.Errors.Count | Should -Be 1
            $result.Errors[0].Id | Should -Be 'ASSET_NOT_FOUND'
            $result.Errors[0].Path | Should -Be 'addons/missing.p3d'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'downgrades missing asset findings when severity is warning' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Asset Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ validation = @{ assets = @{ severity = 'warning'; references = @('missing.rvmat') } } }
            }
            $result = & $assetDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Warning'
            $result.Errors.Count | Should -Be 0
            $result.Warnings.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects references that escape the project root' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Asset Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $context = [pscustomobject]@{
                ProjectRoot = $projectRoot
                Configuration = @{ validation = @{ assets = @{ references = @('../outside.p3d') } } }
            }
            $result = & $assetDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Failed'
            $result.Errors[0].Id | Should -Be 'ASSET_PATH_OUTSIDE_PROJECT'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'skips cleanly when asset validation is disabled or no references are configured' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Asset Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $disabledContext = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ assets = @{ enabled = $false } } } }
            (& $assetDescriptor.Invoke $disabledContext 'Validate').Status | Should -Be 'Skipped'
            $emptyContext = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ assets = @{ references = @() } } } }
            $emptyResult = & $assetDescriptor.Invoke $emptyContext 'Validate'
            $emptyResult.Status | Should -Be 'Skipped'
            $emptyResult.Warnings.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'validates the asset reference manifest against the configuration schema' {
        $valid = @{ schema_version = 1; validation = @{ assets = @{ enabled = $true; severity = 'warning'; references = @('addons/example/model.p3d') } } }
        (Test-A3WorkflowConfiguration -Configuration $valid).IsValid | Should -BeTrue
        $invalid = @{ schema_version = 1; validation = @{ assets = @{ references = @(42) } } }
        (Test-A3WorkflowConfiguration -Configuration $invalid).IsValid | Should -BeFalse
    }
}


Describe 'Validation.Config module' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repositoryRoot 'src/Core/ModuleManager.ps1')
        . (Join-Path $repositoryRoot 'src/Core/Configuration.ps1')
        $configDescriptor = & (Join-Path $repositoryRoot 'src/Modules/ValidationConfig/Module.ps1')
    }

    It 'passes when required classes are declared in project config files' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Config Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'addons/example') -Force | Out-Null
        @'
class CfgPatches
{
    class Example_Addon
    {
        units[] = {};
    };
};
'@ | Set-Content -LiteralPath (Join-Path $projectRoot 'addons/example/config.cpp')
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ config = @{ enabled = $true; severity = 'error'; required_classes = @(@{ path = 'addons/example/config.cpp'; name = 'CfgPatches' }, @{ path = 'addons/example/config.cpp'; name = 'Example_Addon' }) } } } }
            $result = & $configDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Passed'
            $result.Data.CheckedCount | Should -Be 2
            $result.Data.Findings.Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not mistake class-like text in comments or strings for declarations' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Config Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        @'
// class FakeComment
/*
class FakeBlockComment
*/
class RealClass
{
    displayName = "class FakeString {";
};
'@ | Set-Content -LiteralPath (Join-Path $projectRoot 'config.cpp')
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ config = @{ required_classes = @(@{ path = 'config.cpp'; name = 'FakeComment' }, @{ path = 'config.cpp'; name = 'FakeBlockComment' }, @{ path = 'config.cpp'; name = 'FakeString' }) } } } }
            $result = & $configDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Failed'
            $result.Errors.Count | Should -Be 3
            $result.Errors.Id | Should -Contain 'CONFIG_CLASS_NOT_FOUND'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports missing config files and missing class declarations' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Config Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        'class PresentClass { };' | Set-Content -LiteralPath (Join-Path $projectRoot 'present.cpp')
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ config = @{ required_classes = @(@{ path = 'missing.cpp'; name = 'MissingFileClass' }, @{ path = 'present.cpp'; name = 'MissingClass' }) } } } }
            $result = & $configDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Failed'
            $result.Errors.Id | Should -Contain 'CONFIG_FILE_NOT_FOUND'
            $result.Errors.Id | Should -Contain 'CONFIG_CLASS_NOT_FOUND'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'supports warning severity and rejects paths outside the project root' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Config Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ config = @{ severity = 'warning'; required_classes = @(@{ path = 'missing.cpp'; name = 'MissingClass' }, @{ path = '../outside.cpp'; name = 'OutsideClass' }) } } } }
            $result = & $configDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Warning'
            $result.Errors.Count | Should -Be 0
            $result.Warnings.Id | Should -Contain 'CONFIG_FILE_NOT_FOUND'
            $result.Warnings.Id | Should -Contain 'CONFIG_PATH_OUTSIDE_PROJECT'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'skips when config validation is disabled or no class expectations are configured' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Config Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $disabled = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ config = @{ enabled = $false } } } }
            (& $configDescriptor.Invoke $disabled 'Validate').Status | Should -Be 'Skipped'
            $empty = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ config = @{ required_classes = @() } } } }
            $result = & $configDescriptor.Invoke $empty 'Validate'
            $result.Status | Should -Be 'Skipped'
            $result.Warnings.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'validates required config class entries against the configuration schema' {
        $valid = @{ schema_version = 1; validation = @{ config = @{ enabled = $true; severity = 'warning'; required_classes = @(@{ path = 'addons/example/config.cpp'; name = 'CfgPatches' }) } } }
        (Test-A3WorkflowConfiguration -Configuration $valid).IsValid | Should -BeTrue
        $invalid = @{ schema_version = 1; validation = @{ config = @{ required_classes = @(@{ path = 'config.cpp'; name = 42 }) } } }
        (Test-A3WorkflowConfiguration -Configuration $invalid).IsValid | Should -BeFalse
    }
}


Describe 'Validation.Dependencies module' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repositoryRoot 'src/Core/ModuleManager.ps1')
        . (Join-Path $repositoryRoot 'src/Core/Configuration.ps1')
        $dependencyDescriptor = & (Join-Path $repositoryRoot 'src/Modules/ValidationDependencies/Module.ps1')
    }

    It 'collects addon declarations and accepts internal and external requiredAddons references' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Dependency Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'addons/a') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'addons/b') -Force | Out-Null
        @'
class CfgPatches
{
    class Addon_A
    {
        requiredAddons[] = {"Addon_B", "A3_Data_F"};
    };
};
'@ | Set-Content -LiteralPath (Join-Path $projectRoot 'addons/a/config.cpp')
        @'
class CfgPatches
{
    class Addon_B
    {
        requiredAddons[] = {};
    };
};
'@ | Set-Content -LiteralPath (Join-Path $projectRoot 'addons/b/config.cpp')
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ dependencies = @{ config_files = @('addons/a/config.cpp', 'addons/b/config.cpp'); internal_addons = @('Addon_A', 'Addon_B'); severity = 'error' } } } }
            $result = & $dependencyDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Passed'
            $result.Data.DeclaredAddons | Should -Contain 'Addon_A'
            $result.Data.DeclaredAddons | Should -Contain 'Addon_B'
            $result.Data.ExternalDependenciesIgnored | Should -BeTrue
            $result.Data.Findings.Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports missing internal addons referenced by requiredAddons' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Dependency Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        @'
class CfgPatches
{
    class Addon_A
    {
        requiredAddons[] = {"Addon_Missing", "A3_Data_F"};
    };
};
'@ | Set-Content -LiteralPath (Join-Path $projectRoot 'config.cpp')
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ dependencies = @{ config_files = @('config.cpp'); internal_addons = @('Addon_A', 'Addon_Missing'); severity = 'error' } } } }
            $result = & $dependencyDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Failed'
            $result.Errors.Id | Should -Contain 'DEPENDENCY_INTERNAL_ADDON_MISSING'
            ($result.Errors | Where-Object { $_.Addon -eq 'Addon_Missing' }).ReferencedBy | Should -Contain 'Addon_A'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'detects duplicate addon declarations across config files' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Dependency Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'one') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'two') -Force | Out-Null
        @'
class CfgPatches
{
    class Duplicate_Addon
    {
        requiredAddons[] = {};
    };
};
'@ | Set-Content -LiteralPath (Join-Path $projectRoot 'one/config.cpp')
        @'
class CfgPatches
{
    class Duplicate_Addon
    {
        requiredAddons[] = {};
    };
};
'@ | Set-Content -LiteralPath (Join-Path $projectRoot 'two/config.cpp')
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ dependencies = @{ config_files = @('one/config.cpp', 'two/config.cpp'); internal_addons = @('Duplicate_Addon') } } } }
            $result = & $dependencyDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Warning'
            $result.Warnings.Id | Should -Contain 'DEPENDENCY_ADDON_DUPLICATE'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ignores class-like text in comments and quoted strings' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Dependency Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        @'
// class CfgPatches { class FakeLine {}; }
/*
class CfgPatches { class FakeBlock {}; };
*/
class CfgPatches
{
    class Real_Addon
    {
        requiredAddons[] = {"A3_Data_F"};
        description = "class FakeString { }";
    };
};
'@ | Set-Content -LiteralPath (Join-Path $projectRoot 'config.cpp')
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ dependencies = @{ config_files = @('config.cpp'); internal_addons = @('Real_Addon') } } } }
            $result = & $dependencyDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Passed'
            $result.Data.DeclaredAddons | Should -Contain 'Real_Addon'
            $result.Data.DeclaredAddons.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports missing files, missing CfgPatches, and path traversal' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Dependency Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        'class SomeOtherConfig { };' | Set-Content -LiteralPath (Join-Path $projectRoot 'other.cpp')
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ dependencies = @{ config_files = @('missing.cpp', 'other.cpp', '../outside.cpp'); internal_addons = @() } } } }
            $result = & $dependencyDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Warning'
            $result.Warnings.Id | Should -Contain 'DEPENDENCY_CONFIG_FILE_NOT_FOUND'
            $result.Warnings.Id | Should -Contain 'DEPENDENCY_CFGPATCHES_NOT_FOUND'
            $result.Warnings.Id | Should -Contain 'DEPENDENCY_PATH_OUTSIDE_PROJECT'
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'skips when disabled or no config files are configured' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Dependency Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $disabled = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ dependencies = @{ enabled = $false } } } }
            (& $dependencyDescriptor.Invoke $disabled 'Validate').Status | Should -Be 'Skipped'
            $empty = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ dependencies = @{ config_files = @(); internal_addons = @() } } } }
            $result = & $dependencyDescriptor.Invoke $empty 'Validate'
            $result.Status | Should -Be 'Skipped'
            $result.Warnings.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'supports warning severity and validates dependency settings against the schema' {
        $projectRoot = Join-Path ([IO.Path]::GetTempPath()) ("Dependency Validation " + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        try {
            $context = [pscustomobject]@{ ProjectRoot = $projectRoot; Configuration = @{ validation = @{ dependencies = @{ severity = 'warning'; config_files = @('absent.cpp'); internal_addons = @() } } } }
            $result = & $dependencyDescriptor.Invoke $context 'Validate'
            $result.Status | Should -Be 'Warning'
            $result.Errors.Count | Should -Be 0
            $result.Warnings.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
        $valid = @{ schema_version = 1; validation = @{ dependencies = @{ enabled = $true; severity = 'warning'; config_files = @('addons/a/config.cpp'); internal_addons = @('Addon_A') } } }
        (Test-A3WorkflowConfiguration -Configuration $valid).IsValid | Should -BeTrue
        $invalid = @{ schema_version = 1; validation = @{ dependencies = @{ config_files = @(42); internal_addons = @('bad addon') } } }
        (Test-A3WorkflowConfiguration -Configuration $invalid).IsValid | Should -BeFalse
    }
}
