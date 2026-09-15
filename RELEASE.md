# Release Process

This document captures the internal release runbook for OPSd CLI.

For the public release documentation, see:

- [Release Process](./docs/release/process.md)
- [Release Packaging](./docs/release/packaging.md)

## Release Runbook

Use this sequence for a normal versioned release.

1. Confirm the release scope and target version.
2. Update `lib/opsd/version.rb` to the new version.
3. Update `CHANGELOG.md` with a short summary of what changed.
4. Review `README.md`, `SUPPORT.md`, `SECURITY.md`, and `CONTRIBUTING.md` for
   any release-specific wording that should match the new version.
5. Run the unit test suite.
6. Create the git tag `vX.Y.Z` on the release commit.
7. Let CI build and publish the release artifacts.
8. Verify the published bundle and install smoke.
9. Confirm the docs snapshot asset was published for the same tag.
10. Mirror any important release note on the website if public-facing messaging
    needs to stay aligned.

## Preflight

Before tagging, make sure these files are ready:

- `lib/opsd/version.rb`
- `CHANGELOG.md`
- release-facing docs in `README.md`, `SUPPORT.md`, `SECURITY.md`, and `CONTRIBUTING.md`

Verify the suite with:

```bash
sh scripts/ci/run_unit_cli_tests.sh
```

If you changed render paths or release artifacts, also run the relevant smoke
or packaging validation scripts before tagging.

## Tagging

Create a release tag in the form `vX.Y.Z`.

For `1.0.0`, the tag should be `v1.0.0`.

Use the tag on the commit that contains the final release docs and changelog
updates.

## Validation

Release validation should confirm:

- `bin/opsd version`
- portable bundle build
- checksum generation
- `asdf` install smoke
- shell completion smoke

The CI pipeline already covers these checks in the release jobs, so the main
goal before tagging is to make sure the release commit is ready for those jobs
to run cleanly.

## Artifacts

The release should publish:

- `opsd_<version>_docs.tar.gz`
- `opsd_<version>_linux_amd64.tar.gz`
- `opsd_<version>_darwin_arm64.tar.gz`
- `checksums.txt`

If the release is intended for external consumption, make sure the download
URLs and version references in the public docs match the tag.

## After Release

After the tag is published:

- confirm the GitHub Release exists
- confirm the assets download correctly
- confirm `asdf install opsd <version>` works from the release bundle
- confirm the website or release notes reference the same version

If the website needs a public note, mirror the release summary there so the
public support and documentation pages stay aligned with the code release.

The website can also consume the tagged docs snapshot asset directly so the
published docs match the release tag rather than the default branch.

## Failure Recovery

If the release pipeline fails before publication:

1. fix the source commit
2. rerun the pipeline on the same tag only if the tag has not been published
3. otherwise create a new patch release

If a published artifact is wrong:

1. do not silently replace it
2. publish a corrected follow-up release
3. update the changelog and public notes to explain the correction
