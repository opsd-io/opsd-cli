# frozen_string_literal: true

require "open3"
require "pathname"
require "rbconfig"

module OPSd
  # Reuse the CLI's validation and exit semantics without sharing its stdout or SystemExit.
  class McpToolExecutor
    DEFAULT_TIMEOUT = 60

    def initialize(app_root:, workspace_root:, timeout: DEFAULT_TIMEOUT)
      @app_root = Pathname(app_root).expand_path
      @workspace_root = Pathname(workspace_root).expand_path
      @timeout = timeout
    end

    def call(argv)
      env = {
        "OPSD_APP_ROOT" => @app_root.to_s,
        "OPSD_WORKSPACE_ROOT" => @workspace_root.to_s,
        "RUBY_BIN" => RbConfig.ruby,
        # MCP uses prepared workspace modules; setup must be an explicit CLI action.
        "OPSD_MODULES_OFFLINE" => "1"
      }
      launcher = @app_root.join("bin", "opsd").to_s
      # An explicit executable/argv pair prevents shell interpretation, including for a single argument.
      Open3.popen3(env, [launcher, launcher], *argv, chdir: @workspace_root.to_s, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        output_reader = Thread.new { stdout.read }
        error_reader = Thread.new { stderr.read }
        timed_out = process.join(@timeout).nil?
        stop_process(process) if timed_out
        status = process.value
        result(output_reader.value, error_reader.value, status.exitstatus, success: status.success?, timed_out: timed_out)
      ensure
        # Unwind the CLI too if server execution is interrupted (for example by SIGTERM).
        stop_process(process) unless process.join(0)
        output_reader&.join
        error_reader&.join
      end
    rescue SystemCallError => e
      result("", e.message, nil, success: false, timed_out: false)
    end

    private

    def stop_process(process)
      signal_group("TERM", process.pid)
      process.join(1)
      # Kill surviving descendants too: they can otherwise keep the output pipes open.
      signal_group("KILL", process.pid)
      process.join
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    def result(stdout, stderr, exit_code, success:, timed_out:)
      messages = [stdout, stderr].reject(&:empty?)
      messages << "OPSd command timed out after #{@timeout} seconds." if timed_out
      if messages.empty?
        messages << (success ? "OPSd command completed successfully." : "OPSd command failed with exit status #{exit_code.inspect}.")
      end
      {
        "content" => [{ "type" => "text", "text" => messages.join("\n") }],
        "structuredContent" => { "stdout" => stdout, "stderr" => stderr, "exitCode" => exit_code, "timedOut" => timed_out },
        "isError" => timed_out || !success
      }
    end
  end
end
