# Release workflow architecture

## Goals

The reusable release workflow at .github/workflows/release.yml coordinates publication of one HEMTT release to one or both supported destinations:

- GitHub Releases
- An existing Arma 3 Steam Workshop item

It is not a distributed transaction. The workflow makes partial completion visible and supports retrying failed publication jobs without rebuilding.

## Release invariants

1. The workflow must be triggered by pushing a semantic-version tag that already exists in the consuming repository.
2. The tag must resolve to the exact commit that triggered the workflow.
3. HEMTT release runs once per workflow run.
4. One prepared payload is shared by all enabled destinations.
5. The payload contains a ZIP, SHA-256 checksum, content manifest, and the exact Workshop content directory.
6. The GitHub Release remains a draft until every enabled destination succeeds.
7. The workflow summary fails unless preflight, build, and every enabled destination complete successfully.
8. Reruns of failed jobs use the same run-scoped artifact; the artifact name deliberately excludes github.run_attempt.

## Job graph

~~~text
preflight
   |
  build
   |---------------------|
   |                     |
github-draft        steam-publish
   |                     |
   |----------+----------|
              |
       github-publish
              |
       release-status
~~~

The GitHub draft and Steam publication jobs run independently after the build. The final GitHub publication job runs only when GitHub publication is enabled and every enabled destination has succeeded. The status job always runs and marks the overall workflow failed if an enabled destination did not finish.

GitHub-only and Steam-only releases are supported. At least one destination must be enabled.

## Artifact construction and integrity

The build job requires .hemttout/release/addons to exist and contain at least one PBO. It stages the release folder under release-payload/workshop-content, creates a ZIP from that staged directory, and records:

- release tag and source commit;
- archive filename and SHA-256 digest;
- PBO count;
- each content file's relative path, size, and SHA-256 digest.

The artifact is uploaded once and retained for 14 days by default. Its name uses the workflow run ID only, so rerun attempts can download the same artifact. It does not include the attempt number.

The Steam job verifies the archive checksum, file count, file sizes, and per-file hashes before passing the staged content directory to PublisherCmd.

## GitHub Release behavior

The GitHub draft job creates or updates a draft release for the existing tag and attaches the ZIP, checksum, and manifest. The final publication job changes the draft to a published release only after all enabled destinations succeed.

The workflow uses the triggering commit as the tag target. It does not create a new version tag on a different commit. It does not rerun the complete validation and SQF-VM test matrix; consuming repositories should make those checks required before maintainers create a release tag.

## Steam Workshop behavior

Steam publishing uses Bohemia Interactive's PublisherCmd.exe:

~~~powershell
PublisherCmd update /id:<workshop-id> /changeNoteFile:<path> /path:<content-folder> /nologo /nosummary
~~~

PublisherCmd updates an existing Workshop item. Initial item creation, title/description/preview/tag/visibility editing, and acceptance of the Steamworks agreement remain manual prerequisites.

PublisherCmd uses the Steam client API and requires the Steam client to be running and online. The workflow therefore targets a dedicated Windows self-hosted runner labelled arma3-publisher, running under the Windows account with the authenticated Steam client session. No Steam password or Steam Guard code is passed to the workflow.

The Steam job has only `contents: read` permission and does not check out or execute the consuming repository. Restrict the runner to trusted release workflows; never expose it to untrusted pull-request jobs.

## Private framework access

The framework repository is private. Its Actions access settings must allow each consuming repository to call the reusable workflows. Each reusable workflow declares a workflow_call secret named framework_token. The consuming repository passes a fine-grained token with Contents: read access to this repository. The token is used only for the framework checkout, and checkout credentials are not persisted.

## Recovery

If GitHub draft creation fails but Steam succeeds, rerun the failed GitHub draft and dependent publication jobs. If Steam fails but the GitHub draft succeeds, rerun the failed Steam and dependent publication jobs. Successful jobs are not rebuilt or republished when using Re-run failed jobs on the same workflow run.

Do not start a new workflow run to recover a partial release unless a new build is explicitly intended. The original run artifact is retained for 14 days. After that, recovery may require rebuilding or manually restoring the exact artifact.
