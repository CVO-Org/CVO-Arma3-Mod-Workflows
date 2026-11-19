# Validation architecture

## Goals

Validation adds checks that identify project defects before a build or release. It must work with existing project layouts, remain opt-in, produce actionable diagnostics, and never modify project files.

Validation is additive to HEMTT, not a replacement for it. HEMTT remains responsible for its own project checks and packaging rules. The framework must not run an equivalent check twice merely because it is exposed through another command.

## Pipeline and ownership

The framework uses the existing module execution pipeline. A validation run uses the `Check` operation:

1. The HEMTT module runs `hemtt check` when it is enabled and available. HEMTT documents that this runs the same checks as `hemtt dev` without writing files; its `--pedantic` option enables additional lints, and `--error-on-all` promotes help and warning messages to errors.
2. Framework validation modules run checks that are demonstrably outside HEMTT's checks, or checks whose diagnostics or policy need to be standardized by the framework.
3. The core normalizes each module result and applies the existing exit-code policy.

Validation modules must not invoke HEMTT a second time. They must not silently build or package the project. A package validation check may inspect an artifact supplied by an earlier build, but it must not trigger that build itself.

## Check categories

The configuration already reserves these categories under `validation`:

| Category | Responsibility | Initial ownership |
| --- | --- | --- |
| `sqf` | SQF source analysis beyond HEMTT's configured lint checks | Evaluate additional analyzers only where they provide distinct coverage; do not assume SQF-VM is a static linter |
| `config` | Config-specific structural and reference checks not covered by HEMTT | Framework checks and optional parsers |
| `assets` | Missing or incorrectly referenced project assets | Framework checks; initial implementation validates an explicit project-relative reference manifest |
| `dependencies` | Declared addon/mod dependency consistency | Framework checks |
| `package` | Inspection of an existing build/package artifact | Framework checks and format-aware tools |

Each category can be disabled independently. The existing `severity` setting controls whether a finding is treated as an error or warning. A category disabled by configuration is not a passing check; it is reported as skipped or omitted with an explicit reason.

The initial implementation should be incremental. A category must not claim coverage until its checks and fixtures exist. Tool-backed checks must detect the executable and version before execution, use configured timeouts, capture stdout/stderr, and return structured failures. Tools are never downloaded or installed automatically.

## Initial asset validation scope

The first framework-owned validator is `Validation.Assets`. It checks the explicit list in `validation.assets.references` against files inside the consuming project root. References must be project-relative; absolute paths and paths that escape the project root are rejected. This avoids guessing which strings in SQF/config files are file references and avoids false positives for Arma engine paths such as `\\a3\\...`.

The initial manifest is intentionally explicit rather than an automatic source scanner. Projects should add only local assets that are expected to exist in their repository. Engine-provided assets and runtime-generated files should not be listed. Empty manifests are reported as skipped, not passed, so a project cannot mistake an unconfigured check for coverage. The configured severity determines whether a missing reference is an error or warning.

## Normalized finding contract

Validation modules return the existing module-result object. Their `Data` should contain:

- `Checks`: one entry per check that was actually evaluated.
- `Findings`: actionable diagnostics produced by those checks.
- `Tools`: tool identity and detected version for tool-backed checks, when applicable.

A finding uses these fields where applicable:

- `Id`: stable check identifier.
- `Severity`: `error` or `warning`.
- `Message`: concise explanation.
- `Path`: project-relative file path.
- `Line` and `Column`: source location when available.
- `Tool`: validator that produced the finding.

A finding with severity `error` makes its module result `Failed`; a warning-only result is `Warning`. Tool absence is not itself a source finding: optional tools produce a clear `Skipped` result, while tools explicitly marked required produce `Failed`. Process startup errors, nonzero exits, timeouts, and malformed tool output are failures, not clean validation results.

## Configuration and compatibility

The current configuration schema already defines the validation categories and optional `sqfvm` and `sqflint` tool entries. SQF-VM is an SQF virtual machine intended for execution and unit-testing scenarios, not a drop-in static linter; its supported Arma command coverage must be considered before using it to validate production scripts. SQFLint describes itself as a basic SQF syntax checker and has a Java runtime requirement. Their command-line contracts, maintenance status, and diagnostic formats must be verified and tested before either tool is invoked by the framework. Tool paths may be configured explicitly or resolved from `PATH`; relative paths resolve against the consuming project root.

The framework targets Windows PowerShell 5.1 and PowerShell 7. New validation code must remain compatible with both. Tests should use mock executables and temporary project trees; CI must not require Arma 3 or install proprietary game content.

## References

- [HEMTT check command](https://hemtt.dev/commands/check.html) — check behavior and lint-related options.
- [SQF-VM source repository](https://github.com/SQFvm/runtime) — virtual-machine scope and current project documentation.
- [SQFLint source repository](https://github.com/SkaceKamen/sqflint) — basic SQF syntax-checking scope and runtime requirements.

## Non-goals

- Replacing HEMTT's project checks or PBO packaging.
- Enforcing a common directory layout on consuming projects.
- Automatically installing external tools.
- Modifying source files to fix findings.
- Treating a skipped or unavailable check as a pass.
