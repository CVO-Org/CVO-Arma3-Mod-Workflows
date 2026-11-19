# Validation architecture

## Goals

Validation adds checks that identify project defects before a build or release. It must work with existing project layouts, remain opt-in, produce actionable diagnostics, and never modify project files.

Validation is additive to HEMTT, not a replacement for it. HEMTT remains responsible for its own project checks and packaging rules. The framework must not run an equivalent check twice merely because it is exposed through another command.

## Pipeline and ownership

The framework uses the existing module execution pipeline. A validation run uses the `Check` operation:

1. The HEMTT module runs `hemtt check` when it is enabled and available.
2. Framework validation modules run checks that HEMTT does not already provide, or checks whose diagnostics or policy need to be standardized by the framework.
3. The core normalizes each module result and applies the existing exit-code policy.

Validation modules must not invoke HEMTT a second time. They must not silently build or package the project. A package validation check may inspect an artifact supplied by an earlier build, but it must not trigger that build itself.

## Check categories

The configuration already reserves these categories under `validation`:

| Category | Responsibility | Initial ownership |
| --- | --- | --- |
| `sqf` | SQF source analysis beyond checks already performed by HEMTT | Optional dedicated analyzer; capability-detected |
| `config` | Config-specific structural and reference checks not covered by HEMTT | Framework checks and optional parsers |
| `assets` | Missing or incorrectly referenced project assets | Framework checks |
| `dependencies` | Declared addon/mod dependency consistency | Framework checks |
| `package` | Inspection of an existing build/package artifact | Framework checks and format-aware tools |

Each category can be disabled independently. The existing `severity` setting controls whether a finding is treated as an error or warning. A category disabled by configuration is not a passing check; it is reported as skipped or omitted with an explicit reason.

The initial implementation should be incremental. A category must not claim coverage until its checks and fixtures exist. Tool-backed checks must detect the executable and version before execution, use configured timeouts, capture stdout/stderr, and return structured failures. Tools are never downloaded or installed automatically.

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

The current configuration schema already defines the validation categories and the optional `sqfvm` and `sqflint` tool entries. Their command-line contracts must be documented and tested before either tool is invoked by the framework. Tool paths may be configured explicitly or resolved from `PATH`; relative paths resolve against the consuming project root.

The framework targets Windows PowerShell 5.1 and PowerShell 7. New validation code must remain compatible with both. Tests should use mock executables and temporary project trees; CI must not require Arma 3 or install proprietary game content.

## Non-goals

- Replacing HEMTT's project checks or PBO packaging.
- Enforcing a common directory layout on consuming projects.
- Automatically installing external tools.
- Modifying source files to fix findings.
- Treating a skipped or unavailable check as a pass.
