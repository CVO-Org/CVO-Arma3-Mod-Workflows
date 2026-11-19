# Core usage

The initial core targets Windows PowerShell 5.1.

## Configuration

The default configuration filename is arma3-workflows.yml. YAML parsing requires the optional powershell-yaml module:

    Install-Module powershell-yaml -Scope CurrentUser

JSON is also supported without an additional parser. Use arma3-workflows.json or pass an explicit path with ConfigPath.

The initial runtime checks schema_version, known top-level properties, and core value types. The JSON Schema remains the canonical machine-readable contract; full JSON Schema evaluation will be added to CI.

## Initialize

    . .\path\to\Arma3-Mod-Workflows\src\Core\Initialize.ps1
    $context = Initialize-A3Workflow -ProjectRoot (Get-Location).Path -EnableConsoleLog

The returned context contains the project root, framework root, configuration, logger, and module registry.

## Register and run a module

    Register-A3WorkflowModule -Registry $context.Registry -Id 'Example.Check' -Operations @('Run') -Invoke {
        param($Context, $Operation)
        Write-A3WorkflowLog -Logger $Context.Logger -Level Info -Module 'Example.Check' -Message 'Example module ran.'
        return @{ Checked = $true }
    }
    $results = Invoke-A3WorkflowModules -Registry $context.Registry -Context $context -Operation Run

Modules execute in dependency order. Missing dependencies and circular dependencies are preflight errors. Module exceptions are converted into failed results.

## Current limitations

- Full JSON Schema evaluation is not yet embedded in the Windows PowerShell 5.1 runtime.
- YAML requires powershell-yaml; JSON does not.
- No build, validation, testing, or release capability modules are registered yet.
- Module registration is explicit; automatic discovery will follow after the contract is tested.
