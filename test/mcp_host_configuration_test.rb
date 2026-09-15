# frozen_string_literal: true

require "minitest/autorun"

class McpHostConfigurationTest < Minitest::Test
  def test_host_configuration_page_documents_claude_and_codex
    docs = File.read(path("docs/reference/mcp-hosts.md"))

    assert_includes docs, "# MCP Host Configuration"
    assert_includes docs, "Claude Desktop"
    assert_includes docs, "codex mcp add opsd"
    assert_includes docs, ".vscode/mcp.json"
    assert_includes docs, "Copilot Chat in Agent mode"
    assert_includes docs, "OPSD_APP_ROOT"
    assert_includes docs, "OPSD_WORKSPACE_ROOT"
  end

  def test_main_docs_index_links_to_host_configuration
    assert_includes File.read(path("docs/index.md")), "[MCP Host Configuration](./reference/mcp-hosts.md)"
    assert_includes File.read(path("docs/reference/mcp-server.md")), "[MCP Host Configuration](./mcp-hosts.md)"
  end

  private

  def path(relative_path)
    File.expand_path("../#{relative_path}", __dir__)
  end
end
