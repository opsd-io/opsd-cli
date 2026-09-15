# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "minitest/autorun"
require "opsd/mcp_config"

class McpConfigTest < Minitest::Test
  def test_generator_builds_a_ready_to_paste_host_config
    config = OPSd::McpConfig.new(app_root: app_root, workspace_root: workspace_root)
    payload = config.payload

    assert_equal File.join(app_root, "bin", "opsd-mcp"), payload.dig("mcpServers", "opsd", "command")
    assert_equal app_root, payload.dig("mcpServers", "opsd", "env", "OPSD_APP_ROOT")
    assert_equal workspace_root, payload.dig("mcpServers", "opsd", "env", "OPSD_WORKSPACE_ROOT")
  end

  def test_launcher_config_subcommand_prints_json
    Dir.mktmpdir("opsd-mcp-config") do |workspace|
      stdout, stderr, status = Open3.capture3(
        {
          "RUBY_BIN" => RbConfig.ruby,
          "OPSD_WORKSPACE_ROOT" => workspace
        },
        File.expand_path("../bin/opsd-mcp", __dir__),
        "config"
      )

      assert_predicate status, :success?
      assert_equal "", stderr

      payload = JSON.parse(stdout)
      assert_equal File.expand_path("../bin/opsd-mcp", __dir__), payload.fetch("mcpServers").fetch("opsd").fetch("command")
      assert_equal File.expand_path("..", __dir__), payload.fetch("mcpServers").fetch("opsd").fetch("env").fetch("OPSD_APP_ROOT")
      assert_equal workspace, payload.fetch("mcpServers").fetch("opsd").fetch("env").fetch("OPSD_WORKSPACE_ROOT")
    end
  end

  private

  def app_root
    File.expand_path("..", __dir__)
  end

  def workspace_root
    File.expand_path("../..", app_root)
  end
end
