# OPSd MCP Server

OPSd ships a small MCP server entrypoint for hosts that want to connect over
the standard MCP `stdio` transport.

The launcher is:

```bash
bin/opsd-mcp
```

To generate a ready-to-paste host configuration snippet, run:

```bash
bin/opsd-mcp config
```

You can override the workspace root when generating the snippet:

```bash
bin/opsd-mcp config --workspace-root /path/to/workspace
```

The command prints a JSON config block with `command` and `env` fields already
pointing at the current checkout or bundle.

## Transport

The server speaks JSON-RPC over `stdio`, following the MCP framing format with
`Content-Length` headers.

This keeps transport concerns separate from the OPSd domain model:

- resources come from `OPSd::McpResourceCatalog`
- prompts come from `OPSd::McpPromptCatalog`
- tools come from `OPSd::McpToolCatalog`

## Environment

The launcher uses the same app-root and workspace-root assumptions as the rest
of OPSd:

- `OPSD_APP_ROOT` defaults to the repository root
- `OPSD_WORKSPACE_ROOT` defaults to `OPSD_APP_ROOT`

If you want to point the server at a separate workspace, set
`OPSD_WORKSPACE_ROOT` before launching it.

## Discovery Flow

MCP hosts should:

1. send `initialize`
2. wait for the server response
3. send `notifications/initialized`
4. discover available content with:
   - `resources/list`
   - `prompts/list`
   - `tools/list`

After discovery, hosts can read resources, render prompts, and call tools using
the same stdio session.

## Supported Surface

The server exposes the existing OPSd catalogs without adding new contract
semantics:

- read-only resources for contract, docs, blueprints, and supported paths
- reusable prompts for inspect and verify workflows
- tool calls for discovery, verification, rendering, packaging, and the
  current mutation surface

For the catalog details, see:

- [MCP Resources](./mcp-resources.md)
- [MCP Prompts](./mcp-prompts.md)
- [MCP Tools](./mcp-tools.md)

For host-specific setup examples, see [MCP Host Configuration](./mcp-hosts.md).
