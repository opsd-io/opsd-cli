# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

require_relative "contract_store"
require_relative "template_store"

module OPSd
  class McpResourceCatalog
    def initialize(app_root:, workspace_root:, contract_store: nil, template_store: nil)
      @app_root = Pathname(app_root).expand_path
      @workspace_root = Pathname(workspace_root).expand_path
      @contract_store = contract_store || ContractStore.new(app_root: @app_root)
      @template_store = template_store || TemplateStore.new(
        app_root: @app_root,
        workspace_root: @workspace_root,
        contract_store: @contract_store
      )
    end

    def resources
      base_resources + provider_resources + static_resources
    end

    def read(uri)
      case uri.to_s
      when "opsd://contract"
        serialize(contract_payload)
      when "opsd://rule-packs"
        serialize(rule_packs_payload)
      when %r{\Aopsd://catalog/blueprints/([^/]+)\z}
        serialize(blueprint_catalog_payload(Regexp.last_match(1)))
      when %r{\Aopsd://catalog/supported-paths/([^/]+)\z}
        serialize(supported_paths_payload(Regexp.last_match(1)))
      when "opsd://examples"
        serialize(example_manifests_payload)
      when "opsd://docs/pointers"
        serialize(docs_pointers_payload)
      else
        raise "Unsupported MCP resource: #{uri}"
      end
    end

    private

    def base_resources
      [
        resource(
          "opsd://contract",
          "OPSd Contract",
          "Machine-readable manifest contract, lifecycle rules, and provider models"
        ),
        resource(
          "opsd://rule-packs",
          "OPSd Rule Packs",
          "Machine-readable security, reliability, cost, maintainability, upgradeability, and reversibility rules"
        )
      ]
    end

    def provider_resources
      provider_names.flat_map do |provider|
        [
          resource(
            "opsd://catalog/blueprints/#{provider}",
            "Blueprint Catalog: #{provider}",
            "Blueprint metadata and variants for #{provider}"
          ),
          resource(
            "opsd://catalog/supported-paths/#{provider}",
            "Supported Paths: #{provider}",
            "Supported provider paths and their reference stack metadata for #{provider}"
          )
        ]
      end
    end

    def static_resources
      [
        resource(
          "opsd://examples",
          "Example Manifests",
          "Supported example manifests and their recorded blueprint provenance"
        ),
        resource(
          "opsd://docs/pointers",
          "Documentation Pointers",
          "Stable documentation entrypoints for OPSd concepts"
        )
      ]
    end

    def resource(uri, name, description)
      {
        "uri" => uri,
        "name" => name,
        "description" => description,
        "mimeType" => "application/json"
      }
    end

    def serialize(payload)
      JSON.pretty_generate(payload)
    end

    def contract_payload
      contract = @contract_store.contract
      {
        "contract_version" => @contract_store.contract_version,
        "name" => contract["name"],
        "api_version" => contract["api_version"],
        "kind" => contract["kind"],
        "manifest" => deep_clone(contract["manifest"]),
        "lifecycle" => deep_clone(contract["lifecycle"]),
        "rule_packs" => deep_clone(contract["rule_packs"]),
        "source" => {
          "path" => relative_path(@contract_store.contract_path)
        }
      }
    end

    def rule_packs_payload
      {
        "contract_version" => @contract_store.contract_version,
        "rule_packs" => deep_clone(@contract_store.rule_packs)
      }
    end

    def blueprint_catalog_payload(provider)
      blueprints = @template_store.blueprint_entries(provider: provider)
      {
        "provider" => provider,
        "blueprints" => blueprints.map { |blueprint| blueprint_payload(blueprint) }
      }
    end

    def supported_paths_payload(provider)
      supported_paths = @contract_store.supported_paths_for(provider)
      {
        "provider" => provider,
        "status" => @contract_store.provider_status(provider),
        "supported_paths" => deep_clone(supported_paths)
      }
    end

    def example_manifests_payload
      example_paths.map do |path|
        data = YAML.load_file(path)
        next nil unless data.is_a?(Hash)

        {
          "id" => data.dig("metadata", "name") || path.basename(".yaml").to_s,
          "path" => relative_path(path),
          "description" => example_description(data, path),
          "provider" => data.dig("spec", "provider"),
          "blueprint" => data.dig("spec", "origin", "blueprint"),
          "variant" => data.dig("spec", "origin", "variant"),
          "family" => data.dig("spec", "origin", "family"),
          "stack" => data.dig("spec", "origin", "stack")
        }
      end.compact.then do |examples|
        {
          "examples" => examples
        }
      end
    end

    def docs_pointers_payload
      {
        "docs" => [
          {
            "id" => "manifest",
            "title" => "Manifest Contract",
            "path" => "docs/manifest.md",
            "description" => "Canonical v2 manifest contract and lifecycle"
          },
          {
            "id" => "commands",
            "title" => "Command Reference",
            "path" => "docs/reference/commands.md",
            "description" => "Supported CLI workflow and mutation commands"
          },
          {
            "id" => "packaging",
            "title" => "Release Packaging",
            "path" => "docs/release/packaging.md",
            "description" => "Release bundle, asdf plugin, and exit-pack packaging guidance"
          },
          {
            "id" => "exit-pack",
            "title" => "Exit Pack",
            "path" => "docs/exit-pack.md",
            "description" => "Portable handoff archive exported from rendered output"
          },
          {
            "id" => "quickstart",
            "title" => "Quickstart",
            "path" => "docs/getting-started/quickstart.md",
            "description" => "Shortest supported path from install to rendered output"
          }
        ]
      }
    end

    def blueprint_payload(blueprint)
      {
        "id" => blueprint[:id],
        "title" => blueprint[:title],
        "description" => blueprint[:description],
        "usecases" => Array(blueprint[:usecases]),
        "audiences" => Array(blueprint[:audiences]),
        "provider" => blueprint[:provider],
        "variants" => Array(blueprint[:variants]).map { |variant| blueprint_variant_payload(variant) },
        "path" => relative_path(blueprint[:path])
      }
    end

    def blueprint_variant_payload(variant)
      {
        "id" => variant.fetch("id"),
        "title" => variant["title"],
        "description" => variant["description"],
        "components" => Array(variant["components"]),
        "scenarios" => Array(variant["scenarios"])
      }
    end

    def example_description(data, path)
      description = data.dig("metadata", "annotations", "description")
      return description if description.is_a?(String) && !description.empty?

      first_line = path.read.lines.find { |line| line.start_with?("#") }
      return first_line.delete_prefix("#").strip if first_line

      path.basename(".yaml").to_s
    end

    def provider_names
      names = @contract_store.active_provider_names
      names = @contract_store.provider_names if names.empty?
      names
    end

    def example_paths
      @workspace_root.join("examples").children
                     .select(&:file?)
                     .select { |path| %w[.yaml .yml].include?(path.extname) }
                     .sort_by(&:basename)
    end

    def relative_path(path)
      path = Pathname(path)
      return path.to_s unless path.absolute?

      [@app_root, @workspace_root].each do |base|
        next unless path.to_s.start_with?(base.to_s)

        return path.relative_path_from(base).to_s
      rescue ArgumentError
        next
      end

      path.to_s
    rescue ArgumentError
      path.to_s
    end

    def deep_clone(value)
      Marshal.load(Marshal.dump(value))
    rescue TypeError
      value
    end
  end
end
