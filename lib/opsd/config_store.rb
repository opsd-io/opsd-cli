# frozen_string_literal: true

require "pathname"
require "yaml"

module OPSd
  class ConfigStore
    SUPPORTED_PROVIDERS = %w[digitalocean aws azure gcp].freeze

    def initialize(workspace_root:, supported_providers: SUPPORTED_PROVIDERS)
      raise "workspace_root is required" if workspace_root.nil? || workspace_root.to_s.empty?

      @config_dir = Pathname(workspace_root).expand_path.join(".opsd")
      @config_path = @config_dir.join("config")
      @supported_providers = Array(supported_providers).map(&:to_s)
    end

    def profile_names
      profiles.keys.sort
    end

    def profile(profile_name)
      profiles[profile_name.to_s]
    end

    def profile_value(profile_name, key)
      profile(profile_name)&.[](key.to_s)
    end

    def current_profile_name
      value = values["current_profile"]
      value.to_s.strip.empty? ? nil : value.to_s
    end

    def set_current_profile(profile_name)
      profile_name = normalize_profile_name(profile_name)
      raise "Profile not found: #{profile_name}" if profile(profile_name).nil?

      persisted = values
      persisted["current_profile"] = profile_name
      write_values(persisted)
    end

    def unset_current_profile
      persisted = values
      persisted.delete("current_profile")
      write_values(persisted)
    end

    def ensure_profile(profile_name)
      profile_name = normalize_profile_name(profile_name)
      persisted = values
      persisted["profiles"] ||= {}
      persisted["profiles"][profile_name] ||= {}
      write_values(persisted)
      profile(profile_name)
    end

    def set_profile_value(profile_name, key, value)
      profile_name = normalize_profile_name(profile_name)
      key = key.to_s
      validate_profile_value!(key, value)

      persisted = values
      persisted["profiles"] ||= {}
      persisted["profiles"][profile_name] ||= {}
      persisted["profiles"][profile_name][key] = value
      write_values(persisted)
    end

    def unset_profile_value(profile_name, key)
      profile_name = normalize_profile_name(profile_name)
      key = key.to_s

      persisted = values
      profiles = persisted["profiles"] || {}
      profile_data = profiles[profile_name]
      return unless profile_data.is_a?(Hash)

      profile_data.delete(key)
      profiles.delete(profile_name) if profile_data.empty?
      persisted["profiles"] = profiles
      persisted.delete("current_profile") if persisted["current_profile"] == profile_name && profile_data.empty?
      write_values(persisted)
    end

    def delete_profile(profile_name)
      profile_name = normalize_profile_name(profile_name)

      persisted = values
      profiles = persisted["profiles"] || {}
      profiles.delete(profile_name)
      persisted["profiles"] = profiles
      persisted.delete("current_profile") if persisted["current_profile"] == profile_name
      write_values(persisted)
    end

    def path
      @config_path
    end

    private

    def values
      return {} unless @config_path.file?

      data = YAML.load_file(@config_path)
      return {} if data.nil?
      return data if data.is_a?(Hash)

      parse_legacy_values(@config_path.read)

    rescue Psych::SyntaxError => e
      raise "YAML syntax error in #{@config_path}: #{e.message}"
    end

    def write_values(persisted)
      @config_dir.mkpath
      @config_path.write(YAML.dump(sorted_hash(persisted)))
    end

    def profiles
      raw_profiles = values.fetch("profiles", {})
      return {} unless raw_profiles.is_a?(Hash)

      raw_profiles.transform_keys(&:to_s)
    end

    def sorted_hash(hash)
      hash.each_with_object({}) do |(key, value), memo|
        memo[key] =
          case value
          when Hash
            sorted_hash(value)
          else
            value
          end
      end.sort_by { |key, _value| key.to_s }.to_h
    end

    def normalize_profile_name(profile_name)
      profile_name = profile_name.to_s.strip
      raise "Profile name is required" if profile_name.empty?

      profile_name
    end

    def validate_profile_value!(key, value)
      return unless key == "provider"

      unless @supported_providers.include?(value)
        raise "Unsupported provider: #{value}. Allowed values: #{@supported_providers.join(', ')}"
      end
    end

    def parse_legacy_values(text)
      text.to_s.lines.each_with_object({}) do |line, memo|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        key, value = stripped.split("=", 2).map { |part| part&.strip }
        next if key.nil? || key.empty? || value.nil?

        memo[key] = value
      end
    end
  end
end
