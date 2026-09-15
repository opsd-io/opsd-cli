# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "minitest/autorun"
require "opsd/mcp_prompt_catalog"

class McpPromptCatalogTest < Minitest::Test
  def test_lists_reusable_mcp_prompts
    catalog = prompt_catalog(fixture_workspace_root)

    names = catalog.prompts.map(&:name)

    assert_equal %w[
      inspect-blueprint
      inspect-manifest
      verify-config
      verify-plan
      export-exit-pack
    ], names
  end

  def test_rendered_prompt_text_includes_contract_and_verification_context
    Dir.mktmpdir("opsd-mcp-prompts") do |workspace|
      write_blueprint(workspace, "kubernetes-foundation", <<~YAML)
        id: kubernetes-foundation
        title: Kubernetes foundation
        variants:
          - id: kubernetes
            title: Kubernetes Runtime
      YAML

      catalog = prompt_catalog(workspace)

      inspect_prompt = catalog.render(
        "inspect-blueprint",
        provider: "digitalocean",
        blueprint: "kubernetes-foundation",
        variant: "kubernetes"
      )
      verify_prompt = catalog.render(
        "verify-config",
        manifest_path: "demo.yaml"
      )
      export_prompt = catalog.render(
        "export-exit-pack",
        rendered_dir: "./rendered",
        output_path: "./exit-pack.tar.gz"
      )

      assert_includes inspect_prompt, "Inspect the OPSd blueprint `kubernetes-foundation`"
      assert_includes inspect_prompt, "blueprint variants: kubernetes"
      assert_includes inspect_prompt, "supported paths: droplet-single:vm"
      assert_includes inspect_prompt, "Prefer OPSd terms from the contract and docs"

      assert_includes verify_prompt, "Verify the OPSd manifest at `demo.yaml`"
      assert_includes verify_prompt, "verify config"
      assert_includes verify_prompt, "manifest.required_top_level_keys"
      assert_includes verify_prompt, "rule packs"

      assert_includes export_prompt, "Export the rendered OPSd handoff in `./rendered`"
      assert_includes export_prompt, "docs/exit-pack.md"
      assert_includes export_prompt, "Output path: ./exit-pack.tar.gz"
    end
  end

  def test_unknown_prompt_raises_a_clear_error
    catalog = prompt_catalog(fixture_workspace_root)

    error = assert_raises(RuntimeError) do
      catalog.render("missing-prompt", manifest_path: "demo.yaml")
    end

    assert_equal "Unsupported MCP prompt: missing-prompt", error.message
  end

  private

  def fixture_workspace_root
    File.expand_path("..", __dir__)
  end

  def prompt_catalog(workspace_root)
    OPSd::McpPromptCatalog.new(
      app_root: fixture_workspace_root,
      workspace_root: workspace_root
    )
  end

  def write_blueprint(workspace_root, blueprint_id, yaml)
    blueprint_root = File.join(workspace_root, "modules", "digitalocean", "blueprints")
    FileUtils.mkdir_p(blueprint_root)
    File.write(File.join(blueprint_root, "#{blueprint_id}.yaml"), yaml)
  end
end
