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

## Protocol Qualification

Run both local suites before changing the MCP protocol implementation:

```bash
sh scripts/ci/run_unit_cli_tests.sh
sh scripts/ci/run_mcp_protocol_tests.sh
```

The protocol runner requires the activated repository Ruby, Python 3.11, and
[`uv`](https://docs.astral.sh/uv/) (CI uses `0.13.1`). Its first run downloads
locked Python test dependencies; the CLI itself still has no Python dependency.

The independent suite uses the official Python MCP SDK `2.3.0` with protocol
mode explicitly set to `2026-07-28`, so it cannot pass by falling back to the
legacy handshake. It checks discovery, catalogs, resource reads, prompt
rendering, confirmation refusal, and error recovery against the real launcher
in a temporary workspace. Real tool execution is covered as it is implemented
in W9.2; final workflow and portable-bundle qualification belong to W9.6.

Wire tests validate actual request and response messages against the unmodified
upstream JSON Schema, vendored under `test/mcp/schema/`. The source commit is
`271ecc9accafdd9b83a3c869fa67c22953b2af80`; `provenance.json` records its source
URL and SHA-256. The upstream license is preserved alongside it. Schema checks
resolve local references only, without fetching schemas during test execution.
Deliberately malformed request fixtures and corrupted response copies must
fail validation, independently of OPSd's serializers and Ruby test helpers.

The `MCP protocol` GitHub Actions workflow runs both suites on every pull
request and on `main`. RPC reads and process shutdown are bounded, and child
processes are cleaned up on failure. The tests require no cloud credentials.

To update dependencies, edit `test/mcp/pyproject.toml`, regenerate
`test/mcp/uv.lock` with `uv lock --project test/mcp`, and run both suites.
To update the official schema, select an immutable upstream commit, replace
the unmodified schema and license, update `provenance.json` (including its
SHA-256), and rerun the tests; never relax the schema to accommodate a server
regression.

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
