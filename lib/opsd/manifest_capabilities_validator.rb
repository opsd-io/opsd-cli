# frozen_string_literal: true

module OPSd
  class ManifestCapabilitiesValidator
    SECTION_KEYS = %w[compute_groups nodes databases caches load_balancers object_storage cdn_endpoints].freeze

    def initialize(template_store:, provider:)
      @template_store = template_store
      @provider = provider
    end

    def validate!(manifest)
      blueprint = @template_store.blueprint(provider: @provider, id: manifest.composer_blueprint)
      return if blueprint.nil?

      variant = Array(blueprint[:variants]).find { |entry| entry.fetch("id") == manifest.composer_variant }
      return if variant.nil?

      capabilities = variant["capabilities"]
      return unless capabilities.is_a?(Hash)

      errors = []
      errors.concat(validate_immutable_origin(manifest, variant, capabilities))
      errors.concat(validate_sections(manifest, variant, capabilities))

      raise OPSd::Manifest::ValidationError.new(errors) unless errors.empty?
    end

    private

    def validate_immutable_origin(manifest, variant, capabilities)
      immutable = capabilities["immutable"]
      return [] unless immutable.is_a?(Hash)

      errors = []
      errors << immutable_origin_error("family", variant.fetch("family")) if immutable["family"] == true && manifest.family != variant.fetch("family")
      errors << immutable_origin_error("stack", variant.fetch("stack")) if immutable["stack"] == true && manifest.composer_stack != variant.fetch("stack")
      errors
    end

    def validate_sections(manifest, variant, capabilities)
      editable = capabilities["editable"]
      return [] unless editable.is_a?(Hash)

      SECTION_KEYS.flat_map do |section_key|
        section_rules = editable[section_key]
        next [] unless section_rules.is_a?(Hash)

        validate_section(
          section_key,
          current_entries: Array(manifest.spec[section_key]),
          baseline_entries: Array(variant.fetch("manifest", {})[section_key]),
          rules: section_rules
        )
      end
    end

    def validate_section(section_key, current_entries:, baseline_entries:, rules:)
      errors = []

      errors.concat(validate_section_counts(section_key, current_entries, baseline_entries, rules))
      errors.concat(validate_section_entries(section_key, current_entries, rules))

      if section_key == "compute_groups" && rules["scale"] == false
        errors.concat(validate_compute_group_scaling(current_entries, baseline_entries))
      end

      errors
    end

    def validate_section_counts(section_key, current_entries, baseline_entries, rules)
      errors = []
      current_count = current_entries.length
      baseline_count = baseline_entries.length

      if current_count > baseline_count && rules["add"] == false
        errors << "capability violation: blueprint variant does not support adding entries to #{section_key}"
      end

      if current_count < baseline_count && rules["remove"] == false
        errors << "capability violation: blueprint variant does not support removing entries from #{section_key}"
      end

      if rules["min_count"].is_a?(Integer) && current_count < rules["min_count"]
        errors << "capability violation: #{section_key} requires at least #{rules['min_count']} entries"
      end

      if rules["max_count"].is_a?(Integer) && current_count > rules["max_count"]
        errors << "capability violation: #{section_key} supports at most #{rules['max_count']} entries"
      end

      errors
    end

    def validate_section_entries(section_key, current_entries, rules)
      current_entries.each_with_index.flat_map do |entry, index|
        next [] unless entry.is_a?(Hash)

        prefix = "#{section_key}[#{index}]"
        errors = []
        errors << invalid_value_error(prefix, "type", entry["type"], rules["allowed_types"]) if rules["allowed_types"].is_a?(Array) && !blank?(entry["type"]) && !rules["allowed_types"].include?(entry["type"])
        errors << invalid_value_error(prefix, "role", entry["role"], rules["allowed_roles"]) if rules["allowed_roles"].is_a?(Array) && !blank?(entry["role"]) && !rules["allowed_roles"].include?(entry["role"])
        errors << invalid_value_error(prefix, "engine", entry["engine"], rules["allowed_engines"]) if rules["allowed_engines"].is_a?(Array) && !blank?(entry["engine"]) && !rules["allowed_engines"].include?(entry["engine"])
        errors << invalid_value_error(prefix, "profile", entry["profile"], rules["allowed_profiles"]) if rules["allowed_profiles"].is_a?(Array) && !blank?(entry["profile"]) && !rules["allowed_profiles"].include?(entry["profile"])
        errors
      end
    end

    def validate_compute_group_scaling(current_entries, baseline_entries)
      baseline_by_id = baseline_entries.each_with_object({}) do |entry, memo|
        next unless entry.is_a?(Hash) && !blank?(entry["id"])

        memo[entry["id"]] = entry
      end

      current_entries.flat_map do |entry|
        next [] unless entry.is_a?(Hash) && !blank?(entry["id"])

        baseline = baseline_by_id[entry["id"]]
        next [] if baseline.nil?

        next [] if entry["replicas"] == baseline["replicas"]

        ["capability violation: blueprint variant does not support changing replicas for compute_groups"]
      end
    end

    def immutable_origin_error(field, expected)
      "capability violation: spec.origin.#{field} is immutable for in-place evolution and must remain #{expected}"
    end

    def invalid_value_error(prefix, field, value, allowed)
      "capability violation: #{prefix}.#{field}=#{value} is not supported by this blueprint variant. Allowed values: #{allowed.join(', ')}"
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end
