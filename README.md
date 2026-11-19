# Arma 3 Mod Workflows

A reusable development, validation, testing, build, and release framework for Arma 3 mod projects.

The framework is designed to integrate with existing repositories without imposing a project directory layout. It is Windows-first for local development, uses PowerShell for local tooling, and provides reusable GitHub Actions workflows for CI/CD.

## Design principles

- **Integrate, don't restructure:** each consuming mod keeps its existing directory layout.
- **Opt in by module:** build, validation, testing, and release capabilities can be enabled independently.
- **Configuration over assumptions:** project-specific paths and tool settings live in `arma3-workflows.yml`.
- **One release process:** a tagged release validates and builds once, then publishes the same version to GitHub Releases and Steam Workshop, with recovery for partial publication.
- **Local and CI parity:** PowerShell commands and CI workflows should share the same underlying module behavior where practical.
- **No secrets in project configuration:** credentials are supplied through protected environment variables or GitHub Actions secrets.

## Repository layout

```text
.github/
  workflows/          Reusable GitHub Actions workflows (files must live directly here)
  ISSUE_TEMPLATE/
config/
  defaults/           Framework defaults
  schema/             Configuration schemas
docs/
  architecture/
  development/
  reference/
src/
  Core/               Bootstrap, configuration, logging, module contracts
  Modules/            Independently enabled capabilities
tests/
  unit/
  integration/
workflows/
```

Consuming projects may place the submodule wherever convenient and may keep their own source, build, and release directories.

## Getting started

Reusable workflow files live directly in `.github/workflows/`, as required by GitHub Actions; the separate top-level `workflows/` directory is intentionally not used for callable workflow definitions. The callable workflows are `hemtt.yml`, `validate.yml`, `test.yml`, and `release.yml`; see [workflow usage](docs/development/core-usage.md#reusable-release-workflow). The framework provides HEMTT build, validation, and SQF-VM test modules. The SQF-VM reusable workflow installs a selected Windows release and verifies its published SHA-256 digest before execution. The release workflow owns HEMTT release builds, version metadata preparation, ZIP packaging, GitHub Release asset publishing, and optional Steam Workshop uploads through `arma-actions/workshop-upload`. Steam credentials are supplied as `STEAM_USERNAME` and `STEAM_PASSWORD` repository secrets; no dedicated self-hosted runner is required.

A consuming project will eventually add the framework as a Git submodule, pin it to a release tag, and provide an `arma3-workflows.yml` file at its repository root (or pass an explicit configuration path).

## Configuration

See [the architecture overview](docs/architecture/overview.md) and [configuration schema](config/schema/arma3-workflows.schema.json). The schema is an initial contract and will evolve with explicit schema-version changes.

## Development status

The PowerShell module is available under `src/Arma3ModWorkflows.psd1`; the CLI entry point is `src/Invoke-Arma3ModWorkflows.ps1`. It supports JSON configuration out of the box; YAML requires the optional `powershell-yaml` module. Runtime configuration validation is driven by `config/schema/arma3-workflows.schema.json`. Framework modules are discovered from `src/Modules` and enabled through the `modules` configuration section.

The `Build.HEMTT` module supports HEMTT detection, version pinning, project configuration checks, check/dev/build/release operations, process timeouts, and artifact reporting. HEMTT remains an external dependency. Initial validation modules cover explicit asset references, config class contracts, addon dependencies, SQF parsing through SQF-VM in automated parse-only mode, and structural inspection of configured PBO artifacts. SQF-VM remains an external dependency; parse success does not establish Arma 3 runtime compatibility. Core CI tests run under PowerShell 7, with a separate Windows PowerShell 5.1 compatibility smoke test covering HEMTT, SQF-VM adapters, and PBO inspection.

The reusable GitHub Actions workflows include `.github/workflows/hemtt.yml` for HEMTT, `.github/workflows/validate.yml` for configured validation modules, `.github/workflows/test.yml` for SQF-VM runtime tests, and `.github/workflows/release.yml` for release publication. Steam publishing uses the existing `arma-actions/workshop-upload` action and requires the consuming repository's `STEAM_USERNAME` and `STEAM_PASSWORD` secrets plus an existing Workshop item. The release workflow can attach an archive to an existing GitHub Release and publish it after the configured Steam upload succeeds. It expects the consuming repository's normal validation and testing CI to have passed before a maintainer creates a GitHub Release.

See [core usage](docs/development/core-usage.md), [release workflow architecture](docs/architecture/release.md), and [CHANGELOG.md](CHANGELOG.md) for current capabilities and milestones. This repository does not provide project templates or require consuming projects to adopt a common directory structure.
