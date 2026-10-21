# Release Packaging

OPSd CLI ships as a portable release bundle and an `asdf` plugin.

Do not confuse the release bundle with an `exit-pack`.

- The release bundle packages the OPSd CLI itself for installation and distribution.
- The exit pack packages a rendered handoff for client-owned operations without OPSd runtime access.

## Release Bundle

The portable installer selects the archive for your OS/architecture, verifies
the published SHA-256 checksum and checks the embedded runtime before installing:

```bash
curl -fsSL https://raw.githubusercontent.com/opsd-io/opsd-cli/main/scripts/install.sh -o install-opsd.sh && sh install-opsd.sh
```

This URL becomes available when the installer reaches `main`. Open a new
terminal or run the printed activation command to use OPSd and its completion. The default
installation directory is `~/opsd`; each installation is kept separately.
No host Ruby is required. The installer adds PATH, app-root selection and
completion to the detected Bash, Zsh, or Fish configuration, preserving existing
settings. Reinstallation refreshes its setup without duplicate hooks. Use
`--shell` to select a shell explicitly or `--no-shell-setup` to skip these changes.

From a checkout, `sh scripts/install.sh --local` installs an archive you already
have, while `sh scripts/install.sh --version 0.1.0` selects a published release.
Use `--prefix` to choose another installation parent directory and `--help`
for all options. A release version alone does not establish MCP compatibility;
follow the [MCP user guide](../getting-started/mcp-setup.md#b-portable-bundle)
for the currently qualified source/bundle paths.

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

Build prerequisites are Ruby from `.ruby-version`, `uv` (`0.13.1`), Python 3.11,
Git, and the Helm/Terraform/OpenTofu/kubeconform versions in `.tool-versions`.
On macOS, the Command Line Tools must provide `otool`, `install_name_tool`, and
`codesign`; on Linux, `ldd` is required. Release runners need these tools too.
Qualification needs network access for pinned provider source and initial
provider/schema caches, but needs no cloud credentials.

The build script checks the Ruby version, copies required runtime libraries,
and qualifies the extracted archive through the same official MCP SDK/schema,
feature tests, and real platform validation used for the checkout. A failure
stops the build before an archive can be published. It verifies actual generated
files, approved/refused mutations, preserved dependency pins, and warmed-cache
offline validation from a different working directory. See
[MCP qualification](../reference/mcp-server.md#complete-workflow-and-bundle-qualification)
for standalone commands, diagnostics, and the pinned test inputs.

The bundle contains:

- `bin/opsd`
- `bin/opsd-mcp`
- repository runtime assets such as `lib/` and `composer/`
- `docs/` (including `contract.yaml`) and shipped `examples/` for MCP resources
- an embedded Ruby runtime and its required non-system native libraries under `runtime/`
- generated runtime lookup paths relative to the extracted bundle

The launcher in `bin/opsd` prefers the embedded runtime when present and falls
back to `ruby` from `PATH` during local development. Both launchers initialize
the bundled standard-library and native-library lookup paths. macOS non-system
library references are rewritten relative to their loader and ad-hoc signed;
Linux retains the host C runtime/loader and uses copied dependency libraries.
Bundles target their build OS/architecture and still require a compatible host
OS and its core system libraries. Test dependencies and qualification tools
are not added to the installed runtime.

## Exit Pack

If you already rendered a project, `opsd export exit-pack` creates a portable
handoff archive from the rendered directory.

See [docs/exit-pack.md](../exit-pack.md) for the archive layout and metadata.
