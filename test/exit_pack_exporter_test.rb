# frozen_string_literal: true

require "fileutils"
require "json"
require "rubygems/package"
require "tmpdir"
require "zlib"
require "minitest/autorun"
require "opsd/exit_pack_exporter"

class ExitPackExporterTest < Minitest::Test
  def test_export_is_deterministic_for_same_input
    Dir.mktmpdir("opsd-exit-pack") do |root|
      rendered_dir = File.join(root, "rendered")
      archive_one = File.join(root, "first.tar.gz")
      archive_two = File.join(root, "second.tar.gz")

      write_rendered_project(rendered_dir)

      exporter = OPSd::ExitPackExporter.new
      metadata_one = exporter.export(rendered_dir, archive_one)
      metadata_two = exporter.export(rendered_dir, archive_two)

      assert_equal File.binread(archive_one), File.binread(archive_two)
      assert_equal metadata_one, metadata_two

      entries = archive_entries(archive_one)
      assert_includes entries.keys, "exit-pack/opsd.exit-pack.json"
      assert_includes entries.keys, "exit-pack/HANDOFF.md"
      assert_includes entries.keys, "exit-pack/opsd.manifest.yaml"

      metadata = JSON.parse(entries.fetch("exit-pack/opsd.exit-pack.json"))
      assert_equal "opsd.exit-pack", metadata.fetch("format")
      assert_equal 1, metadata.fetch("format_version")
      assert_equal OPSd::VERSION, metadata.fetch("opsd_version")
      assert_includes metadata.fetch("artifacts").map { |artifact| artifact.fetch("path") }, "opsd.lock.yaml"
      assert_includes metadata.fetch("artifacts").map { |artifact| artifact.fetch("path") }, "HANDOFF.md"
    end
  end

  def test_export_includes_required_rendered_artifacts
    Dir.mktmpdir("opsd-exit-pack") do |root|
      rendered_dir = File.join(root, "rendered")
      archive_path = File.join(root, "exit-pack.tar.gz")

      write_rendered_project(rendered_dir)

      exporter = OPSd::ExitPackExporter.new
      metadata = exporter.export(rendered_dir, archive_path)

      entries = archive_entries(archive_path)

      assert_includes entries.keys, "exit-pack/README.md"
      assert_includes entries.keys, "exit-pack/main.tf"
      assert_includes entries.keys, "exit-pack/opsd.auto.tfvars"
      assert_includes entries.keys, "exit-pack/opsd.lock.yaml"
      assert_includes entries.keys, "exit-pack/HANDOFF.md"
      assert_includes entries.keys, "exit-pack/opsd.exit-pack.json"
      assert_equal "v1.0.0", metadata.dig("module_release", "version")
      assert_equal "opsd.io/v2alpha1", metadata.dig("manifest", "apiVersion")
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
    File.write(File.join(rendered_dir, "scenario.json"), JSON.pretty_generate({ "id" => "demo" }))
    File.write(File.join(rendered_dir, "tofu.tfvars.example"), "name = \"demo\"\n")
  end

  def archive_entries(path)
    entries = {}

    Zlib::GzipReader.open(path) do |gzip|
      Gem::Package::TarReader.new(gzip) do |tar|
        tar.each do |entry|
          next unless entry.file?

          entries[entry.full_name] = entry.read
        end
      end
    end

    entries
  end
end
