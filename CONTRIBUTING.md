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

## Pull Requests And Commits

Every pull request title and every commit included in it must use:

~~~text
type(scope): short imperative description
~~~

Use a scope from cli, ci, docs, or release, for example
feat(cli): add manifest validation. The ! marker may be used for a breaking
change.

The required Conventional Commits check must pass before merging. Release
Please uses these messages to build the shared release notes, so avoid bare
messages such as feat: ... or fix: ....

## Validation And Releases

Pull requests run public infrastructure checks for Terraform and OpenTofu
through the shared workflows. They generate manifests, render the
configuration, validate it, and run both plans without creating cloud
resources. Changes that affect provider modules or scenarios must update the
corresponding integration coverage.

Real DigitalOcean apply tests run separately through the private workflow.
They are used for a release candidate or changes that affect the lifecycle;
never put cloud credentials in this repository or in a public workflow.

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
