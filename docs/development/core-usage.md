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

## Command-line entry point

Run the framework from PowerShell:

    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -ListModules
    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Run
    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Run -Module Build.HEMTT

Use `-ConfigPath` to select a non-default configuration file, `-EnableConsoleLog` to mirror log messages to the console, and `-FailOnWarning` to return exit code 1 when a module reports a warning. Exit codes are 0 for success, 1 for failed module results or configured warning failure, and 2 for initialization or command errors.

## Current limitations

- YAML requires `powershell-yaml`; JSON does not.
- No build, validation, testing, or release capability modules are registered yet; the discovery mechanism and CLI are infrastructure only.
- The schema evaluator intentionally implements the keywords used by the current schema, not the entire JSON Schema specification. New schema keywords require matching implementation and tests.
