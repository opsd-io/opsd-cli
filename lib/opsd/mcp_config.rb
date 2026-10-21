# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "rbconfig"

module OPSd
  class McpConfig
    def initialize(app_root:, workspace_root:)
      @app_root = Pathname(app_root).expand_path
      @workspace_root = Pathname(workspace_root).expand_path
    end

    def payload
      {
        "mcpServers" => {
          "opsd" => {
            "command" => @app_root.join("bin", "opsd-mcp").to_s,
            "env" => {
              "OPSD_APP_ROOT" => @app_root.to_s,
              "OPSD_WORKSPACE_ROOT" => @workspace_root.to_s,
              "RUBY_BIN" => ruby_bin
            }
          }
        }
      }
    end

    def to_json
      JSON.pretty_generate(payload)
    end

    # GUI hosts may not load shell initialization or rbenv/asdf shims.
    def ruby_bin
      bundled = @app_root.join("runtime", "bin", "ruby")
      return bundled.to_s if bundled.executable?

      Pathname(RbConfig.ruby).expand_path.to_s
    end
    private :ruby_bin

    def self.run(argv, app_root:, workspace_root:)
      options = parse_options(argv)
      generator = new(
        app_root: options.fetch(:app_root, app_root),
        workspace_root: options.fetch(:workspace_root, workspace_root)
      )

      puts generator.to_json
    end

    def self.parse_options(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: bin/opsd-mcp config [--app-root <path>] [--workspace-root <path>]"
        opts.on("--app-root PATH", "Override the OPSd app root used in the generated config") do |value|
          options[:app_root] = value
        end
        opts.on("--workspace-root PATH", "Override the OPSd workspace root used in the generated config") do |value|
          options[:workspace_root] = value
        end
        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end
      end

      parser.parse!(argv)
      options
    end
    private_class_method :parse_options
  end
end
