# MCP Tools

OPSd exposes a small set of MCP tool definitions that map directly onto the
existing CLI workflow.

The tool catalog is intentionally conservative:

- non-destructive workflow tools map one-to-one to known CLI actions
- risky mutation tools are marked as requiring explicit confirmation
- no separate product model is introduced

## Non-Destructive Tools

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

## Mapping Rule

The tool catalog mirrors CLI semantics closely enough that a host can convert a
tool invocation into a concrete OPSd command-line action.

For confirmation-gated tools, the host should request an explicit user
confirmation before dispatching the command.

## Related Docs

- [MCP Server](./mcp-server.md)
- [MCP Resources](./mcp-resources.md)
- [MCP Prompts](./mcp-prompts.md)
- [Command Reference](./commands.md)
