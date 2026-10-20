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
`OPSD_WORKSPACE_ROOT` before launching it. Use absolute paths; generated host
configuration expands both roots to absolute paths. The launcher's location
selects the default app, so starting it from another directory does not select
that directory as the workspace.

Contracts, docs, and examples belong to the app. Module catalogs, profiles,
manifest paths, and generated output belong to the selected workspace. See
[resource ownership](./mcp-resources.md#ownership-and-workspace-lookup) for
lookup rules and missing-content behavior.

Tool subprocesses run in the selected workspace. `OPSD_PROFILE` overrides the
workspace's `.opsd/config` current profile; otherwise the CLI uses that current
profile. The host's working directory and its configuration are not consulted.
A missing profile produces CLI setup guidance rather than selecting a default
provider. Resource URIs with explicit providers remain available without a
profile.

MCP sets `OPSD_MODULES_OFFLINE=1` for CLI subprocesses, using prepared local
modules or existing workspace release caches. Missing modules return an
operational tool error with `opsd modules sync <manifest.yaml>` guidance.
The explicit `modules-sync` tool requires user confirmation and permits module
downloads; it is the only tool that disables the module-resolution restriction.
Synchronization can also be performed directly through the CLI. Pinned rendering checks synchronized module
integrity and refuses changed or missing pinned modules. Direct CLI execution
keeps its normal module resolution behavior unless this environment flag is set.

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
rendering, confirmation metadata, refusal, and error recovery against the real launcher
in a temporary workspace. Execution tests verify actual CLI results for
blueprint discovery, manifest validation, config/plan/lifecycle verification,
rendering and exit-pack export, including filesystem artifacts, error cases,
literal path handling, and confirmed mutations. Platform workflow tests execute synchronization with
local Git repositories, check rendered artifacts and preserved pins, and use
external-tool stand-ins to verify option forwarding and offline cache behavior.
Workspace tests cover app-owned
resources, missing modules, cached catalogs, profile selection, stale module
pins, and execution from an unrelated host directory. Final combined
workflow and portable-bundle qualification run alongside these feature tests.

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
- executable tools for discovery, verification, rendering, and packaging
- executable manifest mutation tools gated by explicit user confirmation through the host

Manifest mutations require `arguments.confirmed: true` on every call after the
host obtains user approval. See the [confirmation contract](./mcp-tools.md#effects-and-confirmation)
for effects, refusal behavior, and the limits of this gate.

For the catalog details, see:

- [MCP Resources](./mcp-resources.md)
- [MCP Prompts](./mcp-prompts.md)
- [MCP Tools](./mcp-tools.md)

For host-specific setup examples, see [MCP Host Configuration](./mcp-hosts.md).

## Complete Workflow and Bundle Qualification

The existing official SDK `2.3.0` and vendored schema pins are reused unchanged.
The combined scenario performs discovery, resource/prompt reads, confirmation
refusal and approved mutation, validation, pinned platform rendering, failure
recovery, and exit-pack artifact checks in one temporary workspace.

```bash
sh scripts/ci/run_unit_cli_tests.sh
sh scripts/ci/run_mcp_protocol_tests.sh
sh scripts/ci/run_mcp_real_tools_tests.sh
sh scripts/release/build_portable_bundle.sh
# Requalify an existing archive:
sh scripts/ci/run_mcp_bundle_tests.sh /absolute/path/to/opsd_<version>_<os>_<arch>.tar.gz
```

The fast SDK suite uses local repositories and external-tool stand-ins. The
separate real-tools scenario uses Git, Helm, Terraform, OpenTofu, and kubeconform
at the versions in `.tool-versions`. It fetches the exact public provider commit
recorded in `test/mcp/fixtures/real-tools.json`, packages a tiny local Helm chart
with the required CRDs, synchronizes explicit dependency pins, renders real
artifacts, warms provider/schema caches online, and validates again offline
with HTTP proxies directed at an unavailable local port. No cloud credentials,
cluster access, plan/apply, or infrastructure provisioning are used.

The real-tools scenario needs outbound access during initial source/plugin/schema
preparation. Missing tools or version mismatches fail explicitly. `uv` and
Python 3.11 are test/build dependencies, not installed-product dependencies.

Portable qualification extracts the archive into a path containing spaces and
launches it from an unrelated directory. It runs the same SDK/feature/combined
suite and the real-tools scenario with the bundled runtime. It checks that Ruby
and its loaded standard libraries resolve inside the extracted artifact.
`OPSD_MCP_TEST_APP_ROOT` selects the artifact under test; SDK/schema fixtures
remain in the source test tree. Test manifests, managed modules, caches, and
output are temporary synthetic data.

`MCP protocol` runs the fast suite on every PR and main push, and complete
checkout/bundle qualification on Linux and macOS without path filters. Release
Please waits for this reusable qualification workflow before creating a release.
Every portable build also qualifies its extracted artifact before returning an
archive for upload, including tag/manual release builds.

RPC reads, complete sessions, setup subprocesses, and CI jobs have bounded
waits; the official SDK and process-group cleanup tear down child processes.
On CI failure, qualification logs and synthetic workflow diagnostics are retained
as a seven-day artifact. Locally, set `OPSD_MCP_DIAGNOSTICS` to a diagnostics
directory; real-tool failures otherwise write under `.tmp/mcp-diagnostics`.
