# Core usage

The initial core targets Windows PowerShell 5.1 and PowerShell 7.

## Configuration

The default configuration filename is `arma3-workflows.yml`. YAML parsing requires the optional `powershell-yaml` module:

    Install-Module powershell-yaml -Scope CurrentUser

JSON is also supported without an additional parser. Use `arma3-workflows.json` or pass an explicit path with `ConfigPath`. Framework defaults from `config/defaults/configuration.json` are recursively merged with project values; project settings take precedence.

Configuration is validated against `config/schema/arma3-workflows.schema.json` during initialization. The runtime validator supports the schema keywords currently used by this repository: `$ref` (local references), `type`, `const`, `enum`, `required`, `properties`, `additionalProperties`, `minLength`, `pattern`, and `items`. When extending the schema, add corresponding validator support and tests before relying on a new keyword. JSON Schema's `default` annotation is descriptive; defaults are applied by the framework defaults file and recursive merge, not by schema evaluation.

## Initialize

    Import-Module .\src\Arma3ModWorkflows.psd1 -Force
    $context = Initialize-A3Workflow -ProjectRoot (Get-Location).Path -EnableConsoleLog

The returned context contains the project root, framework root, merged configuration, logger, module registry, and initialization timestamp.

## Register and run a module

    Register-A3WorkflowModule -Registry $context.Registry -Id 'Example.Check' -Operations @('Run') -Invoke {
        param($Context, $Operation)
        Write-A3WorkflowLog -Logger $Context.Logger -Level Info -Module 'Example.Check' -Message 'Example module ran.'
        return @{ Checked = $true }
    }
    $results = Invoke-A3WorkflowModules -Registry $context.Registry -Context $context -Operation Run

Modules execute in dependency order. Missing dependencies and circular dependencies are preflight errors. Module exceptions are converted into failed results; dependent modules are skipped when a dependency fails or is skipped. Results use the statuses `Passed`, `Warning`, `Failed`, and `Skipped`.

## Current limitations

- YAML requires `powershell-yaml`; JSON does not.
- Framework modules are discovered from immediate child folders of `src/Modules`, each containing a `Module.ps1` descriptor. Configuration uses `modules.<ConfigKey>.enabled`; absent keys default to enabled. Project-specific modules may still be registered explicitly.
- No build, validation, testing, or release capability modules are registered yet.
- A unified public command-line entry point is not yet implemented; the current public interface is the exported PowerShell module functions.
- The schema evaluator intentionally implements the keywords used by the current schema, not the entire JSON Schema specification. New schema keywords require matching implementation and tests.
