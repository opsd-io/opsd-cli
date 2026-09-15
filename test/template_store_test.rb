# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "minitest/autorun"
require "opsd/contract_store"
require "opsd/template_store"

class TemplateStoreTest < Minitest::Test
  def test_provider_supported_includes_cached_release_blueprint_roots
    Dir.mktmpdir("opsd-template-store") do |workspace|
      cached_blueprint_root = File.join(workspace, ".opsd", "cache", "releases", "digitalocean", "main", "modules", "digitalocean", "blueprints")
      FileUtils.mkdir_p(cached_blueprint_root)
      File.write(File.join(cached_blueprint_root, "kubernetes-foundation.yaml"), <<~YAML)
        id: kubernetes-foundation
        title: Kubernetes foundation
        variants:
          - id: kubernetes
            title: Kubernetes Runtime
      YAML

      store = OPSd::TemplateStore.new(app_root: File.expand_path("..", __dir__), workspace_root: workspace)

      assert store.provider_supported?("digitalocean")
      assert_equal ["kubernetes-foundation"], store.blueprint_ids(provider: "digitalocean")
    end
  end

  def test_cached_release_blueprint_entries_are_loaded_from_main_release_first
    Dir.mktmpdir("opsd-template-store") do |workspace|
      main_root = File.join(workspace, ".opsd", "cache", "releases", "digitalocean", "main", "modules", "digitalocean", "blueprints")
      alt_root = File.join(workspace, ".opsd", "cache", "releases", "digitalocean", "v1.0.0", "modules", "digitalocean", "blueprints")

      FileUtils.mkdir_p(main_root)
      FileUtils.mkdir_p(alt_root)
      File.write(File.join(main_root, "kubernetes-foundation.yaml"), <<~YAML)
        id: kubernetes-foundation
        title: Main Release Blueprint
        variants:
          - id: vm
            title: VM Runtime
      YAML
      File.write(File.join(alt_root, "kubernetes-foundation.yaml"), <<~YAML)
        id: kubernetes-foundation
        title: Older Blueprint
        variants:
          - id: vm
            title: VM Runtime
      YAML

      store = OPSd::TemplateStore.new(app_root: File.expand_path("..", __dir__), workspace_root: workspace)

      assert_equal "Main Release Blueprint", store.blueprint(provider: "digitalocean", id: "kubernetes-foundation")[:title]
    end
  end

  def test_providers_are_filtered_by_active_contract_providers
    Dir.mktmpdir("opsd-template-store") do |workspace|
      digitalocean_root = File.join(workspace, "modules", "digitalocean", "blueprints")
      aws_root = File.join(workspace, "modules", "aws", "blueprints")

      FileUtils.mkdir_p(digitalocean_root)
      FileUtils.mkdir_p(aws_root)

      contract_store = OPSd::ContractStore.new(app_root: File.expand_path("..", __dir__))
      store = OPSd::TemplateStore.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: workspace,
        contract_store: contract_store
      )

      assert_equal ["digitalocean"], store.providers
      assert store.provider_supported?("digitalocean")
      refute store.provider_supported?("aws")
    end
  end
end
