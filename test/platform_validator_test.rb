# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "pathname"
require "stringio"
require "tmpdir"
require "opsd/platform_validator"

class PlatformValidatorTest < Minitest::Test
  def test_extracts_local_schemas_from_rendered_crds
    Dir.mktmpdir("opsd-platform-validator-test-") do |root|
      workspace = Pathname(root)
      rendered = workspace.join("rendered")
      rendered.join("platform", "helm").mkpath
      rendered.join("platform", "helm", "argocd.yaml").write(<<~YAML)
        apiVersion: apiextensions.k8s.io/v1
        kind: CustomResourceDefinition
        spec:
          group: argoproj.io
          names:
            kind: Application
          versions:
            - name: v1alpha1
              served: true
              schema:
                openAPIV3Schema:
                  type: object
                  properties:
                    spec:
                      type: object
      YAML

      validator(workspace).send(:generate_custom_resource_schemas, rendered)

      schema = JSON.parse(workspace.join(".opsd", "cache", "kubeconform", "crds", "Application-argoproj.io-v1alpha1.json").read)
      assert_equal "argoproj.io/v1alpha1", schema.dig("properties", "apiVersion", "enum", 0)
      assert_equal "Application", schema.dig("properties", "kind", "enum", 0)
      assert_equal %w[apiVersion kind metadata], schema.fetch("required")
    end
  end

  def test_reports_invalid_rendered_kubernetes_resources
    Dir.mktmpdir("opsd-platform-validator-test-") do |root|
      workspace = Pathname(root)
      rendered = workspace.join("rendered")
      rendered.join("layers", "00-bootstrap").mkpath
      rendered.join("layers", "00-bootstrap", "invalid.yaml").write("apiVersion: v1\nkind: Service\n")
      schema_root = workspace.join(".opsd", "cache", "kubeconform", "builtin", "v1.33.0-standalone-strict")
      schema_root.mkpath
      schema_root.join("service-v1.json").write("{}")
      fake_bin = workspace.join("bin")
      fake_bin.mkpath
      kubeconform = fake_bin.join("kubeconform")
      kubeconform.write("#!/bin/sh\necho 'invalid.yaml: Service invalid' >&2\nexit 1\n")
      kubeconform.chmod(0o755)

      error = assert_raises(RuntimeError) do
        validator(workspace, "PATH" => fake_bin.to_s).send(:validate_kubernetes, rendered, FakeManifest.new, offline: false)
      end

      assert_includes error.message, "invalid.yaml: Service invalid"
    end
  end

  def test_offline_validation_fails_before_running_iac_tools_when_provider_cache_is_missing
    Dir.mktmpdir("opsd-platform-validator-test-") do |root|
      workspace = Pathname(root)
      rendered = workspace.join("rendered")
      rendered.mkpath

      error = assert_raises(RuntimeError) do
        validator(workspace, {}).send(:validate_iac, rendered, offline: true)
      end

      assert_includes error.message, "terraform and tofu providers"
      assert_includes error.message, "with network access"
    end
  end

  def test_offline_validation_reports_the_missing_kubernetes_schema
    Dir.mktmpdir("opsd-platform-validator-test-") do |root|
      workspace = Pathname(root)
      rendered = workspace.join("rendered")
      manifest_file = rendered.join("layers", "00-bootstrap", "deployment.yaml")
      manifest_file.dirname.mkpath
      manifest_file.write("apiVersion: apps/v1\nkind: Deployment\n")

      error = assert_raises(RuntimeError) do
        validator(workspace, {}).send(:validate_kubernetes, rendered, FakeManifest.new, offline: true)
      end

      assert_includes error.message, "deployment.yaml"
      assert_includes error.message, "apps/v1 Deployment"
    end
  end

  private

  def validator(workspace, env = {})
    OPSd::PlatformValidator.new(workspace_root: workspace, app_root: workspace, env: ENV.to_h.merge(env), stdout: StringIO.new)
  end

  class FakeManifest
    def primary_kubernetes_config
      { "kubernetes_version" => "1.33.0" }
    end
  end
end
