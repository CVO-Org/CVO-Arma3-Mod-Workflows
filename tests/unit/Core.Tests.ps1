$coreRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Core'

Describe 'Arma3 Mod Workflows core' {
    BeforeAll {
        . (Join-Path $coreRoot 'Logging.ps1')
        . (Join-Path $coreRoot 'Configuration.ps1')
        . (Join-Path $coreRoot 'ModuleManager.ps1')
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
}
