# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "pathname"
require "open-uri"
require "tmpdir"
require "yaml"

require_relative "modules_synchronizer"
require_relative "platform_renderer"
require_relative "renderer"

module OPSd
  class PlatformValidator
    IAC_TOOLS = %w[terraform tofu].freeze

    def initialize(workspace_root:, app_root:, env: ENV, stdout: $stdout)
      @workspace_root = Pathname(workspace_root).expand_path
      @app_root = Pathname(app_root).expand_path
      @env = env
      @stdout = stdout
    end

    def validate(manifest:, manifest_path:, module_resolution:, module_lock:, offline: false)
      modules_synchronizer.verify(manifest_path:)
      Dir.mktmpdir("opsd-platform-validation-") do |temporary|
        rendered = Pathname(temporary).join("rendered")
        Renderer.new(app_root: @app_root, workspace_root: module_resolution.fetch(:workspace_root)).render(
          manifest,
          rendered,
          module_lock:,
          module_source: module_resolution
        )
        validate_iac(rendered, offline:)
        PlatformRenderer.new(workspace_root: @workspace_root, env: @env, stdout: @stdout).render(
          manifest:, rendered_dir: rendered, module_lock:
        )
        generate_custom_resource_schemas(rendered)
        validate_kubernetes(rendered, manifest, offline:)
      end
      true
    end

    private

    def modules_synchronizer
      @modules_synchronizer ||= ModulesSynchronizer.new(workspace_root: @workspace_root, env: @env)
    end

    def validate_iac(rendered, offline:)
      missing = IAC_TOOLS.filter_map do |tool|
        mirror, lockfile = provider_cache(tool)
        tool unless provider_mirror_ready?(mirror, lockfile)
      end
      if offline && !missing.empty?
        raise "Offline validation cache is missing for #{missing.join(' and ')} providers; run `opsd validate manifest <manifest.yaml> --platform` once with network access."
      end

      IAC_TOOLS.each do |tool|
        directory = "-chdir=#{rendered}"
        run!(tool, directory, "fmt", "-recursive")
        run!(tool, directory, "fmt", "-check", "-recursive")
        mirror, lockfile = provider_cache(tool)
        cache_ready = provider_mirror_ready?(mirror, lockfile)
        if cache_ready
          FileUtils.cp(lockfile, rendered.join(".terraform.lock.hcl"))
          run!(tool, directory, "init", "-backend=false", "-input=false", "-no-color", "-lockfile=readonly", "-plugin-dir=#{mirror}")
        else
          run!(tool, directory, "init", "-backend=false", "-input=false", "-no-color")
          mirror.dirname.mkpath
          run!(tool, directory, "providers", "mirror", mirror.to_s)
          lockfile.dirname.mkpath
          FileUtils.cp(rendered.join(".terraform.lock.hcl"), lockfile)
        end
        run!(tool, directory, "validate", "-no-color")
      end
    end

    def provider_cache(tool)
      root = @workspace_root.join(".opsd", "cache", "iac", tool)
      [root.join("providers"), root.join(".terraform.lock.hcl")]
    end

    def provider_mirror_ready?(mirror, lockfile)
      mirror.directory? && mirror.glob("**/*.zip").any? && lockfile.file?
    end

    def validate_kubernetes(rendered, manifest, offline:)
      files = rendered.glob("layers/**/*.yaml") + rendered.glob("platform/**/*.yaml")
      return if files.empty?

      custom_schema_root = @workspace_root.join(".opsd", "cache", "kubeconform", "crds")
      version = manifest.primary_kubernetes_config.fetch("kubernetes_version", "1.33.0-do.0").to_s.delete_prefix("v").sub(/-do\.\d+\z/, "")
      schema_root = builtin_schema_root(version)
      ensure_builtin_schemas(files, schema_root, version, offline:)
      run!("kubeconform", "-strict", "-ignore-missing-schemas", "-summary", "-kubernetes-version", version,
           "-schema-location", "file://#{schema_root}/{{.ResourceKind}}{{.KindSuffix}}.json",
           "-schema-location", "file://#{custom_schema_root}/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json",
           *files.map(&:to_s))
    end

    BUILTIN_API_GROUPS = %w[
      admissionregistration.k8s.io apiextensions.k8s.io apps authentication.k8s.io authorization.k8s.io
      autoscaling batch certificates.k8s.io coordination.k8s.io discovery.k8s.io events.k8s.io
      flowcontrol.apiserver.k8s.io networking.k8s.io node.k8s.io policy rbac.authorization.k8s.io
      scheduling.k8s.io storage.k8s.io resource.k8s.io
    ].freeze

    def builtin_schema_root(version)
      @workspace_root.join(".opsd", "cache", "kubeconform", "builtin", "v#{version}-standalone-strict")
    end

    def ensure_builtin_schemas(files, schema_root, version, offline:)
      files.each do |file|
        YAML.load_stream(file.read).compact.each do |resource|
          next unless resource.is_a?(Hash) && resource["kind"] && resource["apiVersion"]
          next if resource["kind"] == "CustomResourceDefinition"

          api_version = resource.fetch("apiVersion")
          group = api_version.include?("/") ? api_version.split("/", 2).first : nil
          custom_schema = @workspace_root.join(".opsd", "cache", "kubeconform", "crds", "#{resource.fetch('kind')}-#{group}-#{api_version.split('/').last}.json") if group
          next if custom_schema&.file?

          builtin = group.nil? || BUILTIN_API_GROUPS.include?(group)
          schema_path = schema_root.join(builtin_schema_filename(resource))
          next if schema_path.file?

          if !builtin
            raise "Offline validation schema is missing for #{file} (#{api_version} #{resource.fetch('kind')}); include its CRD in the enabled Helm charts or run validation online." if offline

            next
          end
          if offline
            raise "Offline Kubernetes schema cache is missing for #{file} (#{api_version} #{resource.fetch('kind')}); run `opsd validate manifest <manifest.yaml> --platform` once with network access."
          end

          schema_path.dirname.mkpath
          url = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v#{version}-standalone-strict/#{schema_path.basename}"
          begin
            schema_path.write(URI.open(url, read_timeout: 10, open_timeout: 10, &:read))
          rescue OpenURI::HTTPError => error
            raise "Unable to cache Kubernetes schema for #{file} (#{api_version} #{resource.fetch('kind')}): #{error.message}" if builtin
          rescue StandardError => error
            raise "Unable to cache Kubernetes schema for #{file} (#{api_version} #{resource.fetch('kind')}): #{error.message}"
          end
        end
      end
    end

    def builtin_schema_filename(resource)
      kind = resource.fetch("kind").downcase
      group_version = resource.fetch("apiVersion").split("/", 2)
      suffix = if group_version.length == 1
                 group_version.first
               else
                 "#{group_version.first.split('.').first}-#{group_version.last}"
               end
      "#{kind}-#{suffix}.json"
    end

    def generate_custom_resource_schemas(rendered)
      schema_root = @workspace_root.join(".opsd", "cache", "kubeconform", "crds")
      chart_files = rendered.glob("platform/helm/*.yaml")
      FileUtils.rm_rf(schema_root)
      return if chart_files.empty?
      chart_files.each do |file|
        YAML.load_stream(file.read).compact.each do |resource|
          next unless resource.is_a?(Hash) && resource["kind"] == "CustomResourceDefinition"

          spec = resource.fetch("spec")
          group = spec.fetch("group")
          kind = spec.dig("names", "kind")
          Array(spec["versions"]).select { |version| version["served"] }.each do |version|
            api_version = version.fetch("name")
            schema = version.dig("schema", "openAPIV3Schema")
            next unless kind && schema.is_a?(Hash)

            properties = schema.fetch("properties", {}).merge(
              "apiVersion" => { "type" => "string", "enum" => ["#{group}/#{api_version}"] },
              "kind" => { "type" => "string", "enum" => [kind] },
              "metadata" => { "type" => "object", "properties" => { "name" => { "type" => "string" }, "namespace" => { "type" => "string" } }, "required" => ["name"] }
            )
            required = (Array(schema["required"]) + %w[apiVersion kind metadata]).uniq
            custom_schema = schema.merge(
              "$schema" => "http://json-schema.org/draft-07/schema#",
              "properties" => properties,
              "required" => required
            )
            filename = "#{kind}-#{group}-#{api_version}.json"
            schema_root.mkpath
            schema_root.join(filename).write(JSON.pretty_generate(custom_schema))
          end
        end
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
