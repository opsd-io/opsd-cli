# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "yaml"
require "minitest/autorun"
require "opsd/cli"

class CliVerifyConfigTest < Minitest::Test
  def test_verify_config_passes_for_supported_manifest
    Dir.mktmpdir("opsd-verify") do |workspace|
      manifest_path = File.join(workspace, "manifest.yaml")
      write_workspace_fixtures(workspace)
      File.write(manifest_path, YAML.dump(supported_manifest))

      stdout, = capture_io do
        with_opsd_env(workspace) do
          OPSd::CLI.new(["verify", "config", manifest_path]).run
        end
      end

      assert_includes stdout, "Config is valid: #{manifest_path}"
      assert_includes stdout, "Provider: digitalocean"
      assert_includes stdout, "Blueprint: droplet-single"
      assert_includes stdout, "Variant: vm"
      assert_includes stdout, "Next step:"
      assert_includes stdout, "opsd render manifest #{manifest_path} --output <directory>"
      refute_includes stdout, "Blocking findings:"
      refute_includes stdout, "Warnings:"
    end
  end

  def test_verify_config_reports_warnings_for_public_exposure
    Dir.mktmpdir("opsd-verify") do |workspace|
      manifest_path = File.join(workspace, "manifest.yaml")
      write_workspace_fixtures(workspace)
      File.write(manifest_path, YAML.dump(public_manifest))

      stdout, = capture_io do
        with_opsd_env(workspace) do
          OPSd::CLI.new(["verify", "config", manifest_path]).run
        end
      end

      assert_includes stdout, "Config is valid: #{manifest_path}"
      assert_includes stdout, "Warnings:"
      assert_includes stdout, "[OPSD-COST-001]"
      assert_includes stdout, "[OPSD-REL-001]"
    end
  end

  def test_verify_config_reports_blocking_findings_for_unsupported_path
    Dir.mktmpdir("opsd-verify") do |workspace|
      manifest_path = File.join(workspace, "manifest.yaml")
      write_workspace_fixtures(workspace)
      File.write(manifest_path, YAML.dump(unsupported_manifest))

      stdout, stderr = capture_io do
        error = assert_raises(SystemExit) do
          with_opsd_env(workspace) do
            OPSd::CLI.new(["verify", "config", manifest_path]).run
          end
        end

        assert_equal 1, error.status
      end

      combined = stdout + stderr
      assert_includes combined, "Config verification failed: #{manifest_path}"
      assert_includes combined, "Blocking findings:"
      assert_includes combined, "[OPSD-CONTRACT-PATH]"
    end
  end

  private

  def write_workspace_fixtures(workspace)
    FileUtils.mkdir_p(File.join(workspace, "modules", "digitalocean", "blueprints"))
    FileUtils.mkdir_p(File.join(workspace, "modules", "digitalocean"))

    File.write(File.join(workspace, "modules", "digitalocean", "blueprints", "droplet-single.yaml"), <<~YAML)
      id: droplet-single
      title: Droplet Single
      variants:
        - id: vm
          family: droplet
          stack: droplet-single-do-dns
    YAML

    File.write(File.join(workspace, "modules", "digitalocean", "opsd.yaml"), <<~YAML)
      profiles:
        compute:
          droplet:
            - s-1vcpu-1gb
        databases:
          postgres:
            - db-s-1vcpu-1gb
        caches:
          valkey:
            - db-s-1vcpu-1gb
        object_storage:
          spaces:
            - standard
      addons:
        databases:
          - postgres
        caches:
          - valkey
        object_storage:
          - spaces
        cdn_endpoints:
          - cdn
        load_balancers:
          - public
          - private
        nodes:
          - vm
    YAML
  end

  def supported_manifest
    {
      "apiVersion" => "opsd.io/v2alpha1",
      "kind" => "Environment",
      "metadata" => {
        "name" => "demo",
        "environment" => "development",
        "region" => "fra1",
        "tags" => ["managed-by-opsd"],
        "labels" => {}
      },
      "spec" => {
        "provider" => "digitalocean",
        "origin" => {
          "blueprint" => "droplet-single",
          "variant" => "vm",
          "family" => "droplet",
          "stack" => "droplet-single-do-dns",
          "modules" => {
            "repo" => "local-workspace",
            "version" => "local-workspace",
            "commit" => "abcdef1234567890abcdef1234567890abcdef12"
          }
        },
        "defaults" => {
          "project" => "demo",
          "network" => "shared"
        },
        "compute_groups" => [
          {
            "id" => "primary",
            "type" => "vm",
            "role" => "app",
            "replicas" => 1,
            "profile" => "s-1vcpu-1gb"
          }
        ],
        "nodes" => [],
        "databases" => [],
        "caches" => [],
        "load_balancers" => [],
        "object_storage" => [],
        "cdn_endpoints" => [],
        "policies" => {
          "drift_detection" => "strict",
          "managed_output" => true
        }
      }
    }
  end

  def public_manifest
    data = supported_manifest
    data["spec"]["compute_groups"][0]["replicas"] = 1
    data["spec"]["load_balancers"] = [
      {
        "id" => "web-public",
        "visibility" => "public",
        "protocol" => "http",
        "port" => 80,
        "target_port" => 8080
      }
    ]
    data
  end

  def unsupported_manifest
    data = supported_manifest
    data["spec"]["origin"]["blueprint"] = "unknown-blueprint"
    data["spec"]["origin"]["variant"] = "vm"
    data
  end

  def with_opsd_env(workspace)
    previous_app_root = ENV["OPSD_APP_ROOT"]
    previous_workspace_root = ENV["OPSD_WORKSPACE_ROOT"]
    previous_profile = ENV["OPSD_PROFILE"]

    ENV["OPSD_APP_ROOT"] = File.expand_path("..", __dir__)
    ENV["OPSD_WORKSPACE_ROOT"] = workspace
    ENV["OPSD_PROFILE"] = "test"

    config_path = File.join(workspace, ".opsd", "config")
    FileUtils.mkdir_p(File.dirname(config_path))
    File.write(config_path, YAML.dump("profiles" => { "test" => { "provider" => "digitalocean" } }))

    yield
  ensure
    ENV["OPSD_APP_ROOT"] = previous_app_root
    ENV["OPSD_WORKSPACE_ROOT"] = previous_workspace_root
    ENV["OPSD_PROFILE"] = previous_profile
  end
end
