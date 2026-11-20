# Release workflow architecture

## Goals

The reusable workflow at `.github/workflows/release.yml` owns the release pipeline for consuming Arma 3 mods:

- check out the tagged project source;
- install the configured HEMTT version;
- update the project's version header and generate Workshop `meta.cpp`;
- run `hemtt release --no-archive`;
- validate and package the release directory;
- attach the ZIP to the existing GitHub Release;
- upload the release directory to an existing Steam Workshop item using `arma-actions/workshop-upload`;
- publish the GitHub Release after successful uploads when requested.

Consuming repositories provide only variant metadata and protected Steam credentials. They do not need to maintain their own packaging or publishing steps.

## Release inputs

The workflow accepts project-relative paths for the version header and `meta.cpp`, the HEMTT version, the release tag, Workshop item ID and display name, release folder prefix, destination toggles, and whether this invocation should finalize the GitHub Release.

The version header is expected to contain exactly one `#define MAJOR`, `#define MINOR`, and `#define PATCH`. The workflow derives those values from a semantic-version tag. A leading `v`, prerelease suffixes, build metadata, and the project's legacy `.RC.` suffix are accepted; the numeric major/minor/patch components are written to the header.

The generated `meta.cpp` contains protocol version, Workshop item ID, display name, and a fresh UTC timestamp.

## Steam credentials and prerequisites

Steam publishing uses the existing `arma-actions/workshop-upload@v1` action. The consuming repository must define:

- `STEAM_USERNAME`
- `STEAM_PASSWORD`

Pass them to the reusable workflow as `secrets.steam_username` and `secrets.steam_password`. The workflow checks that both are present when Steam publishing is enabled. Do not put credentials in project configuration or workflow inputs.

The target Workshop item must already exist, and the Steam account must have permission to update it and own Arma 3 as required by the upload action. Steam Guard / account security requirements are determined by the Steam account and action; use a dedicated publishing account where appropriate.

## Multiple release variants

A project can call the reusable workflow more than once for a single GitHub Release. Calls should be sequenced when they attach different assets to the same GitHub Release. The first call can create/update the release draft and upload its variant; the final call uploads the remaining variant and sets `finalize-github: true`.

For example, a Dev variant can run first. For a prerelease event it can finalize the GitHub prerelease immediately. For a full release event it can leave the GitHub Release as a draft, allowing the Stable variant to upload before the final call publishes the release.

## Artifact validation

The workflow requires `.hemttout/release/addons` to exist and contain at least one PBO. It moves the HEMTT output to a named variant folder and creates a ZIP archive. The same folder is passed to the Workshop upload action, ensuring the Steam upload and GitHub archive are derived from the same HEMTT output. After packaging, the workflow enumerates the release files, compares the ZIP entry count, rejects unexpected entries, and verifies every archived file against its source using SHA-256. This integrity check runs before either publishing destination is used.

## Limitations and recovery

GitHub Releases and Steam Workshop are separate services, not an atomic transaction. If Steam publishing fails after the GitHub draft is created, the release remains a draft when `finalize-github` is enabled only after the Steam step. Rerun the failed workflow job or the workflow after resolving the Steam issue. Avoid creating a second GitHub Release for the same tag.

The workflow updates existing Workshop items; it does not create new items or manage their title, description, preview image, tags, or visibility. The release workflow does not replace the consuming repository's normal validation and test CI. Configure release creation so those checks have passed before maintainers publish a GitHub Release.
### Failure and rerun scenarios

The release steps intentionally use GitHub Actions' default `success()` gating:

- If the draft-asset attachment step fails, Steam upload and finalization do not run.
- If Steam upload fails, the GitHub Release remains a draft and finalization is skipped.
- If Steam succeeds but GitHub finalization fails, the Workshop update is already complete; rerun the workflow for the same tag to retry the GitHub release operation.
- Reruns use the same release tag and existing GitHub Release, rather than creating a second release for the version. The draft and finalization steps are both scoped to that tag.


These scenarios are covered by workflow safety tests. The tests inspect gating and ordering; they do not perform live GitHub Release or Steam Workshop operations.
