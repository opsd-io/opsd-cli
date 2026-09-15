# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "minitest/autorun"
require "opsd/contract_store"
require "opsd/mcp_resource_catalog"
require "opsd/template_store"

class McpResourceCatalogTest < Minitest::Test
  def test_lists_read_only_mcp_resources
    Dir.mktmpdir("opsd-mcp-resource-catalog") do |workspace|
      write_blueprint(workspace, "kubernetes-foundation", <<~YAML)
        id: kubernetes-foundation
        title: Kubernetes foundation
        description: Deploy a Kubernetes foundation.
        usecases:
          - kubernetes
          - foundation
        variants:
          - id: kubernetes
            title: Kubernetes Runtime
            description: Run Kubernetes on DigitalOcean.
            components:
              - kubernetes
          - id: kubernetes-minimal
            title: Minimal Kubernetes Runtime
            description: Run a minimal Kubernetes foundation.
            components:
              - kubernetes
      YAML

      catalog = resource_catalog(workspace)

      uris = catalog.resources.map { |resource| resource.fetch("uri") }

      assert_includes uris, "opsd://contract"
      assert_includes uris, "opsd://rule-packs"
      assert_includes uris, "opsd://catalog/blueprints/digitalocean"
      assert_includes uris, "opsd://catalog/supported-paths/digitalocean"
      assert_includes uris, "opsd://examples"
      assert_includes uris, "opsd://docs/pointers"
    end
  end

  def test_contract_and_rule_pack_payloads_match_the_machine_readable_contract
    catalog = resource_catalog(fixture_workspace_root)

    contract = JSON.parse(catalog.read("opsd://contract"))
    rule_packs = JSON.parse(catalog.read("opsd://rule-packs"))
    supported_paths = JSON.parse(catalog.read("opsd://catalog/supported-paths/digitalocean"))

    assert_equal 1, contract.fetch("contract_version")
    assert_equal "opsd.io/v2alpha1", contract.fetch("api_version")
    assert_equal "Environment", contract.fetch("kind")
    assert_includes contract.fetch("manifest").fetch("provider_models").keys, "digitalocean"
    assert_includes contract.fetch("manifest").fetch("provider_models").fetch("digitalocean").fetch("supported_paths").map { |path| path.fetch("id") }, "digitalocean-reference-droplet-single"
    assert_equal contract.fetch("manifest").fetch("provider_models").fetch("digitalocean").fetch("supported_paths"), supported_paths.fetch("supported_paths")
    assert_equal "reference", supported_paths.fetch("status")
    assert_equal contract.fetch("rule_packs"), rule_packs.fetch("rule_packs")
    assert_includes rule_packs.fetch("rule_packs").keys, "security"
  end

  def test_blueprint_catalog_payload_matches_template_store_facts
    Dir.mktmpdir("opsd-mcp-blueprints") do |workspace|
      write_blueprint(workspace, "kubernetes-foundation", <<~YAML)
        id: kubernetes-foundation
        title: Kubernetes foundation
        description: Deploy a Kubernetes foundation.
        usecases:
          - kubernetes
          - foundation
        variants:
          - id: kubernetes
            title: Kubernetes Runtime
            description: Run Kubernetes on DigitalOcean.
            components:
              - kubernetes
      YAML

      template_store = template_store_for(workspace)
      catalog = resource_catalog(workspace, template_store: template_store)

      payload = JSON.parse(catalog.read("opsd://catalog/blueprints/digitalocean"))
      blueprints = payload.fetch("blueprints")

      assert_equal "digitalocean", payload.fetch("provider")
      assert_equal template_store.blueprint_ids(provider: "digitalocean"), blueprints.map { |blueprint| blueprint.fetch("id") }
      assert_equal template_store.blueprint(provider: "digitalocean", id: "kubernetes-foundation")[:variants].map { |variant| variant.fetch("id") }, blueprints.first.fetch("variants").map { |variant| variant.fetch("id") }
      assert_equal "Kubernetes foundation", blueprints.first.fetch("title")
      assert_equal %w[kubernetes foundation], blueprints.first.fetch("usecases")
    end
  end

  def test_examples_and_docs_pointer_payloads_are_machine_readable
    catalog = resource_catalog(fixture_workspace_root)

    examples = JSON.parse(catalog.read("opsd://examples"))
    docs = JSON.parse(catalog.read("opsd://docs/pointers"))

    assert_includes examples.fetch("examples").map { |example| example.fetch("id") }, "acme-cluster-prod"
    assert_includes examples.fetch("examples").map { |example| example.fetch("blueprint") }, "kubernetes-foundation"
    assert_includes docs.fetch("docs").map { |doc| doc.fetch("path") }, "docs/manifest.md"
    assert_includes docs.fetch("docs").map { |doc| doc.fetch("path") }, "docs/reference/commands.md"
  end

  def test_unknown_resource_uri_raises_a_clear_error
    catalog = resource_catalog(fixture_workspace_root)

    error = assert_raises(RuntimeError) do
      catalog.read("opsd://catalog/unknown")
    end

    assert_equal "Unsupported MCP resource: opsd://catalog/unknown", error.message
  end

  private

  def fixture_workspace_root
    File.expand_path("..", __dir__)
  end

  def resource_catalog(workspace_root, template_store: nil)
    contract_store = OPSd::ContractStore.new(app_root: fixture_workspace_root)
    template_store ||= template_store_for(workspace_root)

    OPSd::McpResourceCatalog.new(
      app_root: fixture_workspace_root,
      workspace_root: workspace_root,
      contract_store: contract_store,
      template_store: template_store
    )
  end

  def template_store_for(workspace_root)
    contract_store = OPSd::ContractStore.new(app_root: fixture_workspace_root)
    OPSd::TemplateStore.new(
      app_root: fixture_workspace_root,
      workspace_root: workspace_root,
      contract_store: contract_store
    )
  end

  def write_blueprint(workspace_root, blueprint_id, yaml)
    blueprint_root = File.join(workspace_root, "modules", "digitalocean", "blueprints")
    FileUtils.mkdir_p(blueprint_root)
    File.write(File.join(blueprint_root, "#{blueprint_id}.yaml"), yaml)
  end
end
