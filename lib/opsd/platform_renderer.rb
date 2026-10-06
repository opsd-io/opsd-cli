# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

require_relative "kubernetes_module"

module OPSd
  class PlatformRenderer
    def initialize(workspace_root:, env: ENV, stdout: $stdout)
      @workspace_root = Pathname(workspace_root).expand_path
      @env = env
      @stdout = stdout
    end

    def render(manifest:, rendered_dir:, module_lock:)
      rendered = Pathname(rendered_dir)
      chart_pins = Array(module_lock["helm_charts"]).to_h { |chart| [chart.fetch("module"), chart] }
      modules_root = @workspace_root.join("modules", "kubernetes")
      enabled_chart_ids(manifest).each do |module_id|
        pin = chart_pins[module_id]
        raise "No Helm chart pin found for Kubernetes module #{module_id}" unless pin

        module_path = modules_root.glob("modules/**/module.yaml").find do |path|
          YAML.load_file(path).dig("metadata", "id") == module_id
        end
        raise "Synchronized Kubernetes module not found: #{module_id}" unless module_path

        metadata = KubernetesModule.load(module_path)
        metadata.validate!
        module_dir = module_path.dirname
        spec = metadata.data.fetch("spec")
        chart_archive = @workspace_root.join(".opsd", "cache", "helm", "#{pin.fetch('digest').delete_prefix('sha256:')}.tgz")
        verify_chart!(pin, chart_archive)

        values = YAML.load_file(module_dir.join(spec.fetch("defaults"))) || {}
        values = deep_merge(values, component_values(manifest, module_id))
        values_dir = Pathname(Dir.mktmpdir("opsd-helm-values-"))
        values_path = values_dir.join("values.yaml")
        values_path.write(YAML.dump(values))
        begin
          run!("helm", "lint", chart_archive.to_s, "--values", values_path.to_s, "--namespace", helm_namespace(module_id))
          stdout, stderr, status = Open3.capture3(@env, "helm", "template", helm_release(module_id), chart_archive.to_s,
                                                  "--namespace", helm_namespace(module_id), "--values", values_path.to_s, "--include-crds")
          raise command_error("helm template #{module_id}", stdout, stderr) unless status.success?

          output_dir = rendered.join("platform", "helm")
          output_dir.mkpath
          output_dir.join("#{module_id}.yaml").write(stdout)
        ensure
          FileUtils.rm_rf(values_dir)
        end
      end
      true
    end

    private

    def enabled_chart_ids(manifest)
      ids = []
      ids << "argocd" if manifest.gitops_repository
      ids << "external-dns" if manifest.kubernetes_component_enabled?(layer: "infrastructure", component: "external-dns")
      ids << "external-secrets" if manifest.kubernetes_external_secrets_enabled?
      tls_enabled = %w[public private].any? do |profile|
        manifest.kubernetes_gateway_profile_enabled?(profile:) && !manifest.kubernetes_gateway_values.dig(profile, "hostname").to_s.empty?
      end
      ids << "cert-manager" if tls_enabled
      ids
    end

    def component_values(manifest, module_id)
      case module_id
      when "external-dns"
        source_values = manifest.kubernetes_external_dns_values
        domains = source_values.fetch("domain_filters")
        {
          "domainFilters" => domains,
          "policy" => source_values.fetch("policy", "upsert-only"),
          "txtOwnerId" => source_values.fetch("txt_owner_id"),
          "provider" => {
            "webhook" => {
              "env" => [
                { "name" => "DO_TOKEN", "valueFrom" => { "secretKeyRef" => { "name" => source_values.fetch("token_secret_name", "digitalocean-dns"), "key" => "access-token" } } },
                { "name" => "DO_DOMAIN_FILTER", "value" => domains.join(",") }
              ]
            }
          }
        }
      else
        manifest.kubernetes_component_values(layer: "infrastructure", component: module_id)
      end
    end

    def verify_chart!(pin, path)
      raise "Cached Helm chart is missing for #{pin.fetch('module')}; run `opsd modules sync` first." unless path.file?

      actual = "sha256:#{Digest::SHA256.file(path).hexdigest}"
      raise "Cached Helm chart digest mismatch for #{pin.fetch('module')}: expected #{pin.fetch('digest')}, got #{actual}." unless actual == pin.fetch("digest")
    end

    def helm_namespace(module_id)
      { "argocd" => "argocd", "cert-manager" => "cert-manager", "external-dns" => "external-dns", "external-secrets" => "external-secrets" }.fetch(module_id)
    end

    def helm_release(module_id)
      { "argocd" => "argocd", "cert-manager" => "cert-manager", "external-dns" => "external-dns", "external-secrets" => "external-secrets" }.fetch(module_id)
    end

    def deep_merge(left, right)
      left.merge(right) do |_key, existing, replacement|
        existing.is_a?(Hash) && replacement.is_a?(Hash) ? deep_merge(existing, replacement) : replacement
      end
    end

    def run!(*command, chdir: nil)
      options = {}
      options[:chdir] = chdir.to_s if chdir
      stdout, stderr, status = Open3.capture3(@env, *command, **options)
      raise command_error(command.join(" "), stdout, stderr) unless status.success?

      @stdout.print(stdout) unless stdout.empty?
    end

    def command_error(command, stdout, stderr)
      output = [stderr, stdout].reject(&:empty?).join("\n").strip
      "#{command} failed#{output.empty? ? '' : ": #{output}"}"
    end
  end
end
