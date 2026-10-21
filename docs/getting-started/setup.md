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

For local development, activate Ruby `3.4.10` in the checkout and retain its
absolute path when launching from other directories:

```bash
export RUBY_BIN="$(ruby -rrbconfig -e 'print RbConfig.ruby')"
```

Skip this command for a portable bundle: it includes and selects its own Ruby.

## 2. Create Or Select A Profile

OPSd stores configuration in named profiles. Select the workspace first so the
profile is created in the same place that MCP and later CLI operations use:

```bash
export OPSD_WORKSPACE_ROOT=/absolute/path/to/workspace
mkdir -p "$OPSD_WORKSPACE_ROOT"
export OPSD_APP_ROOT="$PWD"
export OPSD_MODULES_DIGITALOCEAN_REF=4394491d50ebd3b1c1c1b6e895577dadb59e6bb8
bin/opsd config profile create work
bin/opsd config profile use work
bin/opsd config profile current
```

Run these checkout commands from the installation directory. A portable bundle
selects its embedded Ruby automatically. The explicit provider revision is
compatible with the current manifest contract; the latest published module
release (`v0.1.0`, checked 2026-10-21) generates obsolete layer names through
`init blueprint`. Keep this pin until a compatible module release is qualified.
For this cloud-free check, accept `digitalocean`/`fra1` and leave the API token
blank. No cloud credentials are needed for validation or rendering.

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
OPSD_PROFILE=work bin/opsd init blueprint kubernetes-foundation "$OPSD_WORKSPACE_ROOT/demo.yaml" --variant kubernetes
OPSD_PROFILE=work bin/opsd validate manifest "$OPSD_WORKSPACE_ROOT/demo.yaml"
OPSD_PROFILE=work bin/opsd render manifest "$OPSD_WORKSPACE_ROOT/demo.yaml" --output "$OPSD_WORKSPACE_ROOT/live"
```

To render and qualify the Kubernetes platform path, synchronize the pinned
module sources first. The initialized blueprint contains placeholder GitOps
input; configure its repository URL, revision and environment path before
using Argo CD. For a reproducible cloud-free platform check, use the shipped
example and a separate output directory.

Git, Helm, Terraform, OpenTofu and kubeconform must be available in `PATH`;
when using version managers outside the checkout, include their actual binary
directories rather than relying on project-local shim selection:

```bash
cp "$OPSD_APP_ROOT/examples/kubernetes-environment.yaml" "$OPSD_WORKSPACE_ROOT/platform-demo.yaml"
```

In `platform-demo.yaml`, set `spec.compute_groups[0].config.kubernetes_version`
to a concrete version before platform validation. This walkthrough was tested
with `1.33.0-do.0` (Kubernetes schemas `1.33.0`); the example's `latest` placeholder
cannot select a versioned schema. For actual infrastructure, select a version
supported by your provider.

```bash
OPSD_PROFILE=work bin/opsd modules sync "$OPSD_WORKSPACE_ROOT/platform-demo.yaml"
OPSD_PROFILE=work bin/opsd render manifest "$OPSD_WORKSPACE_ROOT/platform-demo.yaml" --output "$OPSD_WORKSPACE_ROOT/platform" --include-platform
OPSD_PROFILE=work bin/opsd validate manifest "$OPSD_WORKSPACE_ROOT/platform-demo.yaml" --platform
```

CLI relative paths resolve from the current directory, while MCP tool paths
resolve from the selected workspace. The absolute paths above work in either
context.

The first platform validation needs network access to populate provider and
Kubernetes schema caches. After a successful online validation, repeat it with
`--offline` to use only the warmed caches:

```bash
OPSD_PROFILE=work bin/opsd validate manifest "$OPSD_WORKSPACE_ROOT/platform-demo.yaml" --platform --offline
```

## 5. Connect Through MCP

Follow [Use OPSd Through MCP](./mcp-setup.md) for separate checkout and portable
bundle instructions, CLI checks, and a complete terminal-only MCP example.

Check the [host compatibility matrix](../reference/mcp-hosts.md#verified-compatibility)
before registering a server. OPSd requires MCP `2026-07-28` per-request metadata;
a host that only supports the earlier initialization handshake cannot connect.
The tested Codex CLI version is currently incompatible, and unverified GUI
examples must not be treated as verified setup paths.

Generate the entry from the checkout or bundle you intend to use:

```bash
bin/opsd-mcp config --workspace-root "$OPSD_WORKSPACE_ROOT"
```

Keep the generated absolute launcher, app/workspace roots, and `RUBY_BIN`.
GUI tools may additionally need an explicit `PATH`. Follow
[MCP Host Configuration](../reference/mcp-hosts.md) for registration references,
connection checks that validate and create real files, confirmation behavior,
and troubleshooting.

## CI Coverage

The configuration flow is intentionally small and stable, so the CI strategy is
lightweight:

- command-level behavior is covered by the existing CLI test suite
- static documentation checks cover the canonical entrypoints and setup links
- if the profile workflow changes, update the docs and the tests together

The opt-in [live CLI/MCP setup test](../reference/mcp-hosts.md#reproduce-the-cli-based-setup-check)
executes the documented workflow using real public modules and charts, then
checks the generated MCP connection and resulting files. It is separate from
the fast suites and needs network access.

## Related Docs

- [Install](./install.md)
- [Quickstart](./quickstart.md)
- [Development Setup](./development-setup.md)
- [Command Reference](../reference/commands.md)
