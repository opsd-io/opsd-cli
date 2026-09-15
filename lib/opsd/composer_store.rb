# frozen_string_literal: true

require "pathname"
require "yaml"

module OPSd
  class ComposerStore
    def initialize(app_root:)
      @app_root = Pathname(app_root)
    end

    def stack(provider:, id:)
      path = @app_root.join("composer/#{provider}/stacks/#{id}.yaml")
      return nil unless path.file?

      data = YAML.load_file(path)
      return nil unless data.is_a?(Hash)

      data.merge("_path" => path.to_s)
    rescue Psych::SyntaxError
      nil
    end

    def scenario_for_stack(provider:, id:)
      definition = stack(provider: provider, id: id)
      definition && definition.dig("maps_to", "scenario")
    end
  end
end
