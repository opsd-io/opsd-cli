# MCP Tools

OPSd exposes a small set of MCP tool definitions that map directly onto the
existing CLI workflow.

The tool catalog is intentionally conservative:

- workflow tools execute the corresponding CLI action
- manifest mutation tools require explicit user confirmation through the host
- no separate product model is introduced

## Tool and CLI Mapping

`*` marks a required argument. Paths and identifiers are strings. Boolean
options default to `false`; `confirmed` defaults to refusal. Omitted optional
values are passed through to the CLI defaults below. Unknown tool arguments
are rejected with Invalid params instead of being silently ignored.

| MCP tool | Arguments and defaults | CLI equivalent |
| --- | --- | --- |
| `list-blueprints` | None | `list blueprints` |
| `describe-blueprint` | `blueprint*`, optional `variant` (CLI default variant) | `describe blueprint <blueprint> [--variant <variant>]` |
| `validate-manifest` | `manifest_path*`, `platform: boolean=false`, `offline: boolean=false` | `validate manifest <path> [--platform [--offline]]` |
| `verify-config` | `manifest_path*` | `verify config <path>` |
| `verify-plan` | `plan_path*` | `verify plan <path>` |
| `verify-lifecycle` | `snapshot_path*` | `verify lifecycle <path>` |
| `render-manifest` | `manifest_path*`, `output_dir*`, `include_platform: boolean=false` | `render manifest <path> --output <dir> [--include-platform]` |
| `export-exit-pack` | `rendered_dir*`, `output_path*` | `export exit-pack <dir> --output <archive>` |
| `modules-sync` | `manifest_path*`, `update: boolean=false`, `confirmed: boolean` | `modules sync <path> [--update]` |
| `add-compute-group` | `manifest_path*`, `id*`, `role*`, `type*`, `profile*`, `replicas: integer=1`, optional `image`, `port: integer`, `attach_to: string[]=empty`, `links: string[]=empty`, `confirmed: boolean` | `add compute-group <path> --id <id> --role <role> --type <type> --profile <profile> [--replicas N] [--image ID] [--port N] [--attach-to ID]... [--link ID]...` |
| `resize-compute-group` | `manifest_path*`, `resource_id*`, `profile*`, `confirmed: boolean` | `resize compute-group <path> <id> --profile <profile>` |
| `scale-compute-group` | `manifest_path*`, `resource_id*`, `replicas: integer*`, `confirmed: boolean` | `scale compute-group <path> <id> --replicas N` |
| `attach-compute-group` | `manifest_path*`, `resource_id*`, `load_balancer_id*`, `confirmed: boolean` | `attach compute-group <path> <id> --to <load-balancer>` |
| `detach-compute-group` | `manifest_path*`, `resource_id*`, `load_balancer_id*`, `confirmed: boolean` | `detach compute-group <path> <id> --from <load-balancer>` |
| `remove-resource` | `resource*`, `manifest_path*`, `resource_id*`, `confirmed: boolean` | `remove <resource> <path> <id>` |

`resource` supports the CLI's `compute-group`, `database`, `cache`,
`object-storage`, `load-balancer`, `cdn-endpoint`, and `node` kinds. Image and
port default to absent. The CLI validates domain constraints and references;
the MCP layer validates declared JSON types. `offline=true` without
`platform=true` is a CLI error. No options are inferred from prompt prose.

## Platform Workflow and Prerequisites

1. Configure the workspace profile and create a valid manifest using the CLI
   setup and `init blueprint` workflow. Profile editing and manifest creation
   are explicit setup steps outside MCP.
2. Make Git and Helm available in the host's `PATH`. Obtain approval and call
   `modules-sync` with the manifest path and `confirmed=true`. This explicit
   action may fetch provider/Kubernetes repositories and Helm archives and
   writes managed modules, caches, and `opsd.lock.yaml`. Existing unmanaged or
   locally edited module trees are protected by CLI refusal rules.
3. Call `render-manifest` with `include_platform=true` to render infrastructure
   and enabled Helm components from synchronized modules and cached charts.
   This verifies pins and module trees; it does not refresh dependency pins.
4. For platform validation, provide Terraform, OpenTofu (`tofu`), Helm, and
   kubeconform in `PATH`. Call `validate-manifest` with `platform=true`.
   The default `offline=false` can download provider plugins and Kubernetes
   schemas into the workspace cache. This does not synchronize module pins.
5. Reuse those caches with `platform=true, offline=true`. Missing provider,
   chart, or schema caches produce errors; MCP does not retry online.

For an intentional dependency update, obtain new approval and call
`modules-sync` with `update=true, confirmed=true`. Ordinary synchronization
reuses existing pins. Neither render nor validation invokes synchronization.
Repository/ref overrides use the CLI's `OPSD_MODULES_DIGITALOCEAN_REPO` /
`OPSD_MODULES_DIGITALOCEAN_REF` and `OPSD_MODULES_KUBERNETES_REPO` /
`OPSD_MODULES_KUBERNETES_REF` host environment settings. These are setup
configuration, not tool arguments. Synchronization has the same 60-second
execution limit as other tools; a timeout is reported as a failure and may
require inspecting partial caches before retrying.

## Deliberately CLI-Only Capabilities

MCP does not expose the full CLI. Profile/config management, `init blueprint`
and its wizard, shell completion, help/version commands, module metadata
validation (`validate module`), platform module inspection, and bootstrap are
CLI-only. Add commands for resources other than compute groups and resize
commands for databases/caches are also CLI-only. Cloud apply/destroy and
cluster bootstrap are outside this MCP workflow. Use the
[Command Reference](./commands.md) for these operations; arbitrary CLI
commands or additional flags cannot be passed through an MCP tool.

## Execution and Results

Tools run `bin/opsd` as a child process, using the configured
`OPSD_APP_ROOT` and `OPSD_WORKSPACE_ROOT` and the same Ruby runtime as the MCP
server. The CLI remains the source of command validation and behavior.
Arguments are passed directly as an array without a shell. Path arguments are
resolved against the workspace before CLI parsing, including option-like
filenames such as `--help`.

Results contain the actual CLI output in `content` and these fields in
`structuredContent`:

- `stdout`: command standard output
- `stderr`: command diagnostics
- `exitCode`: process exit status, or `null` if the process was signalled or could not start
- `timedOut`: whether execution exceeded the 60-second limit

A zero exit status produces `isError: false`. Command failures, launch errors,
and timeouts produce `isError: true`, while unknown tools and malformed MCP
arguments remain JSON-RPC errors. The child receives no interactive input.
Timeouts terminate the command's process group, including subprocesses.

Configure a workspace profile and provider modules as for the CLI. In
particular, blueprint discovery and manifest commands use the selected profile
and provider catalogs; MCP does not silently create a profile or synchronize
modules. Ordinary tool subprocesses set `OPSD_MODULES_OFFLINE=1` to prevent
implicit module downloads. Only explicit, confirmed `modules-sync` disables
that restriction; module synchronization may also be run directly via CLI.
`render-manifest` writes generated files and the CLI lock file;
`export-exit-pack` writes an archive. Existing CLI overwrite protections apply.
See [Setup](../getting-started/setup.md) for workspace preparation.

## Effects and Confirmation

`tools/list` classifies every tool using `_meta.io.opsd/effect` and
`_meta.io.opsd/requiresConfirmation`:

| Effect | Tools | Confirmation |
| --- | --- | --- |
| `read-only` | Catalog discovery and verification | Not required |
| `generated-files` | `validate-manifest`, `render-manifest`, `export-exit-pack` | Not required; platform validation can write caches |
| `manifest-mutation` | Compute-group mutations and resource removal | Required on every call |
| `dependency-sync` | `modules-sync` | Required on every call; can download dependencies |

Standard MCP annotations expose `readOnlyHint`, `destructiveHint`, and
`openWorldHint`. Validation is conservatively marked writable because platform validation can
populate caches. Generated output is marked as writable and potentially
replacing files. Synchronization and validation have `openWorldHint: true`
because they can download dependencies or validation data. These annotations describe effects; they do not grant approval.

Each manifest mutation and `modules-sync` declares an optional boolean
`confirmed` input. The
host must show the user the tool, target manifest, and exact operation arguments,
obtain explicit approval, then set `arguments.confirmed` to the JSON boolean
`true` for that call. For example:

```json
{"name":"scale-compute-group","arguments":{"manifest_path":"demo.yaml","resource_id":"web","replicas":3,"confirmed":true}}
```

Missing or false confirmation returns `isError: true` before launching the CLI
or changing files. Non-boolean values, including `"true"`, `1`, and `null`,
produce an Invalid params error (`-32602`). Top-level `params.confirmed` is not
accepted as approval. Confirmation does not persist between requests and is
never forwarded as a CLI option. Confirmed calls still undergo normal CLI
validation and return real command failures.

The server enforces this boolean gate but cannot verify that a user actually
approved the call. A model-generated `true` alone is not consent. Hosts must
control approval and must not automatically approve these calls. This is an
OPSd host contract, not a standard MCP authorization mechanism or a filesystem
sandbox. Paths use the configured workspace as a base and may name locations
outside it under the process user's permissions.

Manifest mutations edit local files; synchronization writes dependencies and
pins. Neither applies infrastructure. The
host should request new approval if the tool or its arguments change. Rendering
and export remain available without this gate, so hosts should also make their
file writes visible when presenting tool calls.

## Related Docs

- [MCP Server](./mcp-server.md)
- [MCP Resources](./mcp-resources.md)
- [MCP Prompts](./mcp-prompts.md)
- [Command Reference](./commands.md)
