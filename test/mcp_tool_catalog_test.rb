# frozen_string_literal: true

require "tmpdir"
require "minitest/autorun"
require "opsd/mcp_tool_catalog"

class McpToolCatalogTest < Minitest::Test
  def test_lists_supported_tools_and_confirmation_flags
    catalog = tool_catalog(fixture_workspace_root)

    tools = catalog.tools

    assert_includes tools.map { |tool| tool.fetch("name") }, "validate-manifest"
    assert_includes tools.map { |tool| tool.fetch("name") }, "verify-config"
    assert_includes tools.map { |tool| tool.fetch("name") }, "verify-plan"
    assert_includes tools.map { |tool| tool.fetch("name") }, "render-manifest"
    assert_includes tools.map { |tool| tool.fetch("name") }, "export-exit-pack"
    assert_includes tools.map { |tool| tool.fetch("name") }, "add-compute-group"

    assert_equal false, catalog.tool("validate-manifest").requires_confirmation
    assert_equal false, catalog.tool("render-manifest").requires_confirmation
    assert_equal true, catalog.tool("add-compute-group").requires_confirmation
    assert_equal true, catalog.tool("remove-resource").requires_confirmation
  end

  def test_tool_schemas_match_cli_arguments
    catalog = tool_catalog(fixture_workspace_root)

    validate = catalog.tool("validate-manifest")
    render = catalog.tool("render-manifest")
    add = catalog.tool("add-compute-group")

    assert_equal [{ "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" }], validate.arguments
    assert_equal [
      { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
      { "name" => "output_dir", "required" => true, "description" => "Directory for rendered output" }
    ], render.arguments
    assert_equal %w[add compute-group], add.cli
  end

  def test_dispatch_maps_non_destructive_tools_to_known_cli_actions
    catalog = tool_catalog(fixture_workspace_root)

    assert_equal %w[list blueprints], catalog.dispatch("list-blueprints")
    assert_equal %w[describe blueprint kubernetes-foundation --variant kubernetes], catalog.dispatch(
      "describe-blueprint",
      { "blueprint" => "kubernetes-foundation", "variant" => "kubernetes" }
    )
    assert_equal %w[validate manifest demo.yaml], catalog.dispatch(
      "validate-manifest",
      { "manifest_path" => "demo.yaml" }
    )
    assert_equal %w[verify plan plan.json], catalog.dispatch(
      "verify-plan",
      { "plan_path" => "plan.json" }
    )
    assert_equal %w[render manifest demo.yaml --output live], catalog.dispatch(
      "render-manifest",
      { "manifest_path" => "demo.yaml", "output_dir" => "live" }
    )
    assert_equal %w[export exit-pack rendered --output exit-pack.tar.gz], catalog.dispatch(
      "export-exit-pack",
      { "rendered_dir" => "rendered", "output_path" => "exit-pack.tar.gz" }
    )
  end

  def test_dispatch_requires_confirmation_for_risky_tools
    catalog = tool_catalog(fixture_workspace_root)

    error = assert_raises(RuntimeError) do
      catalog.dispatch(
        "remove-resource",
        { "resource" => "database", "manifest_path" => "demo.yaml", "resource_id" => "db-main" }
      )
    end

    assert_equal "Tool remove-resource requires explicit confirmation", error.message
  end

  def test_dispatch_of_confirmed_risky_tool_returns_cli_arguments
    catalog = tool_catalog(fixture_workspace_root)

    args = catalog.dispatch(
      "remove-resource",
      { "resource" => "database", "manifest_path" => "demo.yaml", "resource_id" => "db-main" },
      confirmed: true
    )

    assert_equal %w[remove database demo.yaml db-main], args
  end

  def test_unknown_tool_raises_a_clear_error
    catalog = tool_catalog(fixture_workspace_root)

    error = assert_raises(RuntimeError) do
      catalog.dispatch("missing-tool", {})
    end

    assert_equal "Unsupported MCP tool: missing-tool", error.message
  end

  private

  def fixture_workspace_root
    File.expand_path("..", __dir__)
  end

  def tool_catalog(workspace_root)
    OPSd::McpToolCatalog.new(
      app_root: fixture_workspace_root,
      workspace_root: workspace_root
    )
  end
end
