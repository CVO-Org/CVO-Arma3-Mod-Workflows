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

## Asset validation module

The first framework-owned validator is discovered as `Validation.Assets` when `modules.validation.enabled` is true. It supports the `Validate` operation and checks an explicit manifest of project-relative file paths. It does not scan SQF/config text automatically, and it does not replace HEMTT checks.

Add local assets that must exist to `validation.assets.references`:

    {
      "schema_version": 1,
      "validation": {
        "assets": {
          "enabled": true,
          "severity": "error",
          "references": [
            "addons/example/models/example.p3d",
            "addons/example/data/example_co.paa"
          ]
        }
      }
    }

Absolute paths and references that resolve outside the project root are rejected. Each configured path must resolve to a file. Engine-provided paths (for example `\\a3\\...`) should not be listed. An empty list is reported as `Skipped`, not `Passed`. Set severity to `warning` to report missing references without failing validation.

Run it with:

    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Validate -Module Validation.Assets

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


## Reusable HEMTT workflow

The repository provides a callable Windows workflow at `.github/workflows/hemtt.yml`. A consuming repository can call it from its own workflow:

    name: Mod CI

    on:
      push:
        branches: [main]
      pull_request:

    jobs:
      hemtt:
        uses: SkippieDippie/Arma3-Mod-Workflows/.github/workflows/hemtt.yml@YOUR_FRAMEWORK_REF
        with:
          framework-ref: YOUR_FRAMEWORK_REF
          operation: Check
          hemtt-version: v1.21.0

Replace `YOUR_FRAMEWORK_REF` in both places with the same immutable framework tag or commit SHA. The `uses` reference selects the reusable workflow; `framework-ref` separately tells the workflow which revision of the framework source to check out. Do not use a moving branch for production consumers.

Supported inputs:

- `operation`: `Detect`, `Check`, `Dev`, `Build`, or `Release` (default `Build`).
- `framework-ref`: required immutable tag or commit SHA matching the `uses` reference.
- `hemtt-version`: HEMTT version installed by the pinned `arma-actions/hemtt` action (default `v1.21.0`).
- `project-root`: consuming project directory relative to the checkout root (default `.`).
- `config-path`: optional configuration path passed to the framework CLI.
- `artifact-path`: optional custom artifact glob or multiline list; otherwise the workflow uploads the HEMTT operation's standard output directory. Release also uploads the project-level `releases/` directory when present.
- `fail-on-warning`: optionally make framework warnings fail the job.

The workflow requests only `contents: read`. It does not receive publishing secrets, create GitHub Releases, publish to Steam Workshop, or attempt to run Arma 3. The HEMTT setup action is pinned to a commit SHA. Artifact upload is required for Dev/Build/Release output (and fails if the expected primary output is absent); the additional project-level release directory is optional.


## Reusable validation workflow

The repository provides a callable Windows validation workflow at `.github/workflows/validate.yml`. A consuming project can call it from its own workflow:

    name: Mod validation

    on:
      push:
        branches: [main]
      pull_request:

    jobs:
      validate:
        uses: SkippieDippie/Arma3-Mod-Workflows/.github/workflows/validate.yml@YOUR_FRAMEWORK_REF
        with:
          framework-ref: YOUR_FRAMEWORK_REF

Replace `YOUR_FRAMEWORK_REF` in both places with the same immutable framework tag or commit SHA. The `uses` reference selects the reusable workflow; `framework-ref` separately selects the source revision checked out by that workflow. Do not use a moving branch for production consumers.

Inputs:

- `framework-ref`: required immutable framework tag or commit SHA.
- `project-root`: consuming project directory relative to the caller workspace (default `.`).
- `config-path`: optional framework configuration path relative to project root.
- `modules`: comma- or newline-separated module IDs. Defaults to `Validation.Assets`, `Validation.Config`, `Validation.Dependencies`, `Validation.SQF`, and `Validation.Package`.
- `fail-on-warning`: optionally fail when a selected module reports warnings (default `false`).
- `fail-on-skipped`: fail when any selected module is skipped (default `true`). This prevents an empty manifest or missing optional validator from being treated as successful validation. Set to `false` only when skipping is intentional.

The consuming project must configure the manifests required by its selected validators. For example, asset references, required config classes, SQF files, and PBO artifacts are all explicit; the framework does not assume a mod-specific directory layout. If a selected validator has no work configured, it reports `Skipped`, and the reusable workflow fails by default.

The workflow requests only `contents: read`. It does not build, run Arma 3, publish releases, or require publishing secrets.


## Reusable SQF-VM test workflow

The repository provides a callable Windows runtime-test workflow at `.github/workflows/test.yml`. A consuming project can call it from its own workflow:

    name: Mod tests

    on:
      push:
        branches: [main]
      pull_request:

    jobs:
      sqfvm:
        uses: SkippieDippie/Arma3-Mod-Workflows/.github/workflows/test.yml@YOUR_FRAMEWORK_REF
        with:
          framework-ref: YOUR_FRAMEWORK_REF
          sqfvm-version: v2026.04.03-ed9f5f5

Replace `YOUR_FRAMEWORK_REF` in both places with the same immutable framework tag or commit SHA. The workflow separately installs the selected SQF-VM release from its official GitHub release archive.

Inputs:

- `framework-ref`: required immutable framework tag or commit SHA.
- `sqfvm-version`: SQF-VM release tag to install (default `v2026.04.03-ed9f5f5`).
- `project-root`: consuming project directory relative to the caller workspace (default `.`).
- `config-path`: optional framework configuration path relative to project root.
- `fail-on-skipped`: fail if no test scripts run or SQF-VM execution is skipped (default `true`).

The consuming project must configure `testing.sqfvm.files` with explicit project-relative `.sqf` test scripts. Optional config inputs are listed in `testing.sqfvm.config_files`. Test scripts must implement meaningful assertions and set a nonzero exit code on failure. A successful process exit alone cannot prove that assertions were actually performed.

Each configured test script runs in its own SQF-VM process. This is SQF-VM runtime testing, not an Arma 3 engine test; engine commands and game integration still require in-game validation.

## Current limitations

- YAML requires `powershell-yaml`; JSON does not.
- The HEMTT and validation reusable workflows are available; testing workflow composition and release publication orchestration are not yet implemented.
- HEMTT output is captured after process completion; live streaming log forwarding and configurable artifact-copying are future work.
- The schema evaluator intentionally implements the keywords used by the current schema, not the entire JSON Schema specification. New schema keywords require matching implementation and tests.


## Config contract validation module

The framework discovers `Validation.Config` when `modules.validation.enabled` is true. It checks explicitly declared class expectations in config source files; it does not parse the full Arma config language or duplicate HEMTT's checks.

Configure required class declarations:

    {
      "schema_version": 1,
      "validation": {
        "config": {
          "enabled": true,
          "severity": "error",
          "required_classes": [
            { "path": "addons/example/config.cpp", "name": "CfgPatches" },
            { "path": "addons/example/config.cpp", "name": "Example_Addon" }
          ]
        }
      }
    }

Paths must be project-relative and remain inside the project root. The class check recognizes declarations with a class body, including nested declarations, and ignores class-like text in comments and quoted strings. It does not resolve inheritance or preprocessor macros. An empty list is reported as `Skipped`, not `Passed`. Set severity to `warning` to report missing config files or classes without failing validation.

Run it with:

    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Validate -Module Validation.Config


## Addon dependency validation module

The framework discovers `Validation.Dependencies` when `modules.validation.enabled` is true. It reads explicitly configured config source files, collects addon classes declared in `CfgPatches`, and inspects their `requiredAddons[]` arrays.

Configure the files to inspect and identify addon names owned by your project:

    {
      "schema_version": 1,
      "validation": {
        "dependencies": {
          "enabled": true,
          "severity": "warning",
          "config_files": [
            "addons/core/config.cpp",
            "addons/vehicles/config.cpp"
          ],
          "internal_addons": [
            "Example_Core",
            "Example_Vehicles"
          ]
        }
      }
    }

The validator detects duplicate addon class declarations and internal addon names that are missing from the configured source files. A `requiredAddons[]` entry is checked as an internal dependency only when its name appears in `internal_addons`; other names are treated as external (including Arma engine and third-party mod dependencies) and are not reported missing. Paths must be project-relative and remain inside the project root. Empty `config_files` is reported as `Skipped`, not `Passed`.

The initial implementation reads literal `CfgPatches` declarations. It does not evaluate preprocessor macros or conditional compilation, and it does not replace HEMTT's config checks.

Run it with:

    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Validate -Module Validation.Dependencies


## SQF syntax validation module

The framework discovers \`Validation.SQF\` when \`modules.validation.enabled\` is true. It uses SQF-VM in **automated parse-only mode** to preprocess and parse explicitly configured \`.sqf\` files. It does not execute the source scripts during this validation operation. SQF-VM is an external optional dependency; it is not installed automatically.

Configure the files to inspect and the executable location:

    {
      "schema_version": 1,
      "validation": {
        "sqf": {
          "enabled": true,
          "severity": "error",
          "files": [
            "addons/example/functions/fn_init.sqf",
            "addons/example/functions/fn_update.sqf"
          ]
        }
      },
      "tools": {
        "sqfvm": {
          "path": "tools/sqfvm.exe",
          "required": false,
          "timeout_seconds": 600
        }
      }
    }

The manifest avoids assuming a particular source directory layout. Paths must be project-relative, remain inside the project root, exist, and use the \`.sqf\` extension. The adapter invokes SQF-VM once per file with \`--automated\`, \`--parse-only\`, and \`--input-sqf\`; it captures standard output, standard error, exit code, process duration, and timeout state. It does not treat a parse-only success as proof of runtime correctness or Arma 3 engine compatibility.

Set \`tools.sqfvm.required\` to \`true\` to fail when the executable is unavailable; otherwise the module is skipped. The executable can be configured explicitly or resolved from \`PATH\` (\`sqfvm\`, \`sqfvm_x64\`, or their Windows executable names). A project-relative executable path is resolved against the project root. \`.ps1\` wrappers are supported for tests and custom launchers. \`tools.sqfvm.arguments\` appends additional arguments to each invocation; do not use it to override the adapter's automated or parse-only mode. The current upstream CLI documents command-line usage through \`-?\`; the adapter deliberately does not claim version pinning until a stable version-query contract is verified.

SQF-VM implements a substantial subset of SQF but does not implement every Arma engine command. Its own documentation recommends checking command support with \`help__\`. Scripts that depend on unsupported engine commands may require test harness stubs or in-game testing. Runtime/unit-test execution should be implemented separately from this syntax-validation module so validation does not accidentally execute arbitrary mod initialization code.

Run it with:

    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Validate -Module Validation.SQF




## PBO package validation

The `Validation.Package` module inspects explicitly configured PBO build artifacts. It does not assume a particular build-output directory and does not invoke HEMTT; run it after the build step has produced the package.

Example configuration:

    {
      "schema_version": 1,
      "validation": {
        "package": {
          "enabled": true,
          "severity": "error",
          "artifacts": [
            "releases/example.pbo",
            {
              "path": ".hemttout/release/example.pbo",
              "required_entries": ["config.cpp", "stringtable.xml"]
            }
          ]
        }
      }
    }

Each artifact path must be project-relative, remain inside the project root, exist, and use the `.pbo` extension. The validator inspects the PBO header and entry metadata, verifies that declared data sizes fit within the artifact, and accepts an optional 5-byte legacy checksum or 21-byte Arma signature record by length and zero-byte prefix only. Required entries are matched case-insensitively with slash normalization. Set severity to `warning` to report findings without failing the module. An empty artifact list is `Skipped`, not `Passed`.

This is not a full PBO extractor or Arma package-load test. It does not decrypt or decompress entries, cryptographically verify the optional checksum, validate signatures, or prove engine compatibility. Those checks still require the appropriate packaging tools and in-game validation.

Run it after building:

    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Validate -Module Validation.Package

## SQF-VM automated tests

The `Testing.SQFVM` module executes only the scripts explicitly listed in `testing.sqfvm.files`. It validates the complete test and config-file manifest before launching any process, then runs one fresh SQF-VM process per script, optionally loading configured `.cpp` config inputs first. It captures stdout, stderr, exit code, duration, and timeout state. The process timeout is controlled by `tools.sqfvm.timeout_seconds`; `testing.sqfvm.max_runtime_ms` optionally supplies SQF-VM's own per-process runtime limit (zero means unlimited inside SQF-VM, while the process timeout still applies). `tools.sqfvm.arguments` may add other SQF-VM options, but runner-controlled options (`--automated`, `--suppress-welcome`, `--no-execute-print`, `--parse-only`, `--input-sqf`, `--input-config`, and `--max-runtime`) are reserved and rejected there so additional arguments cannot silently change execution mode.

Example configuration:

    {
      "schema_version": 1,
      "testing": {
        "sqfvm": {
          "enabled": true,
          "files": ["tests/sqfvm/test_main.sqf"],
          "config_files": ["addons/example/config.cpp"],
          "max_runtime_ms": 30000
        }
      },
      "tools": {
        "sqfvm": {
          "path": "tools/sqfvm.exe",
          "required": true,
          "timeout_seconds": 60
        }
      }
    }

Run tests explicitly with:

    ./src/Invoke-Arma3ModWorkflows.ps1 -ProjectRoot . -Operation Test -Module Testing.SQFVM

Each test script is executed (not parse-only) as an SQF-VM input. The script is responsible for its assertions and must communicate failure through SQF-VM's process exit code (for example, by calling `exitcode__` with a nonzero failure count). A script that merely logs a failed assertion but exits with code zero will be treated as passed. Scripts run in separate processes, so VM state is not shared between files. The framework does not load mod initialization files automatically, discover tests, or claim complete Arma 3 engine compatibility. SQF-VM supports a subset of SQF commands; engine-dependent behavior still needs in-game tests.
