# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "timeout"
require "minitest/autorun"

class McpServerTest < Minitest::Test
  RESPONSE_TIMEOUT = 5

  def test_stdio_server_supports_discovery_and_catalogs
    with_server do |stdin, stdout|
      request(stdin, 1, "server/discover")
      response = read_message(stdout)
      assert_equal "2.0", response.fetch("jsonrpc")
      assert_equal 1, response.fetch("id")
      assert_equal ["2026-07-28"], response.fetch("result").fetch("supportedVersions")
      assert_cacheable(response.fetch("result"))
      assert_equal false, response.dig("result", "capabilities", "tools", "listChanged")

      request(stdin, 2, "resources/list")
      uris = read_message(stdout).fetch("result").fetch("resources").map { |resource| resource.fetch("uri") }
      assert_includes uris, "opsd://contract"
      assert_includes uris, "opsd://docs/pointers"

      request(stdin, 3, "prompts/list")
      prompts = read_message(stdout).fetch("result").fetch("prompts").map { |prompt| prompt.fetch("name") }
      assert_includes prompts, "verify-config"
      assert_includes prompts, "export-exit-pack"

      request(stdin, 4, "tools/list")
      tools = read_message(stdout).fetch("result").fetch("tools").map { |tool| tool.fetch("name") }
      assert_includes tools, "verify-config"
      assert_includes tools, "export-exit-pack"

      request(stdin, 5, "resources/read", { "uri" => "opsd://contract" })
      contract = JSON.parse(read_message(stdout).fetch("result").fetch("contents").first.fetch("text"))
      assert_match(/OPSd/, contract.fetch("name"))

      request(stdin, 6, "resources/templates/list")
      templates = read_message(stdout).fetch("result")
      assert_equal [], templates.fetch("resourceTemplates")
      assert_cacheable(templates)
    end
  end

  def test_discovery_is_optional_and_requests_do_not_establish_a_session
    with_server do |stdin, stdout|
      request(stdin, 1, "tools/list")
      assert read_message(stdout).fetch("result").key?("tools")

      write_message(stdin, { "jsonrpc" => "2.0", "id" => 2, "method" => "tools/list" })
      assert_error(read_message(stdout), -32602, id: 2)

      request(stdin, 3, "prompts/list")
      assert read_message(stdout).fetch("result").key?("prompts")
    end
  end

  def test_unsupported_version_is_rejected_on_each_request_without_changing_other_requests
    with_server do |stdin, stdout|
      ["2025-11-25", "2099-01-01"].each_with_index do |version, id|
        request(stdin, id, "server/discover", meta: request_metadata(version: version))
        response = read_message(stdout)
        assert_error(response, -32022, id: id)
        assert_equal ["2026-07-28"], response.dig("error", "data", "supported")
        assert_equal version, response.dig("error", "data", "requested")
      end
      request(stdin, 3, "tools/list")
      assert read_message(stdout).fetch("result").key?("tools")
      request(stdin, 4, "tools/list", meta: request_metadata(version: "2025-11-25"))
      assert_error(read_message(stdout), -32022, id: 4)
    end
  end

  def test_legacy_initialize_is_rejected_with_an_actionable_diagnostic
    with_server do |stdin, stdout|
      write_message(stdin, {
        "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
        "params" => { "protocolVersion" => "2025-11-25", "capabilities" => {},
                      "clientInfo" => { "name" => "legacy", "version" => "1" } }
      })
      response = read_message(stdout)
      assert_error(response, -32601, id: 1)
      assert_includes response.dig("error", "message"), "2026-07-28"
      assert_equal ["2026-07-28"], response.dig("error", "data", "supported")
      request(stdin, 2, "server/discover")
      assert read_message(stdout).fetch("result").key?("supportedVersions")
    end
  end

  def test_metadata_is_required_and_validated_on_each_request
    with_server do |stdin, stdout|
      metadata = request_metadata
      invalid = [
        nil, [], {},
        metadata.reject { |key, _| key == "io.modelcontextprotocol/protocolVersion" },
        metadata.merge("io.modelcontextprotocol/protocolVersion" => nil),
        metadata.reject { |key, _| key == "io.modelcontextprotocol/clientCapabilities" },
        metadata.merge("io.modelcontextprotocol/clientCapabilities" => []),
        metadata.merge("io.modelcontextprotocol/clientInfo" => "client"),
        metadata.merge("io.modelcontextprotocol/clientInfo" => { "name" => "client" })
      ]
      invalid.each_with_index do |meta, id|
        request(stdin, id, "server/discover", meta: meta)
        assert_error(read_message(stdout), -32602, id: id)
      end
      request(stdin, "valid", "server/discover")
      assert_equal ["2026-07-28"], read_message(stdout).dig("result", "supportedVersions")
    end
  end

  def test_client_identity_is_optional_and_capabilities_are_not_remembered
    with_server do |stdin, stdout|
      meta = request_metadata.reject { |key, _| key == "io.modelcontextprotocol/clientInfo" }
      request(stdin, 1, "tools/list", meta: meta)
      assert read_message(stdout).fetch("result").key?("tools")
      meta = request_metadata.reject { |key, _| key == "io.modelcontextprotocol/clientCapabilities" }
      request(stdin, 2, "tools/list", meta: meta)
      assert_error(read_message(stdout), -32602, id: 2)
    end
  end

  def test_cacheable_results_are_private_and_immediately_stale
    with_server do |stdin, stdout|
      %w[server/discover tools/list resources/list resources/templates/list prompts/list resources/read].each do |method|
        params = method == "resources/read" ? { "uri" => "opsd://contract" } : {}
        request(stdin, method, method, params)
        assert_cacheable(read_message(stdout).fetch("result"))
      end
    end
  end

  def test_parse_errors_do_not_terminate_the_session
    with_server do |stdin, stdout|
      ["{broken\n", "\n", "\xFF\n".b].each do |line|
        stdin.write(line)
        stdin.flush
        assert_error(read_message(stdout), -32700, id: nil)
      end
      request(stdin, 2, "tools/list")
      assert read_message(stdout).fetch("result").key?("tools")
    end
  end

  def test_invalid_request_envelopes_omit_id_and_allow_recovery
    with_server do |stdin, stdout|
      invalid_requests = [
        nil, [], "request", 42,
        { "jsonrpc" => "1.0", "id" => 1, "method" => "ping" },
        { "jsonrpc" => "2.0", "id" => 1 },
        { "jsonrpc" => "2.0", "id" => 1, "method" => 42 },
        { "jsonrpc" => "2.0", "id" => nil, "method" => "ping" },
        { "jsonrpc" => "2.0", "id" => true, "method" => "ping" },
        { "jsonrpc" => "2.0", "id" => {}, "method" => "ping" }
      ]
      invalid_requests.each do |message|
        write_message(stdin, message)
        assert_error(read_message(stdout), -32600, id: nil)
      end
      request(stdin, 1, "server/discover")
      assert read_message(stdout).key?("result")
    end
  end

  def test_invalid_parameters_return_invalid_params_instead_of_internal_errors
    with_server do |stdin, stdout|
      invalid_calls = [
        ["server/discover", []],
        ["tools/list", nil],
        ["resources/read", {}],
        ["resources/read", { "uri" => 42 }],
        ["prompts/get", { "name" => "unknown" }],
        ["prompts/get", { "name" => "verify-config", "arguments" => [] }],
        ["prompts/get", { "name" => "verify-config", "arguments" => {} }],
        ["prompts/get", { "name" => "verify-config", "arguments" => { "manifest_path" => 42 } }],
        ["tools/call", { "name" => "unknown" }],
        ["tools/call", { "name" => "verify-config", "arguments" => [] }],
        ["tools/call", { "name" => "verify-config", "arguments" => {} }],
        ["tools/call", { "name" => "verify-config", "arguments" => { "manifest_path" => 42 } }],
        ["tools/call", { "name" => "scale-compute-group", "arguments" => {
          "manifest_path" => "demo.yaml", "resource_id" => "web", "replicas" => "two"
        } }]
      ]
      invalid_calls.each_with_index do |(method, params), index|
        request(stdin, index, method, params)
        assert_error(read_message(stdout), -32602, id: index)
      end
      request(stdin, "still-ready", "tools/list")
      assert read_message(stdout).fetch("result").key?("tools")
    end
  end

  def test_confirmation_gate_is_preserved_over_standard_stdio
    with_server do |stdin, stdout|
      request(stdin, 2, "tools/call", { "name" => "remove-resource", "arguments" => {
        "resource" => "database", "manifest_path" => "demo.yaml", "resource_id" => "db-main"
      } })
      result = read_message(stdout).fetch("result")
      assert_equal true, result.fetch("isError")
      assert_match(/requires explicit confirmation/, result.fetch("content").first.fetch("text"))
    end
  end

  def test_partial_json_at_eof_reports_a_parse_error_and_exits_cleanly
    with_server do |stdin, stdout|
      stdin.write('{"jsonrpc":')
      stdin.close
      assert_error(read_message(stdout), -32700, id: nil)
    end
  end

  def test_unknown_resource_returns_resource_not_found
    with_server do |stdin, stdout|
      request(stdin, 2, "resources/read", { "uri" => "opsd://missing" })
      assert_error(read_message(stdout), -32602, id: 2)
    end
  end

  def test_notifications_never_produce_responses_or_enable_legacy_sessions
    with_server do |stdin, stdout|
      write_message(stdin, { "jsonrpc" => "2.0", "method" => "notifications/initialized" })
      write_message(stdin, { "jsonrpc" => "2.0", "method" => "notifications/unknown" })
      write_message(stdin, { "jsonrpc" => "2.0", "method" => "ping", "params" => [] })
      write_message(stdin, { "jsonrpc" => "2.0", "method" => "exit" })
      request(stdin, "after-notifications", "tools/list")
      response = read_message(stdout)
      assert_equal "after-notifications", response.fetch("id")
      assert response.fetch("result").key?("tools")
    end
  end

  def test_removed_and_unknown_methods_return_method_not_found
    with_server do |stdin, stdout|
      %w[missing ping shutdown exit].each do |method|
        request(stdin, method, method)
        assert_error(read_message(stdout), -32601, id: method)
      end
    end
  end

  def test_fragmented_input_and_multiple_messages_use_newline_boundaries
    with_server do |stdin, stdout|
      json = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "server/discover",
                             "params" => { "_meta" => request_metadata } })
      stdin.write(json[0, 20])
      stdin.flush
      stdin.write(json[20..] + "\n")
      stdin.flush
      assert read_message(stdout).key?("result")

      messages = [
        { "jsonrpc" => "2.0", "method" => "notifications/initialized" },
        { "jsonrpc" => "2.0", "id" => 2, "method" => "server/discover", "params" => { "_meta" => request_metadata } },
        { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => { "_meta" => request_metadata } }
      ]
      stdin.write(messages.map { |message| JSON.generate(message) + "\n" }.join)
      stdin.flush
      assert_equal 2, read_message(stdout).fetch("id")
      assert_equal 3, read_message(stdout).fetch("id")
    end
  end

  def test_utf8_and_embedded_newlines_are_escaped_within_one_response_line
    with_server do |stdin, stdout|
      path = "zażółć\nmanifest.yaml"
      request(stdin, "żółć", "prompts/get", { "name" => "verify-config", "arguments" => { "manifest_path" => path } })
      response = read_message(stdout)
      assert_equal "żółć", response.fetch("id")
      assert_includes response.fetch("result").fetch("messages").first.fetch("content").fetch("text"), path
      request(stdin, 3, "server/discover")
      assert_equal 3, read_message(stdout).fetch("id")
    end
  end

  def test_eof_before_any_request_is_clean
    with_server do |_stdin, _stdout|
      # The helper closes stdin and verifies successful process termination.
    end
  end

  private

  def with_server
    Dir.mktmpdir("opsd-mcp-server") do |workspace|
      env = {
        "RUBY_BIN" => RbConfig.ruby,
        "OPSD_APP_ROOT" => File.expand_path("..", __dir__),
        "OPSD_WORKSPACE_ROOT" => workspace
      }
      Open3.popen3(env, File.expand_path("../bin/opsd-mcp", __dir__)) do |stdin, stdout, stderr, process|
        stdin.binmode
        diagnostics = Thread.new { stderr.read }
        begin
          yield(stdin, stdout)
          stdin.close unless stdin.closed?
          assert process.join(RESPONSE_TIMEOUT), "MCP server did not exit after EOF"
          assert_predicate process.value, :success?, diagnostics.value
          assert_equal "", stdout.read, "Unexpected extra protocol output"
        ensure
          stdin.close unless stdin.closed?
          # Ensure a protocol regression cannot leave a child or the suite hanging.
          unless process.join(0)
            Process.kill("TERM", process.pid)
            Process.kill("KILL", process.pid) unless process.join(1)
          end
          process.join
          diagnostics.join
        end
      end
    end
  end

  def request_metadata(version: "2026-07-28")
    {
      "io.modelcontextprotocol/protocolVersion" => version,
      "io.modelcontextprotocol/clientCapabilities" => {},
      "io.modelcontextprotocol/clientInfo" => { "name" => "opsd-test", "version" => "1.0.0" }
    }
  end

  def request(io, id, method, params = {}, meta: request_metadata)
    params = params.merge("_meta" => meta) if params.is_a?(Hash)
    write_message(io, { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
  end

  def write_message(io, payload)
    io.write(JSON.generate(payload) + "\n")
    io.flush
  end

  def read_message(io)
    line = Timeout.timeout(RESPONSE_TIMEOUT) { io.gets("\n") }
    refute_nil line, "Unexpected EOF while reading MCP message"
    assert line.end_with?("\n"), "MCP response is not newline-delimited"
    response = JSON.parse(line)
    if response.key?("result")
      assert_equal "complete", response.fetch("result").fetch("resultType")
      identity = response.dig("result", "_meta", "io.modelcontextprotocol/serverInfo")
      assert_equal "opsd", identity.fetch("name")
      assert_kind_of String, identity.fetch("version")
    end
    response
  end

  def assert_cacheable(result)
    assert_equal 0, result.fetch("ttlMs")
    assert_equal "private", result.fetch("cacheScope")
  end

  def assert_error(response, code, id:)
    assert_equal "2.0", response.fetch("jsonrpc")
    if id.nil?
      refute response.key?("id")
    else
      assert_equal id, response.fetch("id")
    end
    assert_equal code, response.fetch("error").fetch("code")
    refute response.key?("result")
  end
end
