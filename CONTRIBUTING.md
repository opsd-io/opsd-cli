# Contributing

Thanks for helping improve OPSd CLI.

## Before You Start

Read these first:

- [Install](./docs/getting-started/install.md)
- [Quickstart](./docs/getting-started/quickstart.md)
- [Support](./SUPPORT.md)

## Local Setup

Use the supported local Ruby version from `.ruby-version`.

Run the primary test suite with:

```bash
sh scripts/ci/run_unit_cli_tests.sh
```

If you are touching render or smoke behavior, also run the relevant smoke
script for the path you changed.

## Good Changes

Prefer changes that are:

- small and focused
- covered by tests
- reflected in docs if they affect user workflow
- compatible with the documented support boundary

## Issues And Pull Requests

Use the repository templates when filing issues or pull requests.

When opening a pull request, include:

- what changed
- why it changed
- how it was tested
- whether docs or release notes need updates

## Reporting Bugs

For bugs, include:

- OPSd version
- command you ran
- expected behavior
- actual behavior
- relevant output or logs

If the bug is security-related, use [Security](./SECURITY.md) instead of a
public issue.
