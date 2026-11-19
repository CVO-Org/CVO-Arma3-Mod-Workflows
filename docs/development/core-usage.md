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

## HEMTT build module

The initial HEMTT module is discovered as `Build.HEMTT` when the framework's `build` module is enabled. It supports the operations `Detect`, `Check`, `Dev`, `Build`, `Release`, and the default `Run` operation (mapped to `hemtt build`).

Configure the executable when it is not available on `PATH`:

    {
      "schema_version": 1,
      "tools": {
        "hemtt": {
          "enabled": true,
          "path": "tools/hemtt.exe",
          "version": "1.21.0",
          "arguments": ["--no-color"],
          "check_arguments": ["--pedantic", "--error-on-all"],
          "timeout_seconds": 600
        }
      }
    }

The configured executable path may be absolute or relative to the project root. If omitted, the module searches for `hemtt.exe` or `hemtt` on `PATH`. HEMTT is optional by default: if it is unavailable, the operation is skipped. Set `tools.hemtt.required` to `true` to make a missing executable a failure. Set `tools.hemtt.version` to require an exact semantic HEMTT version (for example, `1.21.0`); malformed version pins are rejected by configuration validation, and each build/check operation verifies the installed version before running. `Detect` fails if HEMTT exits unsuccessfully or returns output that cannot be parsed as a semantic version. The optional `tools.hemtt.arguments` array appends shared CLI arguments to every invocation, including the `--version` preflight query, so use it only for options accepted by both the version query and the selected HEMTT commands. The optional `tools.hemtt.check_arguments` array is appended only to `hemtt check`; use it for check-only flags such as `--pedantic`, `--error-on-all`, or repeated `--lints` selections. These options are deliberately excluded from the version preflight and all other operations. HEMTT documents that `hemtt check` runs the same checks as `hemtt dev` without writing files, and that `--pedantic` enables additional lints. Build/check operations require the configured `paths.hemtt_config` file (default `.hemtt/project.toml`); `Detect` does not require a HEMTT project. Build-specific and release-specific behavior should be configured in `.hemtt/project.toml` using HEMTT's own configuration.

Examples:

    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Detect -Module Build.HEMTT
    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Check -Module Build.HEMTT
    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Dev -Module Build.HEMTT
    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Release -Module Build.HEMTT

HEMTT output, separate standard output and standard error, process exit code, executable path, timeout state, and output artifact paths are included in the module result. Processes run without a shell, in the project root, and are terminated after `tools.hemtt.timeout_seconds` (default: 600 seconds). On Windows, timeout cleanup attempts to terminate the full child-process tree with `taskkill /T /F`, then falls back to terminating the direct process. Process startup failures are returned in `Data.ProcessStartError` and `Data.StandardError` for diagnosis. Artifact reporting compares file paths, sizes, modification timestamps, and SHA-256 content hashes before and after execution, so unchanged files from earlier runs are excluded and same-size rewrites with preserved timestamps are still detected. Hashing adds file-read overhead for large output directories. The module scans `.hemttout/dev`, `.hemttout/build`, or `.hemttout/release` as appropriate; release operations also scan the project-level `releases` directory. HEMTT itself remains an external dependency; the framework does not download or install it.

## Current limitations

- YAML requires `powershell-yaml`; JSON does not.
- The HEMTT module is the first capability module; validation, testing, and release orchestration modules are not yet implemented.
- HEMTT output is captured after process completion; live streaming log forwarding and configurable artifact-copying are future work.
- The schema evaluator intentionally implements the keywords used by the current schema, not the entire JSON Schema specification. New schema keywords require matching implementation and tests.
