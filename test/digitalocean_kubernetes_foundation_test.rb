# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"

require "opsd/contract_store"
require "opsd/manifest"
require "opsd/renderer"
require "opsd/template_store"

class KubernetesFoundationTest < Minitest::Test
  def test_provider_catalog_exposes_only_the_current_foundation_blueprint
    Dir.mktmpdir("opsd-foundation-catalog") do |workspace|
      blueprint_root = File.join(workspace, "modules", "digitalocean", "blueprints")
      FileUtils.mkdir_p(blueprint_root)
      File.write(File.join(blueprint_root, "kubernetes-foundation.yaml"), <<~YAML)
        id: kubernetes-foundation
        title: Kubernetes foundation
        provider: digitalocean
        variants:
          - id: kubernetes
            stack: kubernetes-foundation
      YAML

      store = OPSd::TemplateStore.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: workspace,
        contract_store: OPSd::ContractStore.new(app_root: File.expand_path("..", __dir__))
      )

      assert_equal ["kubernetes-foundation"], store.blueprint_ids(provider: "digitalocean")
      blueprint = store.blueprint(provider: "digitalocean", id: "kubernetes-foundation")
      assert_equal ["kubernetes"], blueprint.fetch(:variants).map { |variant| variant.fetch("id") }
      assert_equal "kubernetes-foundation", blueprint.fetch(:variants).first.fetch("stack")
    end
  end

  def test_kubernetes_foundation_renders_core_and_layer_plan
    manifest = OPSd::Manifest.new(YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__)))

    Dir.mktmpdir("opsd-foundation-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      scenario = OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: output_dir
      ).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890"
        }
      )

      assert_equal "kubernetes-foundation", scenario
      main_tf = File.read(File.join(output_path, "main.tf"))
      assert_includes main_tf, "modules-digitalocean.git//modules/kubernetes?ref=v1.0.0"
      assert_includes main_tf, "modules-digitalocean.git//modules/vpc?ref=v1.0.0"
      assert File.file?(File.join(output_path, "opsd.layers.yaml"))
      assert File.file?(File.join(output_path, "layers", "bootstrap", "README.md"))
    end
  end

  def test_kubernetes_foundation_renders_optional_redis
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    manifest_data.fetch("spec").fetch("caches") << {
      "id" => "cache-main",
      "engine" => "redis",
      "profile" => "db-s-1vcpu-1gb"
    }
    manifest = OPSd::Manifest.new(manifest_data)

    Dir.mktmpdir("opsd-foundation-redis-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: output_dir
      ).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890"
        }
      )

      main_tf = File.read(File.join(output_path, "main.tf"))
      assert_includes main_tf, 'module "redis"'
      assert_includes main_tf, "modules-digitalocean.git//modules/managed-redis?ref=v1.0.0"
      assert_includes main_tf, "project_resource_urns = concat"
      assert_includes main_tf, "module.redis.urn"
    end
  end
end
