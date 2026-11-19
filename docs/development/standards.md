# Development standards

## PowerShell

- Target Windows PowerShell 5.1 compatibility for baseline local tooling unless a module explicitly documents a PowerShell 7 requirement.
- Use approved PowerShell verbs and descriptive function names.
- Use `[CmdletBinding()]` for public functions and validate parameters.
- Prefer structured objects over formatted strings as function return values.
- Avoid global mutable state; pass the execution context explicitly.
- Use terminating errors for unrecoverable failures and normalize them at the command boundary.
- Never log credentials, access tokens, or secret environment values.

## Paths and filesystem behavior

- Resolve project-relative paths against the configured project root.
- Normalize paths before comparing them.
- Do not assume a consuming project's folder layout.
- Do not delete or overwrite user files during inspection or validation.
- Keep generated output in configured framework output directories.

## Configuration

- Validate configuration before running modules.
- Reject unknown keys unless the schema explicitly permits an extension/settings object.
- Keep secrets out of YAML and JSON configuration.
- Document defaults and the base used to resolve every path.
- Increment or migrate `schema_version` when compatibility changes.

## Diagnostics and logs

- Diagnostics must identify the responsible module.
- Include file/line/column information when the underlying tool provides it.
- Keep console output readable while also supporting machine-readable reports.
- Redact secrets and avoid dumping full environment variables.

## Tests

- Unit tests cover core functions and module contracts.
- Integration tests use controlled fixtures and must not depend on a developer's live mod directory.
- External-tool tests must detect prerequisites and clearly distinguish unavailable tools from failed checks.
- In-game test procedures should record game version, mod set, scenario, steps, expected result, observed result, and relevant RPT/log references.

## Git and releases

- Use semantic versioning for framework releases.
- Pin submodule and reusable workflow dependencies to tags or commit SHAs.
- Keep changes focused and document user-visible behavior in the changelog.
- Release artifacts must be traceable to a source tag and commit.
- GitHub and Steam publication must use the same version and built artifact; partial failures are recovered by retrying only the failed destination.

## Documentation

Public commands, configuration keys, module identifiers, prerequisites, side effects, and exit codes must be documented. Examples must not contain real credentials, personal access tokens, or private machine paths.
