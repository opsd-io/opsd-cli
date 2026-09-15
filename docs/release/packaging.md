# Release Packaging

OPSd CLI ships as a portable release bundle and an `asdf` plugin.

Do not confuse the release bundle with an `exit-pack`.

- The release bundle packages the OPSd CLI itself for installation and distribution.
- The exit pack packages a rendered handoff for client-owned operations without OPSd runtime access.

## Release Bundle

For a released version such as `v1.0.0`, download the bundle that matches your platform:

```bash
curl -fL \
  -o opsd_1.0.0_linux_amd64.tar.gz \
  "https://github.com/opsd-io/opsd-cli/releases/download/v1.0.0/opsd_1.0.0_linux_amd64.tar.gz"
tar -xzf opsd_1.0.0_linux_amd64.tar.gz
./opsd_1.0.0_linux_amd64/bin/opsd version
```

The bundle includes its own Ruby runtime. You do not need Ruby installed on the host to run the
extracted `bin/opsd`.

## asdf

Install the local plugin from this repository:

```bash
asdf plugin add opsd https://github.com/opsd-io/opsd-asdf.git
asdf install opsd 1.0.0
asdf global opsd 1.0.0
opsd version
```

## Build A Local Bundle

If you want to build the release archive locally, use the portable bundle script:

```bash
scripts/release/build_portable_bundle.sh
```

This creates a release archive under `dist/` in the form:

- `opsd_<version>_<os>_<arch>.tar.gz`

The build script validates that the source Ruby matches `.ruby-version` and
that the resulting archive can run `bin/opsd version` after unpacking.

The bundle contains:

- `bin/opsd`
- `bin/opsd-mcp`
- repository runtime assets such as `lib/` and `composer/`
- an embedded Ruby runtime copied from the current Ruby prefix into `runtime/`

The launcher in `bin/opsd` prefers the embedded runtime when present and falls
back to `ruby` from `PATH` during local development.

## Exit Pack

If you already rendered a project, `opsd export exit-pack` creates a portable
handoff archive from the rendered directory.

See [docs/exit-pack.md](../exit-pack.md) for the archive layout and metadata.
