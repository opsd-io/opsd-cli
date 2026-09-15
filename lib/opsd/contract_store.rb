# frozen_string_literal: true

require "pathname"
require "yaml"

module OPSd
  class ContractStore
    class ContractError < StandardError
      attr_reader :errors

      def initialize(errors)
        super("OPSd contract is invalid")
        @errors = errors
      end
    end

    def initialize(app_root:)
      @app_root = Pathname(app_root)
    end

    def contract_path
      @app_root.join("docs/contract.yaml")
    end

    def contract
      @contract ||= load_contract
    end

    def contract_version
      contract.fetch("contract_version")
    end

    def manifest_contract
      contract.fetch("manifest")
    end

    def provider_models
      models = manifest_contract["provider_models"]
      models.is_a?(Hash) ? models : {}
    end

    def provider_model(provider)
      provider_models[provider.to_s]
    end

    def provider_names
      provider_models.keys.sort
    end

    def provider_status(provider)
      model = provider_model(provider)
      return nil unless model.is_a?(Hash)

      (model["status"] || "reference").to_s
    end

    def active_provider_names
      provider_names.select { |provider| provider_status(provider) != "placeholder" }
    end

    def placeholder_provider_names
      provider_names.select { |provider| provider_status(provider) == "placeholder" }
    end

    def supported_paths
      provider_models.values.flat_map do |model|
        next [] unless model.is_a?(Hash)

        Array(model["supported_paths"])
      end
    end

    def supported_paths_for(provider)
      model = provider_model(provider)
      return [] unless model.is_a?(Hash)

      Array(model["supported_paths"])
    end

    def supported_path_ids(provider = nil)
      paths = provider.nil? ? supported_paths : supported_paths_for(provider)
      paths.filter_map { |entry| entry["id"] if entry.is_a?(Hash) }
    end

    def rule_packs
      packs = contract["rule_packs"]
      packs.is_a?(Hash) ? packs : {}
    end

    def rule_pack(name)
      rule_packs[name.to_s]
    end

    def lifecycle
      data = contract["lifecycle"]
      data.is_a?(Hash) ? data : {}
    end

    def lifecycle_provider_modules
      section = lifecycle["provider_modules"]
      section.is_a?(Hash) ? section : {}
    end

    def lifecycle_provider_module(provider)
      lifecycle_provider_modules[provider.to_s]
    end

    def lifecycle_opentofu
      section = lifecycle["opentofu"]
      section.is_a?(Hash) ? section : {}
    end

    def lifecycle_managed_policies
      section = lifecycle["managed_policies"]
      section.is_a?(Hash) ? section : {}
    end

    private

    def load_contract
      raise ContractError.new(["contract file not found: #{contract_path}"]) unless contract_path.file?

      data = YAML.load_file(contract_path)
      errors = validate_contract(data)
      raise ContractError.new(errors) unless errors.empty?

      data
    rescue Psych::SyntaxError => e
      raise ContractError.new(["YAML syntax error in #{contract_path}: #{e.message}"])
    end

    def validate_contract(data)
      errors = []

      unless data.is_a?(Hash)
        return ["contract root must be a YAML mapping"]
      end

      errors << "contract_version is required" if blank?(data["contract_version"])
      errors << "name is required" if blank?(data["name"])
      errors << "api_version is required" if blank?(data["api_version"])
      errors << "kind is required" if blank?(data["kind"])
      errors << "manifest is required" unless data["manifest"].is_a?(Hash)
      errors << "rule_packs must be a mapping" unless data["rule_packs"].is_a?(Hash)

      if data["manifest"].is_a?(Hash)
        manifest = data["manifest"]
        errors << "manifest.required_top_level_keys must be an array" unless manifest["required_top_level_keys"].is_a?(Array)
        errors << "manifest.metadata must be a mapping" unless manifest["metadata"].is_a?(Hash)
        errors << "manifest.provider_models must be a mapping" unless manifest["provider_models"].is_a?(Hash)
      end

      if data.key?("lifecycle")
        errors << "lifecycle must be a mapping" unless data["lifecycle"].is_a?(Hash)
      end

      if data["manifest"].is_a?(Hash) && data["manifest"]["provider_models"].is_a?(Hash)
        data["manifest"]["provider_models"].each do |provider, model|
          next if model.is_a?(Hash)

          errors << "manifest.provider_models.#{provider} must be a mapping"
        end
      end

      if data["rule_packs"].is_a?(Hash)
        data["rule_packs"].each do |name, pack|
          next if pack.is_a?(Hash)

          errors << "rule_packs.#{name} must be a mapping"
        end
      end

      if data["lifecycle"].is_a?(Hash)
        data["lifecycle"].each do |section_name, section|
          next if section.is_a?(Hash)

          errors << "lifecycle.#{section_name} must be a mapping"
        end
      end

      errors
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end
