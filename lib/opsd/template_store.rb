# frozen_string_literal: true

require "pathname"
require "json"
require "yaml"

module OPSd
  class TemplateStore
    FAMILIES = %w[kubernetes].freeze
    DEFAULT_PROVIDER = "digitalocean"

    FAMILY_DESCRIPTIONS = {
      "kubernetes" => "Managed Kubernetes cluster baseline"
    }.freeze

    FAMILY_TEMPLATE_PATHS = {
      "kubernetes" => "examples/kubernetes-environment.yaml"
    }.freeze

    FAMILY_DEFAULTS = {
      "kubernetes" => {
        "kind" => "cluster-service",
        "topology" => "cluster",
        "profile" => "s-2vcpu-4gb",
        "role" => "cluster"
      }
    }.freeze

    def initialize(app_root:, workspace_root:, contract_store: nil)
      @app_root = Pathname(app_root)
      @workspace_root = Pathname(workspace_root)
      @contract_store = contract_store
    end

    def providers
      discovered = provider_roots.keys | cached_provider_roots.keys
      active = contract_active_provider_names
      active.empty? ? discovered.sort : (discovered & active).sort
    end

    def families(provider: DEFAULT_PROVIDER)
      return [] unless provider_supported?(provider)

      FAMILIES
    end

    def family_descriptions(provider: DEFAULT_PROVIDER)
      return {} unless provider_supported?(provider)

      FAMILY_DESCRIPTIONS
    end

    def provider_supported?(provider)
      discovered = provider_roots.key?(provider) || cached_provider_roots.key?(provider)
      return false unless discovered

      active = contract_active_provider_names
      return true if active.empty?

      active.include?(provider.to_s)
    end

    def family_template(family, provider: DEFAULT_PROVIDER)
      return nil unless provider_supported?(provider)

      template_path = FAMILY_TEMPLATE_PATHS[family]
      return nil unless template_path

      @app_root.join(template_path).read
    end

    def blueprint_entries(provider: DEFAULT_PROVIDER)
      root = product_blueprint_root(provider: provider)
      return [] unless root&.directory?

      root.children
          .select(&:file?)
          .select { |path| path.extname == ".yaml" }
          .sort_by(&:basename)
          .filter_map { |path| load_product_blueprint(path, provider) }
    end

    def blueprint_ids(provider: DEFAULT_PROVIDER)
      blueprint_entries(provider: provider).map { |entry| entry[:id] }
    end

    def blueprint(provider: DEFAULT_PROVIDER, id:)
      blueprint_entries(provider: provider).find { |entry| entry[:id] == id }
    end

    def product_blueprint_root(provider: DEFAULT_PROVIDER)
      return nil unless provider_supported?(provider)

      path = @workspace_root.join("modules", provider.to_s, "blueprints")
      return path if path.directory?

      cached = cached_blueprint_root(provider)
      return cached if cached

      nil
    end

    def render_family_template(family, overrides = {}, provider: DEFAULT_PROVIDER)
      return nil if family_template(family, provider: provider).nil?

      defaults = FAMILY_DEFAULTS.fetch(family)
      values = defaults.merge(overrides.transform_keys(&:to_s))
      values["provider"] ||= provider.to_s
      values["environment"] ||= "development"
      values["region"] ||= "fra1"
      values["name"] ||= default_name(family, values["environment"])

      YAML.dump(build_family_template_manifest(family, values))
    end

    private

    def default_name(family, environment)
      "example-#{family}-#{environment}"
    end

    def load_product_blueprint(path, provider)
      data = YAML.load_file(path)
      return nil unless data.is_a?(Hash)

      {
        id: data["id"] || path.basename(".yaml").to_s,
        title: data["title"] || humanize_blueprint_id(path.basename(".yaml").to_s),
        description: data["description"] || "",
        usecases: Array(data["usecases"]),
        audiences: Array(data["audiences"]),
        provider: data["provider"] || provider,
        variants: Array(data["variants"]),
        path: path
      }
    rescue Psych::SyntaxError
      nil
    end

    def load_blueprint_entry(path, provider)
      metadata_path = path.join("scenario.json")
      description = humanize_blueprint_id(path.basename.to_s)
      id = path.basename.to_s

      if metadata_path.file?
        metadata = JSON.parse(metadata_path.read)
        id = metadata["id"] || id
        description = metadata["description"] || description
      end

      {
        id: id,
        description: description,
        provider: provider,
        path: path
      }
    rescue JSON::ParserError
      {
        id: path.basename.to_s,
        description: humanize_blueprint_id(path.basename.to_s),
        provider: provider,
        path: path
      }
    end

    def provider_roots
      @provider_roots ||= discover_provider_roots
    end

    def cached_provider_roots
      @cached_provider_roots ||= discover_cached_provider_roots
    end

    def discover_provider_roots
      modules_root = @workspace_root.join("modules")
      return {} unless modules_root.directory?

      modules_root.children.select(&:directory?).each_with_object({}) do |provider_path, memo|
        provider = provider_path.basename.to_s
        blueprint_root = provider_path.join("blueprints") if provider_path.join("blueprints").directory?
        memo[provider] = blueprint_root if blueprint_root
      end
    end

    def discover_cached_provider_roots
      releases_root = @workspace_root.join(".opsd", "cache", "releases")
      return {} unless releases_root.directory?

      releases_root.children.select(&:directory?).each_with_object({}) do |provider_path, memo|
        provider = provider_path.basename.to_s
        cached = cached_blueprint_root(provider)
        memo[provider] = cached if cached
      end
    end

    def cached_blueprint_root(provider)
      releases_root = @workspace_root.join(".opsd", "cache", "releases", provider)
      return nil unless releases_root.directory?

      preferred = releases_root.join("main", "modules", provider, "blueprints")
      return preferred if preferred.directory?

      candidates = releases_root.children.select(&:directory?).sort_by(&:basename)
      candidates.each do |version_root|
        blueprint_root = version_root.join("modules", provider, "blueprints")
        return blueprint_root if blueprint_root.directory?
      end

      nil
    end

    def humanize_blueprint_id(id)
      id.split("-").map(&:capitalize).join(" ")
    end

    def contract_active_provider_names
      return [] unless @contract_store

      @contract_store.active_provider_names
    end

    def build_family_template_manifest(family, values)
      manifest = {
        "apiVersion" => "opsd.io/v2alpha1",
        "kind" => "Environment",
        "metadata" => {
          "name" => values.fetch("name"),
          "environment" => values.fetch("environment"),
          "region" => values.fetch("region"),
          "tags" => [values.fetch("environment"), "managed-by-opsd", family],
          "labels" => {
            "environment" => values.fetch("environment"),
            "managed_by" => "opsd",
            "runtime" => family,
            "role" => values.fetch("role")
          }
        },
        "spec" => {
          "provider" => values.fetch("provider"),
          "origin" => {
            "blueprint" => nil,
            "variant" => nil,
            "family" => family,
            "stack" => nil,
            "modules" => {
              "repo" => nil,
              "version" => nil,
              "commit" => nil
            }
          },
          "defaults" => {
            "project" => values.fetch("name"),
            "network" => "shared",
            "dns_zone" => values["dns_domain"]
          }.compact,
          "compute_groups" => [],
          "nodes" => [],
          "databases" => [],
          "caches" => [],
          "load_balancers" => [],
          "object_storage" => [],
          "cdn_endpoints" => [],
          "layers" => default_layers_for(family),
          "policies" => {
            "drift_detection" => "strict",
            "managed_output" => true
          }
        }
      }

      case family
      when "droplet"
        manifest["spec"]["compute_groups"] << build_droplet_compute_group(values)
        manifest["spec"]["databases"] << build_database(values) if values["database_enabled"]
        manifest["spec"]["caches"] << build_cache(values) if values["cache_enabled"]
      when "kubernetes"
        manifest["spec"]["compute_groups"] << build_kubernetes_compute_group(values)
      when "spaces"
        manifest["spec"]["object_storage"] << build_object_storage(values)
        manifest["spec"]["cdn_endpoints"] << build_cdn_endpoint(values) if values.fetch("public", true)
      end

      manifest
    end

    def default_layers_for(family)
      return {} unless family == "kubernetes"

      {
        "core" => { "enabled" => true },
        "bootstrap" => { "argocd" => { "enabled" => true } },
        "observability" => { "enabled" => false },
        "tools" => { "enabled" => false },
        "apps" => { "enabled" => false }
      }
    end

    def build_droplet_compute_group(values)
      public = values.fetch("public", true)
      {
        "id" => "primary",
        "type" => "vm",
        "role" => values.fetch("role"),
        "replicas" => 1,
        "profile" => values.fetch("profile"),
        "image" => "ubuntu-24-04",
        "links" => service_links(values),
        "network" => {
          "vpc" => "shared",
          "firewall" => "public"
        },
        "exposure" => {
          "public" => public,
          "ports" => public ? default_public_ingress_ports(values) : [],
          "dns" => dns_mapping(values, default_record: "app")
        },
        "security" => {
          "egress" => {
            "preset" => public ? "web" : "open"
          }
        },
        "delivery" => {
          "mode" => values.fetch("delivery_mode", "bootstrap"),
          "source" => delivery_source(values, fallback_mode: "external"),
          "bootstrap" => {
            "cloud_init_user" => "opsd",
            "ssh_keys" => ["your-ssh-key-id"]
          },
          "env" => {},
          "secret_env" => {}
        }
      }
    end

    def build_kubernetes_compute_group(values)
      {
        "id" => "primary",
        "type" => "cluster",
        "role" => values.fetch("role"),
        "replicas" => 1,
        "profile" => values.fetch("profile"),
        "delivery" => {
          "mode" => values.fetch("delivery_mode", "gitops"),
          "source" => delivery_source(values, fallback_mode: "github"),
          "bootstrap" => {},
          "env" => {},
          "secret_env" => {}
        }
      }
    end

    def build_database(values)
      {
        "id" => "db-main",
        "engine" => values.fetch("database_engine", "postgres"),
        "profile" => values.fetch("database_profile", "db-s-1vcpu-1gb")
      }
    end

    def build_cache(values)
      {
        "id" => "cache-main",
        "engine" => "valkey",
        "profile" => values.fetch("cache_profile", "db-s-1vcpu-1gb")
      }
    end

    def default_public_ingress_ports(values)
      explicit_ports = values["public_ports"]
      return Array(explicit_ports).filter_map { |port| port.is_a?(Integer) ? port : port.to_i } if explicit_ports

      case values.fetch("role")
      when "bastion"
        [22]
      else
        [80, 443]
      end
    end

    def build_object_storage(values)
      {
        "id" => "assets-main",
        "profile" => values.fetch("profile"),
        "visibility" => values.fetch("public", true) ? "public" : "private"
      }
    end

    def build_cdn_endpoint(values)
      {
        "id" => "cdn-public",
        "origin" => "assets-main",
        "visibility" => "public",
        "dns" => dns_mapping(values, default_record: "assets")
      }
    end

    def service_links(values)
      [].tap do |links|
        links << "db-main" if values["database_enabled"]
        links << "cache-main" if values["cache_enabled"]
      end
    end

    def dns_mapping(values, default_record:)
      {
        "enabled" => values.fetch("dns_enabled", true),
        "domain" => values["dns_domain"],
        "record" => values["dns_record"] || default_record,
        "manage_zone" => values.fetch("dns_manage_zone", true)
      }.compact
    end

    def delivery_source(values, fallback_mode:)
      mode = values.fetch("source_mode", fallback_mode)
      source = { "mode" => mode }

      if mode == "image"
        source["image"] = {
          "registry" => values.fetch("image_registry", "dockerhub"),
          "repository" => values.fetch("image_repository", "nginx"),
          "tag" => values.fetch("image_tag", "latest")
        }
      elsif mode == "github"
        source["github"] = {
          "repository" => values.fetch("github_repository", "acme/repo"),
          "branch" => values.fetch("github_branch", "main")
        }
      elsif mode == "gitlab"
        source["gitlab"] = {
          "repository" => values.fetch("gitlab_repository", "acme/repo"),
          "branch" => values.fetch("gitlab_branch", "main")
        }
      end

      source
    end
  end
end
