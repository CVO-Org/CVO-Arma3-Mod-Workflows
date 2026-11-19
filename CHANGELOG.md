# Changelog

All notable changes to this project will be documented in this file.

The project follows Semantic Versioning once the first stable release is published.

## Unreleased

### Added
- Initial repository foundation, architecture documentation, configuration schema, and baseline defaults.
- Importable PowerShell module and CLI for configuration loading, structured JSONL logging, module discovery, dependency ordering, and normalized execution results.
- HEMTT build module with executable discovery, semantic-version detection and pinning, project configuration checks, check/dev/build/release commands, process timeouts, output capture, artifact change tracking, and check-only CLI arguments for pedantic linting and warning promotion.
- Validation architecture defining category ownership, HEMTT boundaries, normalized findings, severity handling, and optional tool requirements.
- Initial `Validation.Assets` module for explicit project-relative asset reference manifests, including missing-file and path-escape findings.
- Initial `Validation.Config` module for explicit required config class declarations, with comment/string filtering, path-safety checks, severity handling, and structured findings.
- Initial `Validation.Dependencies` module for `CfgPatches` addon declarations, literal `requiredAddons[]` references, duplicate detection, and explicit internal-addon consistency checks.
- Initial `Validation.SQF` adapter for SQF-VM automated parse-only validation, with explicit source manifests, process output capture, timeouts, and optional-tool handling.
- Initial `Testing.SQFVM` module for explicit SQF test-script execution in isolated processes, optional config inputs, runtime/process timeouts, output capture, and exit-code-based pass/fail reporting.
- Initial `Validation.Package` module for explicit PBO artifact manifests, path safety, structural header and data-boundary checks, and optional required-entry verification.
- Pester unit and integration coverage for core behavior and HEMTT process execution, failure handling, and artifact reporting.
- Windows CI coverage for PowerShell 7 and a dedicated Windows PowerShell 5.1 compatibility smoke test covering HEMTT, SQF-VM validation/testing, and PBO package inspection.
- Reusable Windows HEMTT GitHub Actions workflow with pinned HEMTT setup action, explicit framework-ref pin, operation inputs, and build artifact uploads.
- Reusable Windows validation GitHub Actions workflow for explicit asset, config, dependency, SQF, and PBO validation manifests, with configurable module selection and fail-on-skipped policy.
- Reusable Windows SQF-VM runtime testing workflow with an explicit SQF-VM release input, SHA-256 archive verification, test-manifest execution, and fail-on-skipped policy.
- Reusable release workflow that builds once, creates a GitHub Release draft, optionally updates an existing Arma 3 Workshop item through PublisherCmd, verifies release payload hashes, and publishes the GitHub Release only after all enabled destinations succeed.
- Private-framework checkout authentication for reusable workflows through a narrowly scoped `framework-token` secret.
- Core, HEMTT, validation, and reusable workflow usage documentation.

### Notes
- HEMTT is the first build capability module. Framework-owned validation includes explicit asset references, config class contracts, addon dependency checks, and SQF-VM parse-only validation. Initial SQF-VM runtime test execution and structural PBO package validation are available. Release orchestration builds once and coordinates GitHub and optional Steam publication; Steam requires a pre-authenticated self-hosted Windows runner and an existing Workshop item.
- HEMTT is an external dependency and is not downloaded or installed by the framework.
