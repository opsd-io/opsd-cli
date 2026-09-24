# frozen_string_literal: true

require "pathname"
require "yaml"

require_relative "manifest"

module OPSd
  class KubernetesModule
    API_VERSION = "opsd.io/modules/v1alpha1"
    KIND = "KubernetesModule"
    SOURCE_TYPES = %w[helm oci git].freeze
    OWNERSHIP_TYPES = %w[official custom].freeze
    VALIDATION_MODES = %w[strict permissive].freeze

    class ValidationError < StandardError
      attr_reader :errors

      def initialize(errors)
        super("Kubernetes module metadata is invalid")
        @errors = errors
      end
    end

    attr_reader :data, :source_path

    def self.load(path)
      source_path = Pathname(path)
      new(YAML.load_file(source_path), source_path: source_path)
    rescue Psych::SyntaxError => e
      raise ValidationError, ["YAML syntax error in #{source_path}: #{e.message}"]
    end

    def initialize(data, source_path: nil)
      @data = data || {}
      @source_path = source_path
    end

    def validate!
      errors = []
      unless data.is_a?(Hash)
        raise ValidationError.new(["module metadata root must be a mapping"])
      end

      errors << "apiVersion must be #{API_VERSION}" unless data["apiVersion"] == API_VERSION
      errors << "kind must be #{KIND}" unless data["kind"] == KIND

      metadata = data["metadata"]
      spec = data["spec"]
      errors << "metadata must be a mapping" unless metadata.is_a?(Hash)
      errors << "spec must be a mapping" unless spec.is_a?(Hash)
      errors.concat(validate_metadata(metadata)) if metadata.is_a?(Hash)
      errors.concat(validate_spec(spec)) if spec.is_a?(Hash)

      raise ValidationError.new(errors) unless errors.empty?

      true
    end

    private

    def validate_metadata(metadata)
      errors = []
      %w[id name description].each do |key|
        errors << "metadata.#{key} is required" if blank?(metadata[key])
      end
      errors << "metadata.id must be a DNS-like identifier" unless metadata["id"].to_s.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      errors
    end

    def validate_spec(spec)
      errors = []
      layer = spec["layer"]
      allowed_layers = Manifest::KUBERNETES_LAYERS.map { |definition| definition["id"] }
      errors << "spec.layer is required" if blank?(layer)
      errors << "spec.layer must be one of: #{allowed_layers.join(', ')}" unless allowed_layers.include?(layer.to_s)

      source = spec["source"]
      errors << "spec.source must be a mapping" unless source.is_a?(Hash)
      errors.concat(validate_source(source)) if source.is_a?(Hash)

      ownership = spec["ownership"]
      errors << "spec.ownership must be a mapping" unless ownership.is_a?(Hash)
      errors.concat(validate_ownership(ownership)) if ownership.is_a?(Hash)

      providers = spec["supported_providers"]
      errors << "spec.supported_providers must be a non-empty array" unless providers.is_a?(Array) && !providers.empty?
      if providers.is_a?(Array)
        unknown = providers.map(&:to_s) - Manifest::SUPPORTED_PROVIDERS
        errors << "spec.supported_providers contains unknown providers: #{unknown.join(', ')}" unless unknown.empty?
      end

      errors << "spec.defaults must be a relative file path" unless relative_path?(spec["defaults"])
      errors << "spec.schema must be a relative file path" unless relative_path?(spec["schema"])

      validation = spec["validation"]
      errors << "spec.validation must be a mapping" unless validation.is_a?(Hash)
      errors.concat(validate_validation(validation, ownership)) if validation.is_a?(Hash) && ownership.is_a?(Hash)

      extensions = spec["provider_extensions"]
      errors << "spec.provider_extensions must be a mapping" if extensions && !extensions.is_a?(Hash)
      if extensions.is_a?(Hash)
        unknown = extensions.keys.map(&:to_s) - Manifest::SUPPORTED_PROVIDERS
        errors << "spec.provider_extensions contains unknown providers: #{unknown.join(', ')}" unless unknown.empty?
      end

      errors
    end

    def validate_source(source)
      errors = []
      type = source["type"]
      errors << "spec.source.type must be one of: #{SOURCE_TYPES.join(', ')}" unless SOURCE_TYPES.include?(type.to_s)

      required = case type.to_s
                 when "helm" then %w[repository chart]
                 when "oci" then %w[registry chart]
                 when "git" then %w[repository path]
                 else []
                 end
      required.each do |key|
        errors << "spec.source.#{key} is required for source type #{type}" if blank?(source[key])
      end
      errors
    end

    def validate_ownership(ownership)
      errors = []
      type = ownership["type"]
      errors << "spec.ownership.type must be one of: #{OWNERSHIP_TYPES.join(', ')}" unless OWNERSHIP_TYPES.include?(type.to_s)
      errors << "spec.ownership.repository is required" if blank?(ownership["repository"])
      errors
    end

    def validate_validation(validation, ownership)
      errors = []
      mode = validation["mode"]
      errors << "spec.validation.mode must be one of: #{VALIDATION_MODES.join(', ')}" unless VALIDATION_MODES.include?(mode.to_s)
      if ownership["type"] == "official" && mode != "strict"
        errors << "spec.validation.mode must be strict for official modules"
      end
      errors
    end

    def relative_path?(value)
      return false unless value.is_a?(String) && !value.empty?

      path = Pathname(value)
      !path.absolute? && !value.split("/").include?("..")
    end

    def blank?(value)
      value.nil? || value.respond_to?(:empty?) && value.empty?
    end
  end
end
