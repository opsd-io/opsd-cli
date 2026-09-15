# Release Process

This page describes the public release flow for OPSd CLI.

The cross-component contract for the CLI, asdf plugin, and provider modules is
documented in [component-contract.md](component-contract.md).

## Release Overview

OPSd CLI releases are versioned with git tags in the form `vX.Y.Z`.

Each release should publish:

- a portable CLI bundle
- an `asdf` install path
- a docs snapshot for the same tag

## What Gets Updated

Before tagging a release, update:

- `lib/opsd/version.rb`
- `CHANGELOG.md`
- release-facing wording in `README.md`, `SUPPORT.md`, `SECURITY.md`, and `CONTRIBUTING.md`

## Release Sequence

Use this sequence for a normal versioned release:

1. Confirm the release scope and target version.
2. Update `lib/opsd/version.rb` to the new version.
3. Update `CHANGELOG.md` with a short summary of what changed.
4. Run the unit test suite.
5. Create the git tag `vX.Y.Z` on the release commit.
6. Let CI build and publish the release artifacts to the GitHub Release.
7. Let the website trigger consume the exact CLI tag and the pinned DigitalOcean module commit.
8. Let the post-release verification download the public assets, verify checksums, and run the asdf install smoke.
9. Mirror any important release note on the website if public-facing messaging needs to stay aligned.

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

## After Release

After the tag is published:

- confirm the GitHub Release exists and links to the release assets
- confirm the assets download correctly
- confirm the package registry URLs remain available independently of CI job artifacts
- confirm the post-release verification job is successful
- confirm `asdf install opsd <version>` works from the release bundle
- confirm the website or release notes reference the same version

The website can also consume the tagged docs snapshot asset directly so the
published docs match the release tag rather than the default branch.

The website trigger currently pins the DigitalOcean module input to commit
`111fd139e7951e08239ec9090d2e5189394627dd`. Update that pin deliberately when
the module release is updated; do not replace it with `main`.

## macOS runner contract

The macOS bundle job requires the protected CI variable
`OPSD_MACOS_RUBY_BIN`. It must point to a runner-managed Ruby `3.4.10` binary;
the job verifies the exact version and rejects the macOS system Ruby. The
runner image or provisioning procedure must keep this path stable and be
documented alongside the runner configuration.
