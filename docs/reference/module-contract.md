# Module execution contract

This document defines the initial contract that framework modules must follow. The PowerShell implementation will formalize these concepts with shared types and helper functions.

## Module metadata

Every module must declare:

- a stable identifier, such as `Build.HEMTT` or `Validation.Assets`;
- a module version compatible with the framework contract;
- the operations it supports;
- required and optional configuration keys;
- external tool requirements;
- dependencies on other modules, if any.

Identifiers are case-insensitive for lookup but must be written consistently in metadata and reports.

## Execution context

The framework supplies a context containing:

- canonical project root;
- loaded and validated configuration;
- framework root and version;
- logger;
- resolved tool paths and versions;
- output/report directories;
- cancellation state where supported.

Modules must not independently reinterpret the project root or read secrets from configuration files.

## Result model

Each invocation returns a normalized result with:

| Field | Meaning |
|---|---|
| `Module` | Stable module identifier |
| `Operation` | Operation executed |
| `Status` | `Passed`, `Warning`, `Failed`, or `Skipped` |
| `Summary` | Short human-readable outcome |
| `Errors` | Structured error diagnostics |
| `Warnings` | Structured warning diagnostics |
| `StartedAt` | Start timestamp |
| `DurationMs` | Elapsed time in milliseconds |
| `Data` | Optional operation-specific structured output |

A diagnostic should include a message and, when available, a file path, line, column, rule identifier, and remediation hint.

## Status and exit-code rules

- **Passed:** operation completed and no warning/error threshold was exceeded.
- **Warning:** operation completed, but at least one warning was emitted.
- **Failed:** operation could not complete or an error-severity diagnostic was emitted.
- **Skipped:** operation was intentionally not run, such as a disabled module or unmet optional prerequisite.

A top-level command returns a non-zero process exit code when a required operation fails. Warnings do not fail by default; projects may configure stricter policies in a future schema revision. A skipped required operation must be treated as a failure, not silently accepted.

## Logging

Modules use the shared logger rather than writing ad hoc console output. Logs should include timestamp, severity, module identifier, and message. Secrets and authentication tokens must be redacted before logging.

## Side effects

Modules must:
- document files and directories they create or modify;
- write generated files only to configured output locations unless the operation explicitly targets a project file;
- avoid destructive cleanup unless the user invoked a cleanup operation;
- support a validation or dry-run mode where practical;
- return actionable diagnostics instead of swallowing exceptions.

## Dependency behavior

The module manager resolves dependencies before execution. A missing optional dependency results in a clear skip or warning. A missing required dependency fails preflight before module execution. Circular dependencies are configuration errors.
