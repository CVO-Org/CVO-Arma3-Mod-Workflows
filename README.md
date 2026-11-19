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

Reusable workflow files live directly in `.github/workflows/`, as required by GitHub Actions; the separate top-level `workflows/` directory is intentionally not used for callable workflow definitions. The framework is under active development. The configuration contract and module interfaces are being established first. Installation instructions and executable commands will be added as those components become available.

A consuming project will eventually add the framework as a Git submodule, pin it to a release tag, and provide an `arma3-workflows.yml` file at its repository root (or pass an explicit configuration path).

## Configuration

See [the architecture overview](docs/architecture/overview.md) and [configuration schema](config/schema/arma3-workflows.schema.json). The schema is an initial contract and will evolve with explicit schema-version changes.

## Development status

See [CHANGELOG.md](CHANGELOG.md) for repository milestones. This repository does not provide project templates or require consuming projects to adopt a common directory structure.
