# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "minitest/autorun"
require "opsd/cli"
require "opsd/config_verifier"
require "opsd/plan_verifier"
require "opsd/template_store"
require "opsd/contract_store"

class CliVerifyPlanTest < Minitest::Test
  def test_verify_plan_passes_for_additive_changes
    Dir.mktmpdir("opsd-plan") do |workspace|
      plan_path = File.join(workspace, "additive-plan.json")
      File.write(plan_path, JSON.pretty_generate(additive_plan))

      stdout, = capture_io do
        OPSd::CLI.new(["verify", "plan", plan_path]).run
      end

      assert_includes stdout, "Plan is supported: #{plan_path}"
      assert_includes stdout, "Additive changes: 1"
      assert_includes stdout, "Destructive changes: 0"
      refute_includes stdout, "Blocking findings:"
    end
  end

  def test_verify_plan_reports_blocking_findings_for_destructive_changes
    Dir.mktmpdir("opsd-plan") do |workspace|
      plan_path = File.join(workspace, "destructive-plan.json")
      File.write(plan_path, JSON.pretty_generate(destructive_plan))

      stdout, stderr = capture_io do
        error = assert_raises(SystemExit) do
          OPSd::CLI.new(["verify", "plan", plan_path]).run
        end

        assert_equal 1, error.status
      end

      combined = stdout + stderr
      assert_includes combined, "Plan verification failed: #{plan_path}"
      assert_includes combined, "Blocking findings:"
      assert_includes combined, "[OPSD-EXIT-001]"
      assert_includes combined, "Destroying"
    end
  end

  def test_verify_plan_reports_mixed_changes
    Dir.mktmpdir("opsd-plan") do |workspace|
      plan_path = File.join(workspace, "mixed-plan.json")
      File.write(plan_path, JSON.pretty_generate(mixed_plan))

      stdout, stderr = capture_io do
        error = assert_raises(SystemExit) do
          OPSd::CLI.new(["verify", "plan", plan_path]).run
        end

        assert_equal 1, error.status
      end

      combined = stdout + stderr
      assert_includes combined, "Plan verification failed: #{plan_path}"
      assert_includes combined, "[OPSD-EXIT-001]"
      assert_includes combined, "Replacing"
    end
  end

  def test_config_and_plan_verifiers_use_the_same_contract_store
    Dir.mktmpdir("opsd-plan-contract") do |workspace|
      FileUtils.mkdir_p(File.join(workspace, "modules", "digitalocean", "blueprints"))
      FileUtils.mkdir_p(File.join(workspace, "modules", "digitalocean"))
      File.write(File.join(workspace, "modules", "digitalocean", "blueprints", "droplet-single.yaml"), <<~YAML)
        id: droplet-single
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
      YAML

      contract_store = OPSd::ContractStore.new(app_root: File.expand_path("..", __dir__))
      template_store = OPSd::TemplateStore.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: workspace,
        contract_store: contract_store
      )
      config_verifier = OPSd::ConfigVerifier.new(contract_store: contract_store, template_store: template_store)
      plan_verifier = OPSd::PlanVerifier.new(contract_store: contract_store)

      config_rules = contract_store.rule_pack("cost").fetch("rules")
      plan_rules = contract_store.rule_pack("reversibility").fetch("rules")

      config_message = config_verifier.send(:public_exposure_warning, manifest_for_warning).first.message
      plan_message = plan_verifier.send(:validate_change, destructive_change).first.message

      assert_includes config_message, config_rules.first["summary"]
      assert_includes plan_message, plan_rules.first["summary"]
    end
  end

  private

  def additive_plan
    {
      "format_version" => "1.0",
      "resource_changes" => [
        {
          "address" => "digitalocean_droplet.primary",
          "mode" => "managed",
          "type" => "digitalocean_droplet",
          "name" => "primary",
          "change" => {
            "actions" => ["create"],
            "before" => nil,
            "after" => {
              "name" => "primary"
            }
          }
        }
      ]
    }
  end

  def destructive_plan
    {
      "format_version" => "1.0",
      "resource_changes" => [
        {
          "address" => "digitalocean_database.db_main",
          "mode" => "managed",
          "type" => "digitalocean_database",
          "name" => "db_main",
          "change" => {
            "actions" => ["delete"],
            "before" => {
              "name" => "db_main"
            },
            "after" => nil
          }
        }
      ]
    }
  end

  def mixed_plan
    {
      "format_version" => "1.0",
      "resource_changes" => [
        {
          "address" => "digitalocean_droplet.primary",
          "mode" => "managed",
          "type" => "digitalocean_droplet",
          "name" => "primary",
          "change" => {
            "actions" => ["create"],
            "before" => nil,
            "after" => {
              "name" => "primary"
            }
          }
        },
        {
          "address" => "digitalocean_database.db_main",
          "mode" => "managed",
          "type" => "digitalocean_database",
          "name" => "db_main",
          "change" => {
            "actions" => ["delete", "create"],
            "before" => {
              "name" => "db_main"
            },
            "after" => {
              "name" => "db_main"
            }
          }
        }
      ]
    }
  end

  def manifest_for_warning
    OPSd::Manifest.new(
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
          "defaults" => {},
          "compute_groups" => [
            {
              "id" => "primary",
              "type" => "vm",
              "role" => "app",
              "replicas" => 1,
              "profile" => "s-1vcpu-1gb",
              "exposure" => {
                "public" => true
              }
            }
          ],
          "nodes" => [],
          "databases" => [],
          "caches" => [],
          "load_balancers" => [],
          "object_storage" => [],
          "cdn_endpoints" => [],
          "policies" => {}
        }
      }
    )
  end

  def destructive_change
    {
      "address" => "digitalocean_database.db_main",
      "type" => "digitalocean_database",
      "change" => {
        "actions" => ["delete"],
        "before" => {},
        "after" => nil
      }
    }
  end
end
