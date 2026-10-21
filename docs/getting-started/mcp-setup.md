# Use OPSd Through MCP

This walkthrough prepares a workspace, validates and renders an example through
CLI, then repeats those operations through MCP. Choose either installation path
below and continue with the shared workspace steps. The commands use a POSIX
shell on macOS or Linux and need no cloud credentials.

| Installation | Ruby | Start here |
| --- | --- | --- |
| Source checkout | Activate Ruby `3.4.10` | [A. Source checkout](#a-source-checkout) |
| Portable bundle | Included in the archive | [B. Portable bundle](#b-portable-bundle) |

Both paths were exercised on macOS arm64 using the CLI and official MCP SDK.
See the [verification record](../reference/mcp-host-verification.json) for the
tested versions and [host compatibility](../reference/mcp-hosts.md#verified-compatibility)
before choosing an AI application. OPSd requires MCP `2026-07-28`; the tested
Codex CLI is incompatible, and the Claude Desktop and VS Code registration
examples remain unverified.

## A. Source Checkout

Obtain the source as described in [Development Setup](./development-setup.md).
In the checkout, activate the Ruby version from `.ruby-version` with your Ruby
version manager, then run:

```bash
ruby --version
export RUBY_BIN="$(ruby -rrbconfig -e 'print RbConfig.ruby')"
export OPSD_APP_ROOT="$(pwd -P)"
"$OPSD_APP_ROOT/bin/opsd" version
```

Ruby should report `3.4.10`; OPSd should print its version and exit successfully.
Retain the absolute `RUBY_BIN` value: another working directory or a GUI process
may not load the checkout's Ruby version-manager settings. The generated MCP
entry will include this interpreter path.

Continue with [Prepare a workspace](#1-prepare-a-workspace).

## B. Portable Bundle

Obtain an archive matching your OS and architecture as described in
[Release Packaging](../release/packaging.md). Use a bundle built from the OPSd
version accompanying these instructions. The qualification used a locally
built `opsd_0.1.0_darwin_arm64` archive; its filename alone does not establish
that a published release includes this MCP implementation.

The portable installer detects your OS/architecture, downloads the latest
published bundle and verifies its release SHA-256 checksum. After
`scripts/install.sh` is published on `main`, install with:

```bash
curl -fsSL https://raw.githubusercontent.com/opsd-io/opsd-cli/main/scripts/install.sh -o install-opsd.sh && sh install-opsd.sh
```

The installer configures `PATH`, `OPSD_APP_ROOT`, and shell completion for your
Bash, Zsh, or Fish shell. Open a new terminal, or run the activation command
printed by the installer before continuing in the current terminal. You can
then run `opsd` and `opsd-mcp` directly. Each installation
has its own directory under `~/opsd`, and existing installations are preserved.
Use `--prefix` to choose another location or `--version` to select a release.
Existing shell settings are preserved; rerunning the installer refreshes the
OPSd setup without adding duplicate hooks for the same installation prefix.
Use `--shell bash`, `--shell zsh`, or `--shell fish` to override shell detection.
Use `--no-shell-setup` for automation or to manage shell configuration yourself.
The installer respects `ZDOTDIR` for Zsh and `XDG_CONFIG_HOME` for Fish;
`--shell-config-dir` selects a custom shell configuration directory.

The published `v0.1.0` release predates this MCP qualification. Until a release
containing these changes is available, use a bundle built from the matching
checkout. From that checkout, run:

```bash
sh scripts/install.sh --local
```

When prompted, paste the path to your downloaded or locally built archive,
without surrounding quotes. This uses the same installer without downloading
a release. The installer checks the archive's platform and embedded runtime,
then configures PATH and completion and prints the activation command. Local archives do not have a downloaded
release checksum to verify. You do not need a host Ruby installation to run
either installer path.

Continue with the same workspace steps below. After moving the extracted
installation, update `OPSD_APP_ROOT` and regenerate the MCP configuration.

## 1. Prepare a Workspace

The commands below create a fresh `~/opsd-workspace.*` directory and print its
actual path. Keep using the same terminal so the selected installation and
workspace remain available. The installation contains OPSd code
and examples; the workspace holds your profile, manifests, modules, caches,
and generated output.

Git and Helm must be available for synchronization. Platform validation also
needs Terraform, OpenTofu (`tofu`), and kubeconform. The tested versions are:

| Tool | Tested version |
| --- | --- |
| Helm | `4.3.0` |
| Terraform | `1.15.7` |
| OpenTofu | `1.12.6` |
| kubeconform | `0.7.0` |

If you use version managers, make the actual executable directories available
in `PATH` when running outside the checkout. GUI applications need the same
explicit tool paths; a project-local shim may not select a version there.

```bash
OPSD_WORKSPACE_ROOT="$(mktemp -d "$HOME/opsd-workspace.XXXXXX")"
export OPSD_WORKSPACE_ROOT
printf 'Workspace: %s\n' "$OPSD_WORKSPACE_ROOT"
export OPSD_MODULES_DIGITALOCEAN_REF=4394491d50ebd3b1c1c1b6e895577dadb59e6bb8
"$OPSD_APP_ROOT/bin/opsd" config profile create work
"$OPSD_APP_ROOT/bin/opsd" config profile use work
"$OPSD_APP_ROOT/bin/opsd" config profile current
```

Accept the default provider `digitalocean`, leave the API token blank, and
accept region `fra1`. The final command should show `Current profile: work`
and `Provider: digitalocean`. The profile belongs to this workspace's
`.opsd/config`. If your environment sets `OPSD_PROFILE`, clear it or set it to
`work` so it does not override the selected profile.

The provider revision above was tested with the current CLI contract. At
qualification time, the latest published module release (`v0.1.0`) still
generated obsolete layer names through `init blueprint`. Keep the compatible
pin for this walkthrough; the resulting `opsd.lock.yaml` records the resolved
module revisions for subsequent operations.

## 2. Validate and Render Through CLI

Copy the included example, fetch its module/chart dependencies, and run:

```bash
cp "$OPSD_APP_ROOT/examples/kubernetes-environment.yaml" "$OPSD_WORKSPACE_ROOT/demo.yaml"
"$OPSD_APP_ROOT/bin/opsd" modules sync "$OPSD_WORKSPACE_ROOT/demo.yaml"
"$OPSD_APP_ROOT/bin/opsd" validate manifest "$OPSD_WORKSPACE_ROOT/demo.yaml"
"$OPSD_APP_ROOT/bin/opsd" render manifest "$OPSD_WORKSPACE_ROOT/demo.yaml" --output "$OPSD_WORKSPACE_ROOT/cli-smoke"
ls "$OPSD_WORKSPACE_ROOT/cli-smoke/main.tf" "$OPSD_WORKSPACE_ROOT/cli-smoke/opsd.manifest.yaml" "$OPSD_WORKSPACE_ROOT/cli-smoke/opsd.lock.yaml"
```

Synchronization needs network access and may download repositories and Helm
charts. Validation should report `Manifest is valid`; rendering should report
`Rendered stack` and produce all three listed files. These operations generate
and validate files without applying infrastructure.

Use a fresh output directory for each render. CLI relative paths follow the
terminal's working directory; the absolute paths above work from elsewhere.
Before adapting the example to a real environment, replace its metadata and
GitOps repository with your project values.

To create your own starting manifest instead, use the CLI catalog and
initialization workflow in [Setup](./setup.md#4-verify-the-result). Profile
management and manifest initialization are CLI setup steps outside MCP.

## 3. Generate the MCP Configuration

```bash
"$OPSD_APP_ROOT/bin/opsd-mcp" config --workspace-root "$OPSD_WORKSPACE_ROOT"
```

The command prints JSON containing `mcpServers.opsd` with an absolute launcher
and `OPSD_APP_ROOT`, `OPSD_WORKSPACE_ROOT`, and `RUBY_BIN` environment values.
For a checkout, Ruby points to the interpreter used above. For a portable
bundle, it points to the embedded `runtime/bin/ruby`.

Merge the generated entry into a compatible host's configuration, preserving
other servers. Add a literal `PATH` containing your Git, Helm, Terraform,
OpenTofu, and kubeconform binaries when the application does not inherit those
paths. Shell expressions such as `$PATH` are not expanded in JSON environment
values. Set `OPSD_PROFILE` to `work` in the entry if you want an explicit profile.

See [MCP Host Configuration](../reference/mcp-hosts.md) for application-specific
registration formats, compatibility results, and troubleshooting. Regenerate
the entry after moving the installation or changing the checkout Ruby path.
A registered command is only the first step: require discovery and a successful
tool call before treating an application connection as working.

## 4. Verify MCP Without a GUI

You can check the actual stdio server directly from the same terminal. Paste
the complete block below; it sends discovery and tool requests using the
required per-request protocol metadata, then closes stdin:

```bash
"$OPSD_APP_ROOT/bin/opsd-mcp" <<'MCP_REQUESTS'
{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}},"name":"validate-manifest","arguments":{"manifest_path":"demo.yaml"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}},"name":"render-manifest","arguments":{"manifest_path":"demo.yaml","output_dir":"mcp-smoke"}}}
MCP_REQUESTS
ls "$OPSD_WORKSPACE_ROOT/mcp-smoke/main.tf" "$OPSD_WORKSPACE_ROOT/mcp-smoke/opsd.manifest.yaml" "$OPSD_WORKSPACE_ROOT/mcp-smoke/opsd.lock.yaml"
```

Expect one JSON-RPC response per request. Discovery should advertise
`2026-07-28`, the tools response should contain the catalog, and responses `3`
and `4` should contain `isError: false` and `structuredContent.exitCode: 0`.
The files under `mcp-smoke/` are produced by the actual CLI execution. MCP
relative paths resolve from the selected workspace, independently of the
terminal's working directory.

In a compatible application, request the same `validate-manifest` and
`render-manifest` calls with the arguments above. A direct stdio success proves
the server works; the application's own discovery and successful tool call
establish its connection. Use a different output directory if the direct
check already created `mcp-smoke`.

Manifest mutations and `modules-sync` require approval for the exact operation
through the host before it sends `confirmed: true`. Calls without confirmation
are refused. Validation and rendering do not automatically synchronize missing
modules. See [MCP Tools](../reference/mcp-tools.md) for arguments and effects.

## 5. Optional Platform Validation and Offline Use

For the example's platform checks, edit `demo.yaml` and replace
`spec.compute_groups[0].config.kubernetes_version: latest` with a concrete
version. Qualification used `1.33.0-do.0`, selecting Kubernetes schemas
`1.33.0`. The `latest` placeholder cannot select a versioned schema. For an
actual cluster, choose a Kubernetes version supported by your provider.

```bash
"$OPSD_APP_ROOT/bin/opsd" render manifest "$OPSD_WORKSPACE_ROOT/demo.yaml" --output "$OPSD_WORKSPACE_ROOT/cli-platform" --include-platform
"$OPSD_APP_ROOT/bin/opsd" validate manifest "$OPSD_WORKSPACE_ROOT/demo.yaml" --platform
"$OPSD_APP_ROOT/bin/opsd" validate manifest "$OPSD_WORKSPACE_ROOT/demo.yaml" --platform --offline
```

Expect `cli-platform/platform/helm/argocd.yaml` as well as the infrastructure
files. The first validation populates provider and schema caches and needs
network access; the offline run uses those caches. Missing caches cause an
error, with no automatic online fallback.

The corresponding MCP validation arguments are
`{"manifest_path":"demo.yaml","platform":true}` and, after warming caches,
`{"manifest_path":"demo.yaml","platform":true,"offline":true}`.
For a platform render, add `include_platform: true` and use a fresh output
directory. Every MCP tool execution has a 60-second limit; inspect `timedOut`
and `stderr` if a cold-cache operation exceeds it. Long initial preparation
can be run through the CLI before repeating the MCP call.

For errors involving runtime discovery, protocol mismatch, profiles, modules,
schemas, or output directories, use the
[troubleshooting table](../reference/mcp-hosts.md#troubleshooting).
