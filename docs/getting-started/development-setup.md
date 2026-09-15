# Development Setup

This page covers the local checkout workflow for contributing to OPSd CLI.

For the canonical configuration workflow after install, see [Setup](./setup.md).

## Run From The Repository

The repository includes a checked-in launcher at `bin/opsd`. It is part of the
source tree, not an accidental build artifact.

```bash
bin/opsd version
bin/opsd list blueprints
```

The supported local Ruby version is `3.4.10`.

## Use A Workspace

When working against a real workspace, point the CLI at the directory that
contains `modules/<provider>/*`:

```bash
OPSD_WORKSPACE_ROOT=/path/to/workspace bin/opsd list blueprints
OPSD_WORKSPACE_ROOT=/path/to/workspace bin/opsd config profile current
```

## Build A Local Bundle

If you want a self-contained bundle instead of running against the host Ruby,
build the portable release archive and unpack it. The build requires Ruby
`3.4.10` and a relocatable Ruby installation:

```bash
scripts/release/build_portable_bundle.sh
tar -xzf dist/opsd_1.0.0_linux_amd64.tar.gz
./opsd_1.0.0_linux_amd64/bin/opsd version
```

That bundle includes its own Ruby runtime under `runtime/`, so you do not need
the host Ruby installed to run the extracted binary.
