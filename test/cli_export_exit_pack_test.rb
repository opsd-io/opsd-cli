# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require "minitest/autorun"
require "opsd/cli"

class CliExportExitPackTest < Minitest::Test
  def test_export_exit_pack_from_rendered_directory
    Dir.mktmpdir("opsd-export") do |root|
      rendered_dir = File.join(root, "rendered")
      archive_path = File.join(root, "exit-pack.tar.gz")

      write_rendered_project(rendered_dir)

      stdout, = capture_io do
        OPSd::CLI.new(["export", "exit-pack", rendered_dir, "--output", archive_path]).run
      end

      assert_includes stdout, "Exported exit pack: #{archive_path}"
      assert_includes stdout, "Source directory: #{rendered_dir}"
      assert_includes stdout, "Artifacts:"
      assert File.file?(archive_path)
    end
  end

  private

  def write_rendered_project(rendered_dir)
    FileUtils.mkdir_p(rendered_dir)

    File.write(File.join(rendered_dir, "opsd.manifest.yaml"), <<~YAML)
      apiVersion: opsd.io/v2alpha1
      kind: Environment
      metadata:
        name: demo
      spec:
        provider: digitalocean
        origin:
          blueprint: demo-blueprint
          variant: vm
        defaults: {}
        compute_groups: []
        nodes: []
        databases: []
        caches: []
        load_balancers: []
        object_storage: []
        cdn_endpoints: []
        policies: {}
    YAML

    File.write(File.join(rendered_dir, "opsd.lock.yaml"), <<~YAML)
      provider_modules:
        provider: digitalocean
        repo: https://github.com/opsd-io/modules-digitalocean.git
        version: v1.0.0
        commit: abc123
        resolved_at: "2026-07-28T00:00:00Z"
      opsd_cli:
        version: 0.0.0-test
    YAML

    File.write(File.join(rendered_dir, "opsd.auto.tfvars"), "name = \"demo\"\n")
    File.write(File.join(rendered_dir, "main.tf"), "terraform {}\n")
    File.write(File.join(rendered_dir, "variables.tf"), "variable \"name\" {}\n")
    File.write(File.join(rendered_dir, "outputs.tf"), "output \"name\" {}\n")
    File.write(File.join(rendered_dir, "README.md"), "# Rendered stack\n")
    File.write(File.join(rendered_dir, "scenario.json"), "{\"id\":\"demo\"}\n")
    File.write(File.join(rendered_dir, "tofu.tfvars.example"), "name = \"demo\"\n")
  end
end
