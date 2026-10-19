# MCP Tools

OPSd exposes a small set of MCP tool definitions that map directly onto the
existing CLI workflow.

The tool catalog is intentionally conservative:

- workflow tools execute the corresponding CLI action
- manifest mutation tools remain blocked pending the confirmation policy in W9.3
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

Workflow tools run `bin/opsd` as a child process, using the configured
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
modules. `render-manifest` writes generated files and the CLI lock file;
`export-exit-pack` writes an archive. Existing CLI overwrite protections apply.
See [Setup](../getting-started/setup.md) for workspace preparation.

## Mutation Availability

The six confirmation-gated tools above are advertised but cannot execute yet,
even when `confirmed: true` is supplied. Calls return `isError: true` with a
W9.3 diagnostic before starting the CLI or modifying the manifest. W9.3 defines
the host-visible confirmation contract and enables these operations with tests
for refusal before side effects and for confirmed changes.

## Related Docs

- [MCP Server](./mcp-server.md)
- [MCP Resources](./mcp-resources.md)
- [MCP Prompts](./mcp-prompts.md)
- [Command Reference](./commands.md)
