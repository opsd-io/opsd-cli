# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "opsd/kubernetes_module"
require "opsd/cli"

class KubernetesModuleTest < Minitest::Test
  EXAMPLE_PATH = File.expand_path("../examples/modules-kubernetes/modules/bootstrap/root-app-of-apps/module.yaml", __dir__)
  OCI_EXAMPLE_PATH = File.expand_path("../examples/modules-kubernetes/modules/tools/platform-tools-oci/module.yaml", __dir__)
  GIT_EXAMPLE_PATH = File.expand_path("../examples/modules-kubernetes/modules/applications/platform-tools-git/module.yaml", __dir__)

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

  def test_locked_source_examples_validate
    [OCI_EXAMPLE_PATH, GIT_EXAMPLE_PATH].each do |path|
      assert_equal true, OPSd::KubernetesModule.load(path).validate!, path
    end
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

  def test_helm_source_requires_a_version_and_digest
    data = YAML.load_file(EXAMPLE_PATH)
    data["spec"]["source"].delete("digest")

    error = assert_raises(OPSd::KubernetesModule::ValidationError) do
      OPSd::KubernetesModule.new(data).validate!
    end

    assert_includes error.errors, "spec.source.digest is required for source type helm"
  end

  def test_helm_source_requires_a_version
    data = YAML.load_file(EXAMPLE_PATH)
    data["spec"]["source"].delete("version")

    error = assert_raises(OPSd::KubernetesModule::ValidationError) do
      OPSd::KubernetesModule.new(data).validate!
    end

    assert_includes error.errors, "spec.source.version is required for source type helm"
  end

  def test_oci_source_accepts_a_locked_chart
    data = YAML.load_file(EXAMPLE_PATH)
    data["spec"]["source"] = {
      "type" => "oci",
      "registry" => "registry.example.invalid/opsd",
      "chart" => "platform-tools",
      "version" => "2.0.1",
      "digest" => "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }

    assert_equal true, OPSd::KubernetesModule.new(data).validate!
  end

  def test_git_source_accepts_a_locked_chart
    data = YAML.load_file(EXAMPLE_PATH)
    data["spec"]["source"] = {
      "type" => "git",
      "repository" => "https://github.com/example/platform-modules.git",
      "path" => "charts/platform-tools",
      "ref" => "v2.0.1",
      "commit" => "0123456789abcdef0123456789abcdef01234567"
    }

    assert_equal true, OPSd::KubernetesModule.new(data).validate!
  end

  def test_git_source_requires_a_ref_and_commit
    data = YAML.load_file(EXAMPLE_PATH)
    data["spec"]["source"] = {
      "type" => "git",
      "repository" => "https://github.com/example/platform-modules.git",
      "path" => "charts/platform-tools"
    }

    error = assert_raises(OPSd::KubernetesModule::ValidationError) do
      OPSd::KubernetesModule.new(data).validate!
    end

    assert_includes error.errors, "spec.source.ref is required for source type git"
    assert_includes error.errors, "spec.source.commit is required for source type git"
  end

  def test_git_source_rejects_a_short_commit
    data = YAML.load_file(GIT_EXAMPLE_PATH)
    data["spec"]["source"]["commit"] = "0123456789abcdef"

    error = assert_raises(OPSd::KubernetesModule::ValidationError) do
      OPSd::KubernetesModule.new(data).validate!
    end

    assert_includes error.errors, "spec.source.commit must be a full Git commit SHA"
  end

  def test_source_rejects_unlocked_artifact_records
    data = YAML.load_file(EXAMPLE_PATH)
    data["spec"]["source"]["digest"] = "sha256:not-a-digest"

    error = assert_raises(OPSd::KubernetesModule::ValidationError) do
      OPSd::KubernetesModule.new(data).validate!
    end

    assert_includes error.errors, "spec.source.digest must be a sha256 digest"
  end
end
