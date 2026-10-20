# frozen_string_literal: true

require "json"
require "pathname"

require_relative "mcp_prompt_catalog"
require_relative "mcp_resource_catalog"
require_relative "mcp_tool_catalog"
require_relative "mcp_tool_executor"
require_relative "version"

module OPSd
  class McpServer
    PROTOCOL_VERSION = "2026-07-28"
    PATH_ARGUMENTS = %w[manifest_path plan_path snapshot_path rendered_dir output_dir output_path].freeze
    CACHEABLE_METHODS = %w[
      server/discover resources/list resources/templates/list resources/read prompts/list tools/list
    ].freeze

    def initialize(app_root:, workspace_root:, input: $stdin, output: $stdout, error: $stderr)
      @app_root = Pathname(app_root).expand_path
      @workspace_root = Pathname(workspace_root).expand_path
      @input = input
      @output = output
      @error = error
      @resources = McpResourceCatalog.new(app_root: @app_root, workspace_root: @workspace_root)
      @prompts = McpPromptCatalog.new(app_root: @app_root, workspace_root: @workspace_root)
      @tools = McpToolCatalog.new(app_root: @app_root, workspace_root: @workspace_root)
      @executor = McpToolExecutor.new(app_root: @app_root, workspace_root: @workspace_root)
    end

    def run
      @output.sync = true if @output.respond_to?(:sync=)
      @input.binmode if @input.respond_to?(:binmode)
      @output.binmode if @output.respond_to?(:binmode)

      loop do
        line = @input.gets("\n")
        break if line.nil?

        begin
          line = line.force_encoding(Encoding::UTF_8)
          raise JSON::ParserError, "Invalid UTF-8" unless line.valid_encoding?

          handle_message(JSON.parse(line))
        rescue JSON::ParserError
          write_error(nil, jsonrpc_error(-32700, "Parse error"))
        end
      end
    end

    private

    def handle_message(message)
      id = nil
      notification = false
      validate_request(message)
      id = message["id"]
      notification = !message.key?("id")
      method = message.fetch("method")
      params = message.fetch("params", {})
      require_object(params, "params")

      return if notification

      if method == "initialize"
        raise jsonrpc_error(
          -32601,
          "initialize is not supported; use MCP #{PROTOCOL_VERSION} with per-request metadata",
          { "supported" => [PROTOCOL_VERSION] }
        )
      end
      validate_request_metadata(params)

      result =
        case method
        when "server/discover"
          discovery_payload
        when "resources/list"
          { "resources" => @resources.resources }
        when "resources/templates/list"
          { "resourceTemplates" => [] }
        when "resources/read"
          handle_resources_read(params)
        when "prompts/list"
          { "prompts" => @prompts.prompts.map { |prompt| prompt_payload(prompt) } }
        when "prompts/get"
          handle_prompts_get(params)
        when "tools/list"
          { "tools" => @tools.tools.map { |tool| tool_payload(tool) } }
        when "tools/call"
          handle_tools_call(params)
        else
          raise jsonrpc_error(-32601, "Method not found: #{method}")
        end

      write_result(id, method, result)
    rescue JsonRpcError => e
      if notification
        @error.puts("MCP notification rejected: #{e.message}")
      else
        write_error(id, e)
      end
    rescue StandardError => e
      @error.puts("MCP internal error: #{e.class}: #{e.message}")
      write_error(id, jsonrpc_error(-32603, "Internal error")) unless notification
    end

    def validate_request(message)
      valid = message.is_a?(Hash) && message["jsonrpc"] == "2.0" && message["method"].is_a?(String)
      if valid && message.key?("id")
        valid = message["id"].is_a?(String) || message["id"].is_a?(Integer)
      end
      raise jsonrpc_error(-32600, "Invalid request") unless valid
    end

    def validate_request_metadata(params)
      meta = require_object(require_parameter(params, "_meta"), "_meta")
      requested_version = require_string(meta, "io.modelcontextprotocol/protocolVersion")
      require_object(
        require_parameter(meta, "io.modelcontextprotocol/clientCapabilities"),
        "io.modelcontextprotocol/clientCapabilities"
      )
      unless requested_version == PROTOCOL_VERSION
        raise jsonrpc_error(
          -32022,
          "Unsupported protocol version",
          { "supported" => [PROTOCOL_VERSION], "requested" => requested_version }
        )
      end

      if meta.key?("io.modelcontextprotocol/clientInfo")
        client_info = require_object(meta.fetch("io.modelcontextprotocol/clientInfo"), "io.modelcontextprotocol/clientInfo")
        require_string(client_info, "name")
        require_string(client_info, "version")
      end
    end

    def discovery_payload
      {
        "supportedVersions" => [PROTOCOL_VERSION],
        "capabilities" => {
          "prompts" => { "listChanged" => false },
          "resources" => { "subscribe" => false, "listChanged" => false },
          "tools" => { "listChanged" => false }
        },
        "instructions" => "Use per-request MCP metadata over stdio to discover resources, prompts, and tools."
      }
    end

    def server_info
      {
        "name" => "opsd",
        "title" => "OPSd MCP Server",
        "version" => OPSd::VERSION,
        "description" => "OPSd stdio transport for resources, prompts, and tools"
      }
    end

    def handle_resources_read(params)
      uri = require_string(params, "uri")
      unless @resources.resources.any? { |resource| resource.fetch("uri") == uri }
        raise jsonrpc_error(-32602, "Resource not found: #{uri}")
      end
      {
        "contents" => [
          {
            "uri" => uri,
            "mimeType" => "application/json",
            "text" => @resources.read(uri)
          }
        ]
      }
    end

    def handle_prompts_get(params)
      name = require_string(params, "name")
      arguments = require_object(params.fetch("arguments", {}), "arguments")
      prompt = @prompts.prompt(name)
      raise jsonrpc_error(-32602, "Unsupported MCP prompt: #{name}") if prompt.nil?

      validate_arguments(prompt.arguments, arguments, prompt: true)

      {
        "description" => prompt.description,
        "messages" => [
          {
            "role" => "user",
            "content" => {
              "type" => "text",
              "text" => @prompts.render(name, arguments)
            }
          }
        ]
      }
    end

    def handle_tools_call(params)
      name = require_string(params, "name")
      arguments = require_object(params.fetch("arguments", {}), "arguments")
      tool = @tools.tool(name)
      raise jsonrpc_error(-32602, "Unsupported MCP tool: #{name}") if tool.nil?

      validate_arguments(tool.arguments, arguments)
      confirmed = arguments["confirmed"] == true
      if tool.requires_confirmation && !confirmed
        message = "Tool #{name} requires explicit confirmation: the host must obtain user approval " \
                  "for this operation and set arguments.confirmed to true"
        return { "content" => [{ "type" => "text", "text" => message }], "isError" => true }
      end

      # Resolve path arguments before CLI parsing so names such as --help remain literal files.
      arguments = arguments.dup
      tool.arguments.each do |argument|
        key = argument.fetch("name")
        next unless PATH_ARGUMENTS.include?(key) && arguments.key?(key)

        arguments[key] = Pathname(arguments.fetch(key)).expand_path(@workspace_root).to_s
      end
      argv = @tools.dispatch(name, arguments, confirmed: confirmed)
      @executor.call(argv)
    end

    def prompt_payload(prompt)
      {
        "name" => prompt.name,
        "description" => prompt.description,
        "arguments" => prompt.arguments
      }
    end

    def tool_payload(tool)
      {
        "name" => tool.fetch("name"),
        "description" => tool.fetch("description"),
        "annotations" => {
          "readOnlyHint" => tool.fetch("effect") == "read-only",
          "destructiveHint" => tool.fetch("effect") != "read-only",
          "openWorldHint" => false
        },
        "_meta" => {
          "io.opsd/effect" => tool.fetch("effect"),
          "io.opsd/requiresConfirmation" => tool.fetch("requires_confirmation")
        },
        "inputSchema" => {
          "type" => "object",
          "properties" => tool.fetch("arguments").each_with_object({}) do |argument, properties|
            properties[argument.fetch("name")] = schema_for_argument(argument)
          end,
          "required" => tool.fetch("arguments").select { |argument| argument.fetch("required") }.map { |argument| argument.fetch("name") },
          "additionalProperties" => true
        }
      }
    end

    def require_object(value, name)
      raise jsonrpc_error(-32602, "#{name} must be an object") unless value.is_a?(Hash)

      value
    end

    def require_parameter(params, name)
      params.fetch(name) { raise jsonrpc_error(-32602, "Missing required parameter: #{name}") }
    end

    def require_string(params, name)
      value = require_parameter(params, name)
      unless value.is_a?(String) && !value.empty?
        raise jsonrpc_error(-32602, "#{name} must be a non-empty string")
      end

      value
    end

    def validate_arguments(definitions, arguments, prompt: false)
      definitions.each do |argument|
        name = argument.fetch("name")
        if argument.fetch("required") && !arguments.key?(name)
          raise jsonrpc_error(-32602, "Missing required argument: #{name}")
        end
        next unless arguments.key?(name)

        type = prompt ? "string" : argument_type(name)
        value = arguments.fetch(name)
        valid = case type
                when "integer" then value.is_a?(Integer)
                when "boolean" then value == true || value == false
                else value.is_a?(String)
                end
        raise jsonrpc_error(-32602, "#{name} must be a #{type}") unless valid
      end
    end

    def write_result(id, method, payload)
      result = payload.merge(
        "resultType" => "complete",
        "_meta" => { "io.modelcontextprotocol/serverInfo" => server_info }
      )
      if CACHEABLE_METHODS.include?(method)
        # Workspace content can change between calls; do not encourage caching or sharing it.
        result.merge!("ttlMs" => 0, "cacheScope" => "private")
      end
      write_json("jsonrpc" => "2.0", "id" => id, "result" => result)
    end

    def write_error(id, error)
      write_json({
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => { "code" => error.code, "message" => error.message, "data" => error.data }.compact
      }.compact)
    end

    def write_json(payload)
      @output.write(JSON.generate(payload) + "\n")
      @output.flush if @output.respond_to?(:flush)
    end

    def schema_for_argument(argument)
      {
        "type" => argument_type(argument.fetch("name")),
        "description" => argument.fetch("description")
      }
    end

    def argument_type(name)
      case name
      when "replicas"
        "integer"
      when "confirmed"
        "boolean"
      else
        "string"
      end
    end

    def jsonrpc_error(code, message, data = nil)
      JsonRpcError.new(code: code, message: message, data: data)
    end

    class JsonRpcError < StandardError
      attr_reader :code, :data

      def initialize(code:, message:, data: nil)
        super(message)
        @code = code
        @data = data
      end
    end
  end
end
