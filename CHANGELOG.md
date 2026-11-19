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
- Pester unit and integration coverage for core behavior and HEMTT process execution, failure handling, and artifact reporting.
- Windows CI coverage for PowerShell 7 and a dedicated Windows PowerShell 5.1 HEMTT compatibility smoke test.
- Core, HEMTT, and validation architecture documentation.

### Notes
- HEMTT is the first build capability module. Framework-owned validation now includes explicit asset references and config class contracts; package validation, SQF-VM runtime/unit-test orchestration, and release orchestration remain future work.
- HEMTT is an external dependency and is not downloaded or installed by the framework.
