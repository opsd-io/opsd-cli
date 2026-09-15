# frozen_string_literal: true

require "pathname"
require "yaml"

module OPSd
  class ProviderCatalogStore
    def initialize(workspace_root:)
      @workspace_root = Pathname(workspace_root)
    end

    def profile_catalog(provider)
      data = provider_metadata(provider)
      profiles = data["profiles"]
      return profiles if profiles.is_a?(Hash)

      raise "Provider metadata for #{provider} does not define a valid profiles catalog in #{provider_metadata_path(provider)}"
    end

    def addons_catalog(provider)
      data = provider_metadata(provider)
      addons = data["addons"]
      return addons if addons.is_a?(Hash)

      raise "Provider metadata for #{provider} does not define a valid addons catalog in #{provider_metadata_path(provider)}"
    end

    private

    def provider_metadata(provider)
      metadata_path = provider_metadata_path(provider)
      raise "Provider metadata not found for #{provider}: #{metadata_path}" if metadata_path.nil?

      data = YAML.load_file(metadata_path)
      return data if data.is_a?(Hash)

      raise "Provider metadata for #{provider} is not a valid mapping: #{metadata_path}"
    rescue Psych::SyntaxError
      raise "Provider metadata for #{provider} contains invalid YAML: #{metadata_path}"
    end

    def provider_metadata_path(provider)
      metadata_path_for(provider) || cached_metadata_path_for(provider)
    end

    def metadata_path_for(provider)
      path = @workspace_root.join("modules", provider.to_s, "opsd.yaml")
      return path if path.file?

      nil
    end

    def cached_metadata_path_for(provider)
      releases_root = @workspace_root.join(".opsd", "cache", "releases", provider.to_s)
      return nil unless releases_root.directory?

      preferred = releases_root.join("main", "modules", provider.to_s, "opsd.yaml")
      return preferred if preferred.file?

      releases_root.children.select(&:directory?).sort_by(&:basename).each do |version_root|
        path = version_root.join("modules", provider.to_s, "opsd.yaml")
        return path if path.file?
      end

      nil
    end
  end
end
