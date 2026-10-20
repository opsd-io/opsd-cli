# MCP Tools

OPSd exposes a small set of MCP tool definitions that map directly onto the
existing CLI workflow.

The tool catalog is intentionally conservative:

- workflow tools execute the corresponding CLI action
- manifest mutation tools require explicit user confirmation through the host
- no separate product model is introduced

## Workflow Tools

- `list-blueprints`
- `describe-blueprint`
- `validate-manifest`
- `verify-config`
- `verify-plan`
- `verify-lifecycle`
- `render-manifest`
- `export-exit-pack`

## Confirmation-Gated Tools

- `add-compute-group`
- `resize-compute-group`
- `scale-compute-group`
- `attach-compute-group`
- `detach-compute-group`
- `remove-resource`

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
modules. Tool subprocesses set `OPSD_MODULES_OFFLINE=1`; prepare missing
modules explicitly with `opsd modules sync <manifest.yaml>` outside MCP.
`render-manifest` writes generated files and the CLI lock file;
`export-exit-pack` writes an archive. Existing CLI overwrite protections apply.
See [Setup](../getting-started/setup.md) for workspace preparation.

## Effects and Confirmation

`tools/list` classifies every tool using `_meta.io.opsd/effect` and
`_meta.io.opsd/requiresConfirmation`:

| Effect | Tools | Confirmation |
| --- | --- | --- |
| `read-only` | Catalog discovery, validation, and verification | Not required |
| `generated-files` | `render-manifest`, `export-exit-pack` | Not required; writes generated output |
| `manifest-mutation` | The six confirmation-gated tools above | Required on every call |

Standard MCP annotations expose `readOnlyHint`, `destructiveHint`, and
`openWorldHint`. Generated output is marked as writable and potentially
replacing files. These annotations describe effects; they do not grant approval.

Each manifest mutation declares an optional boolean `confirmed` input. The
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

These tools edit local manifest files; they do not apply infrastructure. The
host should request new approval if the tool or its arguments change. Rendering
and export remain available without this gate, so hosts should also make their
file writes visible when presenting tool calls.

## Related Docs

- [MCP Server](./mcp-server.md)
- [MCP Resources](./mcp-resources.md)
- [MCP Prompts](./mcp-prompts.md)
- [Command Reference](./commands.md)
