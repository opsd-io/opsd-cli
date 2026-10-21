# MCP Host Configuration

For a user walkthrough covering both installation paths, workspace setup, and
CLI/MCP checks, start with [Use OPSd Through MCP](../getting-started/mcp-setup.md).

OPSd supports only MCP `2026-07-28` over newline-delimited UTF-8 JSON-RPC on
`stdio`. The host must send protocol/client metadata on each request. A host
that only uses the earlier `initialize` handshake cannot connect. Registering
a command is not evidence of discovery or successful tool execution.

## Verified Compatibility

Qualification recorded on 2026-10-21, on macOS 27.0.1 arm64. Detailed,
path-free evidence is in [the verification record](./mcp-host-verification.json).

| Client or host | Observed version | Result |
| --- | --- | --- |
| Official Python MCP SDK | `2.3.0`, explicit `2026-07-28` mode | Verified for checkout and extracted bundle: discovery, validation, rendering, confirmation, and artifacts |
| Codex CLI/app-server MCP client | `0.163.0-alpha.10.2` | Incompatible: sends `initialize` with `2025-06-18`; OPSd returns `-32601` before discovery, for both checkout and bundle |
| Codex desktop UI / IDE extension | Not independently exercised | Unverified; CLI runtime evidence is not a separate UI qualification |
| Claude Desktop | `2.31226.0` installed | Unverified: interactive connection/discovery/tool checks are pending |
| VS Code / Copilot | VS Code `1.142.0` installed | Unverified: interactive connection/discovery/tool checks are pending |

No GUI host is currently listed as verified. The SDK qualification proves the
server workflow, not compatibility with every application. The Codex result
applies to the exact installed client version above; do not infer support or
failure for other versions. Earlier protocols remain intentionally unsupported.

The server qualification on [main](https://github.com/opsd-io/opsd-cli/actions/runs/39563873212)
passed for the checkout and portable bundle on Linux and macOS. This does not
replace the application-specific checks below.

## Prepare the Installation and Workspace

Start with [Setup](../getting-started/setup.md). Choose a checkout using the
Ruby version from `.ruby-version`, or extract a [portable bundle](../release/packaging.md)
with its own runtime. Use absolute paths and select the workspace before
creating its profile:

```bash
export OPSD_APP_ROOT=/absolute/path/to/opsd
export OPSD_WORKSPACE_ROOT=/absolute/path/to/workspace
mkdir -p "$OPSD_WORKSPACE_ROOT"
export OPSD_MODULES_DIGITALOCEAN_REF=4394491d50ebd3b1c1c1b6e895577dadb59e6bb8
"$OPSD_APP_ROOT/bin/opsd" config profile create work
"$OPSD_APP_ROOT/bin/opsd" config profile use work
```

For a checkout, activate Ruby `3.4.10` before these commands. The provider pin
above matches the current contract; the latest published module release still
generates obsolete layer names through `init blueprint`.
Choose `digitalocean` when creating the profile and leave the token blank for
this cloud-free check. For a cloud-free smoke check,
copy the shipped example and explicitly prepare its dependencies:

```bash
cp "$OPSD_APP_ROOT/examples/kubernetes-environment.yaml" "$OPSD_WORKSPACE_ROOT/demo.yaml"
"$OPSD_APP_ROOT/bin/opsd" modules sync "$OPSD_WORKSPACE_ROOT/demo.yaml"
"$OPSD_APP_ROOT/bin/opsd" validate manifest "$OPSD_WORKSPACE_ROOT/demo.yaml"
"$OPSD_APP_ROOT/bin/opsd" render manifest "$OPSD_WORKSPACE_ROOT/demo.yaml" --output "$OPSD_WORKSPACE_ROOT/cli-smoke"
```

Synchronization may download modules and chart archives; Git and Helm must be
available. These commands do not apply infrastructure. Use a fresh output
directory because the renderer refuses to overwrite one. For a real project,
replace the example's metadata and GitOps repository before operating it.

Generate the host entry from the selected installation:

```bash
"$OPSD_APP_ROOT/bin/opsd-mcp" config --workspace-root "$OPSD_WORKSPACE_ROOT"
```

The JSON contains an absolute launcher, both roots, and `RUBY_BIN`. For a
checkout, the Ruby path is the interpreter that generated the entry; regenerate
it after removing or moving that Ruby installation. A bundle selects its
embedded runtime. Regenerate configuration after moving the bundle as the host
entry itself uses absolute paths.

## GUI Runtime and PATH

GUI processes need not load your shell startup files, rbenv, or asdf settings.
The generated absolute `RUBY_BIN` handles checkout Ruby discovery. Bundled
launchers select and initialize their embedded runtime automatically.

Set the server entry's `PATH` explicitly when GUI tools cannot find Git, Helm,
Terraform, OpenTofu, or kubeconform. Use directories containing the real
executables, for example `/absolute/tools/bin:/usr/bin:/bin`; a version-manager
shim alone may still require shell configuration. JSON/TOML environment values
are literal: `$PATH`, `~`, command substitutions, and shell activation commands
are not expanded by OPSd.

Profiles come from the selected workspace's `.opsd/config`. If the host sets
`OPSD_PROFILE`, it overrides the current profile and must name a profile in
that workspace. Contracts, documentation, and examples come from the app;
modules, caches, relative MCP manifest paths, and MCP output belong to the
workspace. CLI relative paths use the current directory; use absolute paths
when calling the CLI from elsewhere.
See [resource lookup](./mcp-resources.md#ownership-and-workspace-lookup).

## Claude Desktop — Unverified Registration Example

The usual macOS configuration file is
`~/Library/Application Support/Claude/claude_desktop_config.json`. Merge the
generated `mcpServers.opsd` entry with existing entries; do not replace unrelated
servers. For a checkout, the shape is:

```json
{
  "mcpServers": {
    "opsd": {
      "command": "/absolute/path/to/opsd/bin/opsd-mcp",
      "env": {
        "OPSD_APP_ROOT": "/absolute/path/to/opsd",
        "OPSD_WORKSPACE_ROOT": "/absolute/path/to/workspace",
        "RUBY_BIN": "/absolute/path/to/ruby/bin/ruby",
        "PATH": "/absolute/tools/bin:/usr/bin:/bin"
      }
    }
  }
}
```

Restart the application after saving the entry and perform the connection
checks below. This is a registration reference, not a claim that the installed
Claude Desktop version has passed qualification. See the
[official SDK host guide](https://py.sdk.modelcontextprotocol.io/get-started/real-host/#claude-desktop)
for registration and GUI environment background.

## Codex CLI — Tested Version Incompatible

The installed client tested above fails before discovery, even with correct
launcher and workspace settings. Increasing timeouts or editing `PATH` does
not fix an `initialize`/protocol mismatch. These snippets document registration
for a future independently qualified client; they do not make that tested
version compatible. Setting `CODEX_MCP_PROTOCOL_VERSION=2026-07-28` in either
the server entry or app-server process environment was also tested and did not
change the observed handshake in this build.

```bash
codex mcp add opsd --env OPSD_APP_ROOT=/absolute/path/to/opsd --env OPSD_WORKSPACE_ROOT=/absolute/path/to/workspace --env RUBY_BIN=/absolute/path/to/ruby/bin/ruby -- /absolute/path/to/opsd/bin/opsd-mcp
```

Equivalent configuration in `~/.codex/config.toml`:

```toml
[mcp_servers.opsd]
command = "/absolute/path/to/opsd/bin/opsd-mcp"
startup_timeout_sec = 10
tool_timeout_sec = 75

[mcp_servers.opsd.env]
OPSD_APP_ROOT = "/absolute/path/to/opsd"
OPSD_WORKSPACE_ROOT = "/absolute/path/to/workspace"
RUBY_BIN = "/absolute/path/to/ruby/bin/ruby"
PATH = "/absolute/tools/bin:/usr/bin:/bin"
```

`codex mcp list` shows registration; `/mcp` in the TUI exposes connection
status. Neither replaces an observed successful tool call. Tool timeout is
longer than OPSd's 60-second process limit so command failures can be reported.
See [official Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
for the host's supported settings. Vendor configuration documentation alone
does not establish support for this server's protocol revision.

## VS Code — Unverified Registration Example

A VS Code workspace entry can be placed in `.vscode/mcp.json`. Convert the
generated entry's outer `mcpServers` key to `servers` and declare the transport:

```json
{
  "servers": {
    "opsd": {
      "type": "stdio",
      "command": "/absolute/path/to/opsd/bin/opsd-mcp",
      "env": {
        "OPSD_APP_ROOT": "/absolute/path/to/opsd",
        "OPSD_WORKSPACE_ROOT": "/absolute/path/to/workspace",
        "RUBY_BIN": "/absolute/path/to/ruby/bin/ruby",
        "PATH": "/absolute/tools/bin:/usr/bin:/bin"
      }
    }
  }
}
```

Start the configured server and inspect its output. Copilot Chat in Agent mode
must discover and successfully call the tools before the version is qualified.
The selected agent harness can use a different configuration format; consult
[Microsoft's configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration).
This example remains unverified and is not a supported-host claim.

## Connection Checks and Evidence

Record host/runtime versions before testing, for example `codex --version`,
`code --version`, `ruby --version`, and Claude Desktop's About dialog. Claude
Code and Claude Desktop are separate hosts; one version does not qualify the
other.

For each host version, use a disposable workspace and record the version,
installation type (checkout or bundle), runtime, selected profile, discovery
result, tool result, and generated artifact. Preserve existing host settings.

1. Start the server through the host, not just a terminal. Inspect connection
   logs; legacy `initialize` is an incompatibility result, not success.
2. Discover tools and read `opsd://contract`. Optionally retrieve
   `prepare-platform`; retrieving a prompt never executes its instructions.
3. Call `validate-manifest` with `{"manifest_path":"demo.yaml"}`. Require
   `isError: false`, `structuredContent.exitCode: 0`, and actual validation text.
4. Call `render-manifest` with
   `{"manifest_path":"demo.yaml","output_dir":"mcp-smoke"}`. Check that
   `mcp-smoke/main.tf`, `opsd.manifest.yaml`, and `opsd.lock.yaml` really exist
   in the selected workspace. The output directory must not already exist.
5. Check a missing manifest produces an operational error and another valid
   call still succeeds. Verify a mutation without confirmation is refused
   before changing the fixture. Never use a real infrastructure apply as a
   connection check.
6. Repeat against the extracted bundle. A host is marked verified only when
   discovery and a successful tool call are recorded; untested versions remain
   unverified.

For supported argument types/defaults, explicit synchronization, offline
platform validation, and CLI-only setup steps, see [MCP Tools](./mcp-tools.md).
Manifest mutations and `modules-sync` require approval for the exact operation
through the host before `confirmed=true` is sent. The server checks the boolean
but cannot independently prove human consent. Hosts must not turn a
model-generated value into automatic approval.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `initialize is not supported` or tools never appear | The host is using the old handshake. Verify exact `2026-07-28` per-request support; there is no legacy fallback. |
| `Unsupported protocol version` (`-32022`) | Request metadata must select `2026-07-28`; later revisions are not implicitly supported. |
| Ruby not found, old-Ruby syntax errors, or `LoadError` | Regenerate configuration using supported Ruby, use an absolute `RUBY_BIN`, or select a complete portable bundle. Inspect host stderr. |
| `git`, Helm, Terraform, `tofu`, or kubeconform not found | Set the GUI server's `PATH` to actual tool binaries. Shell activation is not inherited. |
| No profile selected / unexpected provider | Check the selected workspace's `.opsd/config` and the host's `OPSD_PROFILE` override. |
| Empty blueprint resource / missing provider modules | Prepare that workspace with explicit `modules-sync` after approval or CLI `modules sync`; rendering does not fetch missing modules automatically. |
| Missing contract or app content | Verify `OPSD_APP_ROOT`, complete bundle extraction, and shipped `docs/contract.yaml`; workspace examples do not replace app examples. |
| Refusal to overwrite output | Choose a new output directory; retain the earlier result for comparison. |
| `isError: true` | Inspect `structuredContent.stderr`, `exitCode`, and `timedOut`. Operational failures are distinct from JSON-RPC parameter errors. |
| Schema download returns 404 | Replace the manifest's `kubernetes_version: latest` placeholder with a concrete version; platform validation needs matching versioned Kubernetes schemas. |
| Missing offline caches | Prepare caches online explicitly; MCP does not silently retry an offline validation online. |
| Confirmation refused | Obtain user approval and send boolean `confirmed: true` for this exact call. String `"true"` and top-level confirmation are not accepted. |

Protocol stdout must contain JSON-RPC lines only. Application logs and command
diagnostics go to stderr or tool results. See [MCP Server](./mcp-server.md) for
framing, request metadata, and reproducible SDK/bundle qualification commands.

## Reproduce the CLI-Based Setup Check

From the activated source checkout, run the live test without a GUI host:

```bash
RUBY_BIN="$(ruby -rrbconfig -e 'print RbConfig.ruby')" uv run --project test/mcp --locked --python 3.11 python test/mcp/qualification/documented_setup.py
OPSD_MCP_TEST_APP_ROOT=/absolute/path/to/extracted/bundle RUBY_BIN="$(ruby -rrbconfig -e 'print RbConfig.ruby')" uv run --project test/mcp --locked --python 3.11 python test/mcp/qualification/documented_setup.py
```

This opt-in check needs network access and the real tools from `.tool-versions`.
It creates a token-free profile and manifest through the CLI, synchronizes
public modules/charts, renders CLI output, then launches the generated MCP
configuration from another directory through the official SDK. It checks
discovery, validation, rendering artifacts, refusal without confirmation, and
recovery after an operational error. CLI platform validation is exercised online
and offline with unavailable HTTP proxies after warming the caches. It uses no
tool stand-ins and never
applies infrastructure. A successful SDK run does not qualify a GUI host.
