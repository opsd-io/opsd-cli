# frozen_string_literal: true

require "json"
require "pathname"

require_relative "mcp_prompt_catalog"
require_relative "mcp_resource_catalog"
require_relative "mcp_tool_catalog"
require_relative "version"

module OPSd
  class McpServer
    PROTOCOL_VERSION = "2025-11-25"

    def initialize(app_root:, workspace_root:, input: $stdin, output: $stdout, error: $stderr)
      @app_root = Pathname(app_root).expand_path
      @workspace_root = Pathname(workspace_root).expand_path
      @input = input
      @output = output
      @error = error
      @resources = McpResourceCatalog.new(app_root: @app_root, workspace_root: @workspace_root)
      @prompts = McpPromptCatalog.new(app_root: @app_root, workspace_root: @workspace_root)
      @tools = McpToolCatalog.new(app_root: @app_root, workspace_root: @workspace_root)
      @initialized = false
    end

    def run
      @output.sync = true if @output.respond_to?(:sync=)
      @input.binmode if @input.respond_to?(:binmode)
      @output.binmode if @output.respond_to?(:binmode)

      loop do
        message = read_message
        break if message.nil?

        handle_message(message)
        break if @stop
      end
    end

    private

    def handle_message(message)
      raise jsonrpc_error(-32600, "Invalid request") unless message.is_a?(Hash)

      method = message["method"].to_s
      id = message["id"]

      if id.nil?
        handle_notification(method, message["params"] || {})
        return
      end

      result =
        case method
        when "initialize"
          handle_initialize(message["params"] || {})
        when "resources/list"
          { "resources" => @resources.resources }
        when "resources/read"
          handle_resources_read(message["params"] || {})
        when "prompts/list"
          { "prompts" => @prompts.prompts.map { |prompt| prompt_payload(prompt) } }
        when "prompts/get"
          handle_prompts_get(message["params"] || {})
        when "tools/list"
          { "tools" => @tools.tools.map { |tool| tool_payload(tool) } }
        when "tools/call"
          handle_tools_call(message["params"] || {})
        when "ping"
          {}
        when "shutdown"
          @initialized = false
          {}
        else
          raise jsonrpc_error(-32601, "Method not found: #{method}")
        end

      write_json(
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => result
      )
    rescue JsonRpcError => e
      write_json(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => {
          "code" => e.code,
          "message" => e.message,
          "data" => e.data
        }.compact
      )
    rescue StandardError => e
      write_json(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => {
          "code" => -32603,
          "message" => e.message
        }
      )
    end

    def handle_notification(method, _params)
      case method
      when "notifications/initialized"
        @initialized = true
      when "exit"
        @stop = true
      end
    end

    def handle_initialize(params)
      requested_version = params["protocolVersion"].to_s
      {
        "protocolVersion" => negotiated_protocol_version(requested_version),
        "capabilities" => {
          "prompts" => { "listChanged" => false },
          "resources" => { "subscribe" => false, "listChanged" => false },
          "tools" => { "listChanged" => false }
        },
        "serverInfo" => {
          "name" => "opsd",
          "title" => "OPSd MCP Server",
          "version" => OPSd::VERSION,
          "description" => "OPSd stdio transport for resources, prompts, and tools"
        },
        "instructions" => "Connect over stdio, then use resources/list, prompts/list, and tools/list."
      }
    end

    def handle_resources_read(params)
      uri = params.fetch("uri")
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
      name = params.fetch("name")
      arguments = params["arguments"] || {}
      prompt = @prompts.prompt(name)
      raise jsonrpc_error(-32602, "Unsupported MCP prompt: #{name}") if prompt.nil?

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
      name = params.fetch("name")
      arguments = params["arguments"] || {}
      confirmed = truthy?(arguments["confirmed"] || arguments[:confirmed] || params["confirmed"] || params[:confirmed])

      argv = @tools.dispatch(name, stringify_keys(arguments), confirmed: confirmed)
      {
        "content" => [
          {
            "type" => "text",
            "text" => argv.join(" ")
          }
        ],
        "isError" => false
      }
    rescue RuntimeError => e
      if e.message.include?("requires explicit confirmation")
        {
          "content" => [
            {
              "type" => "text",
              "text" => e.message
            }
          ],
          "isError" => true
        }
      else
        raise
      end
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

    def write_json(payload)
      json = JSON.generate(payload)
      @output.write("Content-Length: #{json.bytesize}\r\n\r\n")
      @output.write(json)
      @output.flush if @output.respond_to?(:flush)
    end

    def read_message
      headers = {}

      loop do
        line = @input.gets("\n")
        return nil if line.nil? && headers.empty?
        raise EOFError if line.nil?

        line = line.delete_prefix("\r").chomp
        break if line.empty?

        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip if key && value
      end

      length = headers.fetch("content-length").to_i
      body = @input.read(length)
      return nil if body.nil?

      JSON.parse(body)
    end

    def negotiated_protocol_version(requested_version)
      requested_version == PROTOCOL_VERSION ? requested_version : PROTOCOL_VERSION
    end

    def stringify_keys(hash)
      hash.each_with_object({}) do |(key, value), memo|
        memo[key.to_s] = value
      end
    end

    def truthy?(value)
      value == true || value.to_s == "true"
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
