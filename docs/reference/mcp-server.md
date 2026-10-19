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

The server speaks UTF-8 JSON-RPC over `stdio`, with one JSON message per line.
Messages use a trailing newline, without transport headers. Diagnostic output
is written only to `stderr`.

The only supported protocol revision is
[`2026-07-28`](https://modelcontextprotocol.io/specification/2026-07-28).
Clients must support per-request protocol metadata. Earlier revisions and their
`initialize` / `notifications/initialized` handshake are not supported.

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

Every request must include `params._meta` with these fields:

- `io.modelcontextprotocol/protocolVersion`: `"2026-07-28"`
- `io.modelcontextprotocol/clientCapabilities`: an object (`{}` is valid)
- `io.modelcontextprotocol/clientInfo`: optional client identity with `name`
  and `version`; clients should include it

Hosts may call `server/discover` to inspect supported versions, capabilities,
and server guidance. Discovery is optional: any supported operation can be the
first request. For example, the following is a complete stdio request line:

```json
{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
```

Then discover available content using `resources/list`,
`resources/templates/list`, `prompts/list`, and `tools/list`, or directly use
`resources/read`, `prompts/get`, and `tools/call`. Include protocol metadata on
every request; previous requests do not establish a session or client capabilities.

Successful results include `resultType: "complete"` and server identity in
`result._meta.io.modelcontextprotocol/serverInfo`. Cacheable results, including
`server/discover`, catalog lists, and resource reads, use `ttlMs: 0` and
`cacheScope: "private"` because workspace content can change between calls.

Missing or malformed metadata produces `-32602` (Invalid params). Unsupported
versions produce `-32022` with `supported` and `requested` in the error data.
Legacy `initialize` requests are rejected with a diagnostic naming the supported
revision. There is no fallback to an earlier protocol.

To stop the server, close its standard input and wait for the process to exit.
The server does not implement `initialize`, `ping`, `shutdown`, or `exit` RPCs.
Malformed JSON produces a parse error response; subsequent valid messages can
still be processed. Unknown notifications are ignored without responses.

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
