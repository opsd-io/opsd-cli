# frozen_string_literal: true

module OPSd
  class RenderProviderCatalog
    Provider = Struct.new(:name, :template_namespace, :module_namespace, keyword_init: true)

    def initialize(provider_names: %w[digitalocean])
      @provider_names = Array(provider_names).map(&:to_s)
    end

    def supported_provider_names
      @provider_names.dup
    end

    def provider(name)
      provider_name = name.to_s
      return nil unless supported_provider_names.include?(provider_name)

      Provider.new(
        name: provider_name,
        template_namespace: provider_name,
        module_namespace: provider_name
      )
    end
  end
end
