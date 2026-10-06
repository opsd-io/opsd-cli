# frozen_string_literal: true

require "digest"
require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

require "opsd/platform_renderer"

class PlatformRendererTest < Minitest::Test
  def test_renders_enabled_chart_from_locked_archive_with_manifest_values
    Dir.mktmpdir("opsd-platform-renderer-test-") do |root|
      workspace = Pathname(root)
      module_dir = workspace.join("modules", "kubernetes", "modules", "infrastructure", "external-dns")
      module_dir.mkpath
      chart_archive = workspace.join(".opsd", "cache", "helm", "#{Digest::SHA256.hexdigest('chart')}.tgz")
      chart_archive.dirname.mkpath
      chart_archive.write("chart")
      File.write(module_dir.join("module.yaml"), module_metadata(chart_archive))
      File.write(module_dir.join("defaults.yaml"), "provider:\n  webhook:\n    env: []\n")
      File.write(module_dir.join("schema.yaml"), "type: object\n")

      fake_bin = workspace.join("bin")
      fake_bin.mkpath
      helm = fake_bin.join("helm")
      helm.write(<<~'RUBY')
        #!/usr/bin/env ruby
        require "yaml"
        if ARGV.first == "template"
          values_path = ARGV[ARGV.index("--values") + 1]
          values = YAML.safe_load(File.read(values_path))
          puts "apiVersion: v1"
          puts "kind: ConfigMap"
          puts "metadata:\n  name: rendered"
          puts "data:\n  owner: #{values.fetch('txtOwnerId')}"
        end
      RUBY
      helm.chmod(0o755)
      env = ENV.to_h.merge("PATH" => "#{fake_bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}")
      rendered = workspace.join("rendered")
      lock = {
        "helm_charts" => [{ "module" => "external-dns", "digest" => "sha256:#{Digest::SHA256.hexdigest('chart')}" }]
      }

      OPSd::PlatformRenderer.new(workspace_root: workspace, env:, stdout: StringIO.new).render(
        manifest: FakeManifest.new,
        rendered_dir: rendered,
        module_lock: lock
      )

      output = rendered.join("platform", "helm", "external-dns.yaml").read
      assert_includes output, "owner: ci-owner"
    end
  end

  private

  def module_metadata(chart_archive)
    <<~YAML
      apiVersion: opsd.io/modules/v1alpha1
      kind: KubernetesModule
      metadata:
        id: external-dns
        name: ExternalDNS
        description: External DNS Helm module fixture
      spec:
        layer: infrastructure
        source:
          type: helm
          repository: https://example.test/charts
          chart: external-dns
          version: 1.2.3
          digest: sha256:#{Digest::SHA256.file(chart_archive).hexdigest}
        defaults: defaults.yaml
        schema: schema.yaml
        ownership:
          type: official
          repository: opsd-io/modules-kubernetes
        supported_providers: [digitalocean]
        validation:
          mode: strict
    YAML
  end

  class FakeManifest
    def gitops_repository
      nil
    end

    def kubernetes_component_enabled?(layer:, component:)
      layer == "infrastructure" && component == "external-dns"
    end

    def kubernetes_external_secrets_enabled?
      false
    end

    def kubernetes_gateway_profile_enabled?(profile:)
      false
    end

    def kubernetes_gateway_values
      { "public" => {}, "private" => {} }
    end

    def kubernetes_external_dns_values
      { "domain_filters" => ["example.test"], "txt_owner_id" => "ci-owner" }
    end
  end
end
