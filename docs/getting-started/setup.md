# Setup

This page is the canonical setup path for configuring OPSd locally.

If you only need the shortest path from install to render, use
[Quickstart](./quickstart.md). If you are packaging OPSd or using a relocatable
bundle, use [Release Packaging](../release/packaging.md).

## 1. Install OPSd

Install OPSd using one of the documented paths:

- [Install](./install.md)
- [Development Setup](./development-setup.md)
- [Release Packaging](../release/packaging.md)

For local development, the supported Ruby version is `3.4.10`.

## 2. Create Or Select A Profile

OPSd stores configuration in named profiles.

```bash
bin/opsd config profile create work
bin/opsd config profile use work
bin/opsd config profile current
```

The current profile tells OPSd which provider and connection details to use for
CLI discovery and workspace-aware flows.

## 3. Point OPSd At Your Workspace

When you work against a repository checkout or another workspace, set the
workspace root explicitly:

```bash
OPSD_WORKSPACE_ROOT=/path/to/workspace bin/opsd list blueprints
OPSD_WORKSPACE_ROOT=/path/to/workspace bin/opsd config profile current
```

The workspace is where OPSd materializes its managed modules. Keep client-owned
modules under `modules/custom/`.

## 4. Verify The Result

After creating a profile and pointing at the workspace, verify the active
context:

```bash
bin/opsd config profile show work
bin/opsd config profile current
```

Then continue with discovery and workflow commands:

```bash
OPSD_PROFILE=work bin/opsd list blueprints
OPSD_PROFILE=work bin/opsd describe blueprint kubernetes-foundation
OPSD_PROFILE=work bin/opsd init blueprint kubernetes-foundation demo.yaml --variant kubernetes
OPSD_PROFILE=work bin/opsd validate manifest demo.yaml
OPSD_PROFILE=work bin/opsd render manifest demo.yaml --output live/
```

To render and qualify the Kubernetes platform path, synchronize the pinned
module sources first. Helm, Terraform and OpenTofu must be available in `PATH`:

```bash
OPSD_PROFILE=work bin/opsd modules sync demo.yaml
OPSD_PROFILE=work bin/opsd render manifest demo.yaml --output live/ --include-platform
OPSD_PROFILE=work bin/opsd validate manifest demo.yaml --platform
```

The first platform validation needs network access to populate provider and
Kubernetes schema caches. After a successful online validation, repeat it with
`--offline` to use only the warmed caches:

```bash
OPSD_PROFILE=work bin/opsd validate manifest demo.yaml --platform --offline
```

## CI Coverage

The configuration flow is intentionally small and stable, so the CI strategy is
lightweight:

- command-level behavior is covered by the existing CLI test suite
- this setup page is backed by a docs test so the canonical path does not drift
- if the profile workflow changes, update the docs and the tests together

## Related Docs

- [Install](./install.md)
- [Quickstart](./quickstart.md)
- [Development Setup](./development-setup.md)
- [Command Reference](../reference/commands.md)
