# frozen_string_literal: true

require "json"
require "tmpdir"
require "minitest/autorun"
require "opsd/cli"

class CliVerifyLifecycleTest < Minitest::Test
  def test_verify_lifecycle_passes_for_supported_versions
    Dir.mktmpdir("opsd-lifecycle") do |workspace|
      snapshot_path = File.join(workspace, "supported-lifecycle.json")
      File.write(snapshot_path, JSON.pretty_generate(lifecycle_snapshot(
        provider_version: "v1.0.0",
        tofu_version: "1.10.0",
        policy_version: "2"
      )))

      stdout, = capture_io do
        OPSd::CLI.new(["verify", "lifecycle", snapshot_path]).run
      end

      assert_includes stdout, "Lifecycle is compatible: #{snapshot_path}"
      assert_includes stdout, "provider module: supported (v1.0.0)"
      assert_includes stdout, "OpenTofu: supported (1.10.0)"
      assert_includes stdout, "managed policy data: supported (2)"
      refute_includes stdout, "Warnings:"
    end
  end

  def test_verify_lifecycle_reports_warnings_for_deprecated_versions
    Dir.mktmpdir("opsd-lifecycle") do |workspace|
      snapshot_path = File.join(workspace, "deprecated-lifecycle.json")
      File.write(snapshot_path, JSON.pretty_generate(lifecycle_snapshot(
        provider_version: "v1.0.0",
        tofu_version: "1.9.0",
        policy_version: "1"
      )))

      stdout, = capture_io do
        OPSd::CLI.new(["verify", "lifecycle", snapshot_path]).run
      end

      assert_includes stdout, "Lifecycle is compatible: #{snapshot_path}"
      assert_includes stdout, "Warnings:"
      assert_includes stdout, "[OPSD-LIFECYCLE-DEPRECATED]"
      assert_includes stdout, "deprecated (1.9.0) -> 1.10.0"
      assert_includes stdout, "deprecated (1) -> 2"
    end
  end

  def test_verify_lifecycle_reports_blocking_findings_for_unsupported_versions
    Dir.mktmpdir("opsd-lifecycle") do |workspace|
      snapshot_path = File.join(workspace, "unsupported-lifecycle.json")
      File.write(snapshot_path, JSON.pretty_generate(lifecycle_snapshot(
        provider_version: "v0.9.0",
        tofu_version: "1.10.0",
        policy_version: "2"
      )))

      stdout, stderr = capture_io do
        error = assert_raises(SystemExit) do
          OPSd::CLI.new(["verify", "lifecycle", snapshot_path]).run
        end

        assert_equal 1, error.status
      end

      combined = stdout + stderr
      assert_includes combined, "Lifecycle verification failed: #{snapshot_path}"
      assert_includes combined, "Blocking findings:"
      assert_includes combined, "[OPSD-LIFECYCLE-UPGRADE-MISSING]"
      assert_includes combined, "No upgrade path is available for provider module version v0.9.0"
    end
  end

  def test_verify_lifecycle_reports_distinct_failure_when_upgrade_path_is_missing
    Dir.mktmpdir("opsd-lifecycle") do |workspace|
      snapshot_path = File.join(workspace, "missing-upgrade-lifecycle.json")
      File.write(snapshot_path, JSON.pretty_generate(lifecycle_snapshot(
        provider_version: "v9.9.9",
        tofu_version: "1.10.0",
        policy_version: "2"
      )))

      stdout, stderr = capture_io do
        error = assert_raises(SystemExit) do
          OPSd::CLI.new(["verify", "lifecycle", snapshot_path]).run
        end

        assert_equal 1, error.status
      end

      combined = stdout + stderr
      assert_includes combined, "Lifecycle verification failed: #{snapshot_path}"
      assert_includes combined, "[OPSD-LIFECYCLE-UPGRADE-MISSING]"
      refute_includes combined, "upgrade to"
    end
  end

  private

  def lifecycle_snapshot(provider_version:, tofu_version:, policy_version:)
    {
      "provider" => "digitalocean",
      "provider_version" => provider_version,
      "tofu_version" => tofu_version,
      "policy_version" => policy_version
    }
  end
end
