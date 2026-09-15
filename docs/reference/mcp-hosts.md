# MCP Host Configuration

OPSd can be connected to any MCP host that supports the MCP `stdio` transport.
The command below prints a ready-to-paste host snippet for the current checkout
or a separate workspace:

```bash
bin/opsd-mcp config --workspace-root /path/to/workspace
```

The generated JSON is meant to be copied into the host application's MCP
configuration.

## Claude Desktop

Claude Desktop reads its MCP configuration from:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`

Add the generated `mcpServers` entry to that file, for example:

```json
{
  "mcpServers": {
    "opsd": {
      "command": "/path/to/opsd/bin/opsd-mcp",
      "env": {
        "OPSD_APP_ROOT": "/path/to/opsd",
        "OPSD_WORKSPACE_ROOT": "/path/to/workspace"
      }
    }
  }
}
```

Restart Claude Desktop after saving the file.

## Codex CLI

Codex supports MCP servers from the CLI, TUI, and IDE extension. For the CLI,
add OPSd with:

```bash
codex mcp add opsd --env OPSD_APP_ROOT=/path/to/opsd --env OPSD_WORKSPACE_ROOT=/path/to/workspace -- /path/to/opsd/bin/opsd-mcp
```

You can also declare the same server in `~/.codex/config.toml`:

```toml
[mcp_servers.opsd]
command = "/path/to/opsd/bin/opsd-mcp"

[mcp_servers.opsd.env]
OPSD_APP_ROOT = "/path/to/opsd"
OPSD_WORKSPACE_ROOT = "/path/to/workspace"
```

Then run `codex mcp list` to confirm the server is registered, or use `/mcp`
in the TUI to inspect active MCP servers.

## VS Code

VS Code can load MCP servers from a workspace-local `.vscode/mcp.json` file or
from a user-level configuration.

For a workspace-local setup, create `.vscode/mcp.json` with an OPSd server
entry like this:

```json
{
  "servers": {
    "opsd": {
      "command": "/path/to/opsd/bin/opsd-mcp",
      "env": {
        "OPSD_APP_ROOT": "/path/to/opsd",
        "OPSD_WORKSPACE_ROOT": "/path/to/workspace"
      }
    }
  }
}
```

Open Copilot Chat in Agent mode, start the MCP server from the configuration,
and then use the OPSd tools from the chat tool picker.

## Path Meaning

- `OPSD_APP_ROOT` points at the OPSd checkout or bundle.
- `OPSD_WORKSPACE_ROOT` points at the workspace the MCP server should inspect.
- The generated command path should be absolute.

If you are using the bundled release artifact, the command path should point to
that bundle's `bin/opsd-mcp`.
