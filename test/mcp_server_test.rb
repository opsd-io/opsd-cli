# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "minitest/autorun"

class McpServerTest < Minitest::Test
  def test_stdio_server_supports_initialize_and_discovery
    Dir.mktmpdir("opsd-mcp-server") do |workspace|
      with_server(workspace) do |stdin, stdout|
        write_message(stdin, {
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => {
            "protocolVersion" => "2025-11-25",
            "capabilities" => {},
            "clientInfo" => {
              "name" => "opsd-test",
              "version" => "1.0.0"
            }
          }
        })

        initialize_response = read_message(stdout)
        assert_equal "2.0", initialize_response.fetch("jsonrpc")
        assert_equal 1, initialize_response.fetch("id")
        assert_equal "2025-11-25", initialize_response.fetch("result").fetch("protocolVersion")
        assert_equal false, initialize_response.fetch("result").fetch("capabilities").fetch("tools").fetch("listChanged")

        write_message(stdin, {
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

        write_message(stdin, {
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "resources/list",
          "params" => {}
        })
        resources_response = read_message(stdout)
        resource_uris = resources_response.fetch("result").fetch("resources").map { |resource| resource.fetch("uri") }
        assert_includes resource_uris, "opsd://contract"
        assert_includes resource_uris, "opsd://docs/pointers"

        write_message(stdin, {
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "prompts/list",
          "params" => {}
        })
        prompts_response = read_message(stdout)
        prompt_names = prompts_response.fetch("result").fetch("prompts").map { |prompt| prompt.fetch("name") }
        assert_includes prompt_names, "verify-config"
        assert_includes prompt_names, "export-exit-pack"

        write_message(stdin, {
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/list",
          "params" => {}
        })
        tools_response = read_message(stdout)
        tool_names = tools_response.fetch("result").fetch("tools").map { |tool| tool.fetch("name") }
        assert_includes tool_names, "verify-config"
        assert_includes tool_names, "export-exit-pack"

        write_message(stdin, {
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "resources/read",
          "params" => {
            "uri" => "opsd://contract"
          }
        })
        resource_response = read_message(stdout)
        contract_payload = JSON.parse(resource_response.fetch("result").fetch("contents").first.fetch("text"))
        assert_match(/OPSd/, contract_payload.fetch("name"))

        write_message(stdin, {
          "jsonrpc" => "2.0",
          "id" => 6,
          "method" => "tools/call",
          "params" => {
            "name" => "verify-config",
            "arguments" => {
              "manifest_path" => "demo.yaml"
            }
          }
        })
        call_response = read_message(stdout)
        assert_equal false, call_response.fetch("result").fetch("isError")
        assert_equal "verify config demo.yaml", call_response.fetch("result").fetch("content").first.fetch("text")

        write_message(stdin, {
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => {
            "name" => "remove-resource",
            "arguments" => {
              "resource" => "database",
              "manifest_path" => "demo.yaml",
              "resource_id" => "db-main"
            }
          }
        })
        gated_response = read_message(stdout)
        assert_equal true, gated_response.fetch("result").fetch("isError")
        assert_match(/requires explicit confirmation/, gated_response.fetch("result").fetch("content").first.fetch("text"))

        write_message(stdin, {
          "jsonrpc" => "2.0",
          "method" => "exit"
        })
      end
    end
  end

  private

  def with_server(workspace_root)
    app_root = File.expand_path("..", __dir__)
    env = {
      "OPSD_APP_ROOT" => app_root,
      "OPSD_WORKSPACE_ROOT" => workspace_root
    }

    Open3.popen3(env, File.expand_path("../bin/opsd-mcp", __dir__)) do |stdin, stdout, stderr, wait_thread|
      yield(stdin, stdout)

      stdin.close unless stdin.closed?
      wait_thread.value
    end
  end

  def write_message(io, payload)
    json = JSON.generate(payload)
    io.write("Content-Length: #{json.bytesize}\r\n\r\n")
    io.write(json)
    io.flush
  end

  def read_message(io)
    headers = {}

    loop do
      line = io.gets("\n")
      raise "Unexpected EOF while reading MCP header" if line.nil?

      line = line.delete_prefix("\r").chomp
      break if line.empty?

      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end

    body = io.read(headers.fetch("content-length").to_i)
    JSON.parse(body)
  end
end
