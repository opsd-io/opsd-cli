# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "opsd/mcp_tool_executor"

class McpToolExecutorTest < Minitest::Test
  def test_executes_literal_arguments_in_the_selected_workspace
    with_executor(<<~'CODE') do |executor, workspace|
      require "json"
      puts JSON.generate("argv" => ARGV, "cwd" => Dir.pwd, "workspace" => ENV.fetch("OPSD_WORKSPACE_ROOT"))
    CODE
      arguments = ["validate", "manifest", "demo $(touch injected); file.yaml"]
      response = executor.call(arguments)
      result = JSON.parse(response.fetch("structuredContent").fetch("stdout"))
      assert_equal false, response.fetch("isError")
      assert_equal arguments, result.fetch("argv")
      assert_equal File.realpath(workspace), File.realpath(result.fetch("cwd"))
      assert_equal workspace, result.fetch("workspace")
      refute File.exist?(File.join(workspace, "injected"))
    end
  end

  def test_reads_both_output_streams_without_pipe_deadlock
    with_executor("$stdout.write('o' * 100_000); $stderr.write('e' * 100_000)") do |executor, _|
      response = executor.call(%w[list blueprints])
      assert_equal false, response.fetch("isError")
      assert_equal 100_000, response.dig("structuredContent", "stdout").length
      assert_equal 100_000, response.dig("structuredContent", "stderr").length
      assert_equal 0, response.dig("structuredContent", "exitCode")
    end
  end

  def test_nonzero_status_is_an_operational_tool_error
    with_executor("warn 'invalid manifest'; exit 2") do |executor, _|
      response = executor.call(%w[validate manifest missing.yaml])
      assert_equal true, response.fetch("isError")
      assert_equal 2, response.dig("structuredContent", "exitCode")
      assert_includes response.dig("structuredContent", "stderr"), "invalid manifest"
      assert_equal false, response.dig("structuredContent", "timedOut")
    end
  end

  def test_timeout_terminates_the_command_and_reports_failure
    with_executor("sleep 10", timeout: 0.2) do |executor, _|
      response = executor.call(%w[list blueprints])
      assert_equal true, response.fetch("isError")
      assert_equal true, response.dig("structuredContent", "timedOut")
      assert_includes response.fetch("content").first.fetch("text"), "timed out"
    end
  end

  def test_missing_launcher_is_a_tool_error
    Dir.mktmpdir("opsd-mcp-executor-") do |workspace|
      response = OPSd::McpToolExecutor.new(app_root: workspace, workspace_root: workspace).call(%w[list blueprints])
      assert_equal true, response.fetch("isError")
      assert_nil response.dig("structuredContent", "exitCode")
      assert_includes response.dig("structuredContent", "stderr"), "opsd"
    end
  end

  private

  def with_executor(source, timeout: 5)
    Dir.mktmpdir("opsd-mcp-executor-") do |root|
      workspace = File.join(root, "client workspace")
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(File.join(root, "bin"))
      launcher = File.join(root, "bin", "opsd")
      File.write(launcher, "#!#{RbConfig.ruby}\n#{source}\n")
      File.chmod(0o755, launcher)
      yield OPSd::McpToolExecutor.new(app_root: root, workspace_root: workspace, timeout: timeout), workspace
    end
  end
end
