# frozen_string_literal: true

require "json"
require "pathname"
require "rubygems/package"
require "zlib"
require "yaml"

require_relative "version"

module OPSd
  class ExitPackExporter
    REQUIRED_ARTIFACTS = %w[
      opsd.manifest.yaml
      opsd.lock.yaml
      opsd.auto.tfvars
      main.tf
      variables.tf
      outputs.tf
      README.md
      scenario.json
      tofu.tfvars.example
    ].freeze

    def export(rendered_path, output_path)
      rendered_root = Pathname(rendered_path).expand_path
      archive_path = Pathname(output_path).expand_path

      raise "Rendered directory not found: #{rendered_root}" unless rendered_root.directory?
      raise "Refusing to overwrite existing file: #{archive_path}" if archive_path.exist?
      raise "Exit pack output must be outside the rendered directory" if descendant_or_same?(archive_path, rendered_root)

      validate_required_artifacts!(rendered_root)

      archive_path.dirname.mkpath
      metadata = metadata_for(rendered_root)

      with_source_date_epoch(0) do
        File.open(archive_path, "wb") do |file|
          gzip = Zlib::GzipWriter.new(file)
          gzip.mtime = 0
          gzip.orig_name = ""
          gzip.comment = ""

          Gem::Package::TarWriter.new(gzip) do |tar|
            write_directory(tar, "exit-pack")
            write_metadata(tar, metadata)
            write_handoff_notes(tar, metadata)

            rendered_files(rendered_root).each do |relative_path|
              write_file(tar, rendered_root.join(relative_path), "exit-pack/#{relative_path}")
            end
          end
        ensure
          gzip.close unless gzip.closed?
        end
      end

      metadata
    end

    private

    def validate_required_artifacts!(rendered_root)
      missing = REQUIRED_ARTIFACTS.reject { |artifact| rendered_root.join(artifact).file? }
      return if missing.empty?

      raise "Rendered directory is missing required artifacts: #{missing.join(', ')}"
    end

    def metadata_for(rendered_root)
      manifest = YAML.load_file(rendered_root.join("opsd.manifest.yaml"))
      lock = YAML.load_file(rendered_root.join("opsd.lock.yaml"))

      provider_modules = lock.fetch("provider_modules", {})

      metadata = {
        "format" => "opsd.exit-pack",
        "format_version" => 1,
        "opsd_version" => OPSd::VERSION,
        "manifest" => {
          "apiVersion" => manifest["apiVersion"],
          "kind" => manifest["kind"],
          "provider" => manifest.dig("spec", "provider"),
          "blueprint" => manifest.dig("spec", "origin", "blueprint"),
          "variant" => manifest.dig("spec", "origin", "variant")
        },
        "module_release" => {
          "provider" => provider_modules["provider"],
          "repo" => provider_modules["repo"],
          "version" => provider_modules["version"],
          "commit" => provider_modules["commit"]
        }
      }

      metadata["artifacts"] = artifact_entries(rendered_root, metadata)
      metadata
    end

    def artifact_entries(rendered_root, metadata)
      entries = rendered_files(rendered_root).map do |relative_path|
        {
          "path" => relative_path,
          "bytes" => rendered_root.join(relative_path).size
        }
      end

      entries << {
        "path" => "HANDOFF.md",
        "bytes" => handoff_notes_for(metadata).bytesize
      }

      entries
    end

    def rendered_files(rendered_root)
      rendered_root
        .find
        .select { |entry| entry.file? }
        .map { |entry| entry.relative_path_from(rendered_root).to_s }
        .reject { |path| path == "opsd.exit-pack.json" }
        .sort
    end

    def write_metadata(tar, metadata)
      payload = JSON.pretty_generate(metadata) + "\n"
      write_string(tar, "exit-pack/opsd.exit-pack.json", payload)
    end

    def write_handoff_notes(tar, metadata)
      notes = handoff_notes_for(metadata)

      write_string(tar, "exit-pack/HANDOFF.md", notes)
    end

    def handoff_notes_for(metadata)
      <<~MD
        # OPSd Exit Pack

        This archive packages a client-owned OpenTofu handoff that can be used without OPSd runtime access.

        ## Included Artifacts

        - `opsd.manifest.yaml`
        - `opsd.lock.yaml`
        - `opsd.auto.tfvars`
        - `main.tf`
        - `variables.tf`
        - `outputs.tf`
        - `README.md`
        - `scenario.json`
        - `tofu.tfvars.example`

        ## Versions

        - OPSd CLI: #{metadata.fetch("opsd_version")}
        - Manifest API: #{metadata.dig("manifest", "apiVersion")}
        - Provider module: #{metadata.dig("module_release", "version")}

        ## Next Steps

        1. Extract the archive.
        2. `cd exit-pack`
        3. `tofu init -backend=false -input=false`
        4. `tofu plan`
        5. `tofu apply`
      MD
    end

    def write_file(tar, source_path, archive_path)
      mkdirs_for(tar, archive_path)
      tar.add_file_simple(archive_path, 0o644, source_path.size) do |io|
        io.write(source_path.binread)
      end
    end

    def write_string(tar, archive_path, content)
      mkdirs_for(tar, archive_path)
      tar.add_file_simple(archive_path, 0o644, content.bytesize) do |io|
        io.write(content)
      end
    end

    def write_directory(tar, archive_path)
      tar.mkdir(archive_path, 0o755)
    end

    def mkdirs_for(tar, archive_path)
      path = Pathname(archive_path)
      parents = []

      while path.dirname != path && path.dirname.to_s != "."
        path = path.dirname
        parents << path.to_s
      end

      parents.reverse_each do |dir|
        next if dir == "exit-pack"

        tar.mkdir(dir, 0o755) unless dir.empty?
      end
    end

    def descendant_or_same?(child, parent)
      child = child.expand_path
      parent = parent.expand_path
      child == parent || child.to_s.start_with?("#{parent}/")
    end

    def with_source_date_epoch(epoch)
      previous = ENV["SOURCE_DATE_EPOCH"]
      ENV["SOURCE_DATE_EPOCH"] = epoch.to_s
      yield
    ensure
      ENV["SOURCE_DATE_EPOCH"] = previous
    end
  end
end
