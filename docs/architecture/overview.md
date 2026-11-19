# Architecture overview

## Purpose

Arma 3 Mod Workflows supplies shared engineering infrastructure to multiple independent Arma 3 mod repositories. It is not a mod template, project generator, or replacement for HEMTT.

## Distribution model

The framework has two complementary delivery mechanisms:

1. **Git submodule:** distributes local PowerShell modules, schemas, helper scripts, and documentation. A consuming project pins the submodule to a known tag or commit.
2. **Reusable GitHub Actions:** centralizes CI and release workflow logic. Callable workflow files are stored directly in `.github/workflows/` (GitHub does not support subdirectories there). Consumers reference a tagged workflow revision or immutable commit SHA.

These mechanisms are versioned together but can be adopted independently where a project only needs one of them.

## Integration contract

A consuming repository:
- retains its existing directory structure;
- adds a root-level `arma3-workflows.yml` configuration file, unless a custom path is passed;
- explicitly enables the modules it wants;
- provides project-specific paths and tool overrides;
- supplies credentials only through the local environment or protected CI secrets.

The framework resolves paths relative to the consuming project root unless a setting explicitly documents another base.

## Runtime flow

```text
Entry point
  -> Resolve project root and configuration path
  -> Load defaults and project overrides
  -> Validate configuration against the versioned schema
  -> Initialize structured logging
  -> Resolve enabled modules and dependencies
  -> Execute requested operation
  -> Normalize module results
  -> Write summary and machine-readable report
  -> Return process exit code
```

Configuration or bootstrap errors stop execution before a module is invoked. A disabled module is reported as skipped, not passed.

## Module boundaries

Initial capability areas:

- **Build:** HEMTT discovery, configuration checks, build/release invocation, output collection.
- **Validation:** SQF, config, asset/reference, dependency, and package checks.
- **Testing:** automated tests supported by available tools, plus conventions and helpers for developer-run in-game tests.
- **Release:** version/changelog checks, package preparation, GitHub Release and Steam Workshop publication.
- **Utilities:** project inspection and other focused developer tools.

Each module declares its identifier, supported operations, configuration requirements, dependencies, and result format. Modules must not silently change files outside their declared output locations.

## Tool ownership

HEMTT remains the authoritative build and packaging tool when a project uses it. Other validators are selected for checks that HEMTT does not already perform or where a separate tool provides a distinct diagnostic. SQF-VM and other optional tools must be capability-detected and explicitly configurable; they are not assumed to be installed in every project.

See [Validation architecture](validation.md) for the validation pipeline, category ownership, normalized finding contract, and compatibility requirements.

## Execution environments

- **Local:** Windows-first, PowerShell interface, with clear prerequisite checks.
- **CI:** reusable GitHub Actions workflows, initially targeting Windows runners where tool compatibility requires it.
- **In-game:** test execution remains developer-operated initially. The framework can standardize test scenarios, logging, and result collection, but does not assume a hosted CI runner can launch and interact with a normal Arma 3 client.

## Release consistency

A release tag starts one release orchestration process. It validates the tag and project version, runs required checks, builds one release package, and publishes that version to GitHub Releases and Steam Workshop.

GitHub and Steam do not provide a shared transaction. Therefore:
- record the status of each publication target;
- never rebuild or increment the version merely because one destination failed;
- retry only the failed destination using the same version and artifact;
- treat the overall release as complete only when both enabled destinations report success;
- make publication steps safe to retry and detect an already-published version.

Steam credentials must be stored as protected secrets. Steam Guard or other interactive authentication requirements must be addressed in the release-runner setup; secrets must never be written to logs or committed files.

## Compatibility and versioning

The configuration schema has an explicit `schema_version`. Breaking changes to configuration or module contracts require a documented migration and a major framework version increment. Consumers should pin submodules and reusable workflows to immutable tags or commit SHAs rather than tracking a moving branch.
