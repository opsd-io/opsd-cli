# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "opsd/kubernetes_module"
require "opsd/cli"

class KubernetesModuleTest < Minitest::Test
  EXAMPLE_PATH = File.expand_path("../examples/modules-kubernetes/modules/bootstrap/root-app-of-apps/module.yaml", __dir__)

  def test_example_module_metadata_validates
    assert_equal true, OPSd::KubernetesModule.load(EXAMPLE_PATH).validate!
  end

  def test_cli_validates_example_module_metadata
    stdout, = capture_io do
      OPSd::CLI.new(["validate", "module", EXAMPLE_PATH]).run
    end

    assert_includes stdout, "Kubernetes module metadata is valid: #{EXAMPLE_PATH}"
    assert_includes stdout, "Module: root-app-of-apps"
    assert_includes stdout, "Layer: bootstrap"
  end

  def test_rejects_unknown_layer
    data = YAML.load_file(EXAMPLE_PATH)
    data["spec"]["layer"] = "unknown"

    error = assert_raises(OPSd::KubernetesModule::ValidationError) do
      OPSd::KubernetesModule.new(data).validate!
    end

    assert_includes error.errors, "spec.layer must be one of: bootstrap, infrastructure, monitoring, tools, applications"
  end

  def test_official_modules_require_strict_validation
    data = YAML.load_file(EXAMPLE_PATH)
    data["spec"]["validation"]["mode"] = "permissive"

    error = assert_raises(OPSd::KubernetesModule::ValidationError) do
      OPSd::KubernetesModule.new(data).validate!
    end

    assert_includes error.errors, "spec.validation.mode must be strict for official modules"
  end

  def test_custom_modules_can_use_permissive_validation
    data = YAML.load_file(EXAMPLE_PATH)
    data["metadata"]["id"] = "client-addon"
    data["metadata"]["name"] = "Client Addon"
    data["spec"]["ownership"] = {
      "type" => "custom",
      "repository" => "acme/platform"
    }
    data["spec"]["validation"]["mode"] = "permissive"

    assert_equal true, OPSd::KubernetesModule.new(data).validate!
  end
end
