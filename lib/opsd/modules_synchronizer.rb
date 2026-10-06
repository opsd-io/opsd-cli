# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

require_relative "kubernetes_module"
require_relative "module_catalog"

module OPSd
  class ModulesSynchronizer
    DEFAULT_KUBERNETES_REPO = "https://github.com/opsd-io/modules-kubernetes.git"
    REPOSITORIES = { "digitalocean" => "provider_modules", "kubernetes" => "kubernetes_modules" }.freeze

    def initialize(workspace_root:, cache_root: nil, env: ENV, module_catalog: nil)
      @workspace_root = Pathname(workspace_root).expand_path
      @cache_root = Pathname(cache_root || @workspace_root.join(".opsd", "cache")).expand_path
      @env = env
      @module_catalog = module_catalog || ModuleCatalog.new(workspace_root: @workspace_root, cache_root: @cache_root, env:)
    end

    def sync(manifest_path:, update: false)
      manifest_path = Pathname(manifest_path).expand_path
      lock_path = manifest_path.dirname.join("opsd.lock.yaml")
      previous_lock = read_lock(lock_path)
      if previous_lock && update
        raise "Refusing to update module pins while synchronized module directories have local changes." unless synchronized_trees_intact?(previous_lock)
      end

      provider = YAML.load_file(manifest_path).dig("spec", "provider").to_s
      provider_lock = resolve_provider_pin(provider, previous_lock, update)
      kubernetes_lock = resolve_kubernetes_pin(previous_lock, update)
      kubernetes_root = repository_source_root("kubernetes", kubernetes_lock)
      chart_locks = chart_metadata(kubernetes_root)

      lock = (previous_lock || {}).merge(
        "provider_modules" => provider_lock,
        "kubernetes_modules" => kubernetes_lock,
        "helm_charts" => chart_locks
      )

      validate_destinations!(lock, previous_lock)
      cache_charts!(chart_locks)
      sync_repository("digitalocean", provider_lock, provider_source_root(provider, provider_lock), previous_lock)
      sync_repository("kubernetes", kubernetes_lock, kubernetes_root, previous_lock)
      write_lock(lock_path, lock)
      lock
    end

    def verify(manifest_path:)
      manifest_path = Pathname(manifest_path).expand_path
      lock_path = manifest_path.dirname.join("opsd.lock.yaml")
      lock = read_lock(lock_path)
      raise "Pinned OPSd modules are missing; run `opsd modules sync #{manifest_path}` first." unless lock

      REPOSITORIES.each do |name, lock_key|
        pin = lock[lock_key]
        path = @workspace_root.join("modules", name)
        unless pin && pin["tree_sha256"] && path.directory? && tree_digest(path) == pin["tree_sha256"]
          raise "Synchronized #{name} modules do not match opsd.lock.yaml; restore the pinned tree or run `opsd modules sync --update`."
        end
      end

      actual_charts = chart_metadata(@workspace_root.join("modules", "kubernetes"))
      expected_charts = Array(lock["helm_charts"])
      unless canonicalize(actual_charts) == canonicalize(expected_charts)
        raise "Kubernetes Helm chart metadata does not match opsd.lock.yaml; run `opsd modules sync --update`."
      end
      expected_charts.each do |chart|
        archive = @cache_root.join("helm", "#{chart.fetch('digest').delete_prefix('sha256:')}.tgz")
        raise "Cached Helm chart is missing for #{chart.fetch('module')}; run `opsd modules sync`." unless archive.file?

        verify_digest!(chart, archive)
      end
      lock
    end

    private

    def resolve_provider_pin(provider, previous_lock, update)
      existing = previous_lock && previous_lock["provider_modules"]
      if existing && !update
        %w[repo version commit].each do |key|
          raise "Invalid opsd.lock.yaml: provider_modules.#{key} is required" if existing[key].to_s.empty?
        end
        return existing
      end

      catalog = if @module_catalog.is_a?(ModuleCatalog)
                  ModuleCatalog.new(
                    workspace_root: @cache_root.join("module-resolution-workspace"),
                    cache_root: @cache_root,
                    env: @env
                  )
                else
                  @module_catalog
                end
      resolution = catalog.resolve(provider)
      catalog.lock_data_for(resolution).fetch("provider_modules")
    end

    def provider_source_root(provider, pin)
      repository_source_root(provider, pin)
    end

    def resolve_kubernetes_pin(previous_lock, update)
      existing = previous_lock && previous_lock["kubernetes_modules"]
      if existing && !update
        %w[repo version commit].each do |key|
          raise "Invalid opsd.lock.yaml: kubernetes_modules.#{key} is required" if existing[key].to_s.empty?
        end
        pin = existing
      else
        repo = @env.fetch("OPSD_MODULES_KUBERNETES_REPO", DEFAULT_KUBERNETES_REPO)
        version = @env.fetch("OPSD_MODULES_KUBERNETES_REF", "main")
        raise "OPSD_MODULES_KUBERNETES_REF cannot be empty" if version.strip.empty?
        Dir.mktmpdir("opsd-kubernetes-pin-") do |temporary|
          source = clone_at({ "repo" => repo, "version" => version }, "kubernetes", destination: File.join(temporary, "source"))
          commit = git!("-C", source.to_s, "rev-parse", "HEAD").strip
          pin = { "repo" => repo, "version" => version, "commit" => commit }
        end
      end

      pin
    end

    def clone_at(pin, name, destination: nil)
      target = Pathname(destination || Dir.mktmpdir("opsd-#{name}-source-")).expand_path
      if target.directory? && pin["commit"] && git!("-C", target.to_s, "rev-parse", "HEAD").strip == pin.fetch("commit")
        return target
      end
      FileUtils.rm_rf(target)
      target.dirname.mkpath
      git!("clone", "--no-checkout", "--filter=blob:none", pin.fetch("repo"), target.to_s)
      git!("-C", target.to_s, "fetch", "--depth", "1", "origin", pin.fetch("commit", pin.fetch("version")))
      git!("-C", target.to_s, "checkout", "--detach", "FETCH_HEAD")
      if pin["commit"] && git!("-C", target.to_s, "rev-parse", "HEAD").strip != pin.fetch("commit")
        raise "Pinned #{name} commit does not match #{pin.fetch('commit')}"
      end
      target
    rescue StandardError
      FileUtils.rm_rf(target)
      raise
    end

    def cached_source_path(name, pin)
      ref = pin.fetch("commit", pin.fetch("version"))
      key = ref.match?(/\A[0-9a-f]{40,64}\z/i) ? ref : Digest::SHA256.hexdigest(ref)[0, 16]
      @cache_root.join("sources", name, key)
    end

    def repository_source_root(name, pin)
      clone_at(pin, name, destination: cached_source_path(name, pin))
    end

    def chart_metadata(kubernetes_root)
      Dir.glob(kubernetes_root.join("modules", "**", "module.yaml")).sort.filter_map do |path|
        module_data = KubernetesModule.load(path)
        module_data.validate!
        source = module_data.data.dig("spec", "source")
        next unless %w[helm oci].include?(source.fetch("type"))

        {
          "module" => module_data.data.dig("metadata", "id"),
          "repository" => source["repository"] || source["registry"],
          "chart" => source.fetch("chart"),
          "version" => source.fetch("version"),
          "digest" => source.fetch("digest")
        }
      end
    end

    def cache_charts!(charts)
      charts.each do |chart|
        archive = @cache_root.join("helm", "#{chart.fetch('digest').delete_prefix('sha256:')}.tgz")
        if archive.file?
          verify_digest!(chart, archive)
          next
        end

        archive.dirname.mkpath
        Dir.mktmpdir("opsd-helm-") do |directory|
          repository = chart.fetch("repository")
          source = repository.start_with?("oci://") ? File.join(repository, chart.fetch("chart")) : chart.fetch("chart")
          command = ["helm", "pull", source, "--version", chart.fetch("version"), "--destination", directory]
          command.insert(2, "--repo", repository) unless repository.start_with?("oci://")
          stdout, stderr, status = Open3.capture3(@env, *command)
          raise "Unable to download Helm chart #{chart.fetch('chart')}: #{stderr.empty? ? stdout : stderr}" unless status.success?

          downloaded = Pathname(directory).join("#{chart.fetch('chart')}-#{chart.fetch('version')}.tgz")
          verify_digest!(chart, downloaded)
          FileUtils.mv(downloaded, archive)
        end
      end
    end

    def verify_digest!(chart, archive)
      actual = "sha256:#{Digest::SHA256.file(archive).hexdigest}"
      expected = chart.fetch("digest")
      raise "Helm chart digest mismatch for #{chart.fetch('module')}: expected #{expected}, got #{actual}" unless actual == expected
    end

    def sync_repository(name, pin, source_root, previous_lock)
      destination = @workspace_root.join("modules", name)
      old_pin = previous_lock && previous_lock[REPOSITORIES.fetch(name)]
      if destination.exist?
        expected_tree = old_pin && old_pin["tree_sha256"]
        raise "Refusing to overwrite #{destination}: it is not a verified OPSd-managed module tree" if expected_tree.nil? || tree_digest(destination) != expected_tree
        return if old_pin.fetch("commit") == pin.fetch("commit") && tree_digest(destination) == pin["tree_sha256"]
      end

      archive_root = Pathname(Dir.mktmpdir("opsd-#{name}-archive-"))
      begin
        git!("-C", source_root.to_s, "archive", "--format=tar", "HEAD", "-o", archive_root.join("source.tar").to_s)
        staged = archive_root.join("tree")
        staged.mkpath
        Open3.capture3("tar", "-xf", archive_root.join("source.tar").to_s, "-C", staged.to_s).tap do |_out, err, status|
          raise "Unable to materialize #{name} source: #{err}" unless status.success?
        end
        pin["tree_sha256"] = tree_digest(staged)
        destination.dirname.mkpath
        backup = destination.dirname.join(".#{name}-previous-#{Process.pid}")
        FileUtils.rm_rf(backup)
        FileUtils.mv(destination, backup) if destination.exist?
        FileUtils.mv(staged, destination)
        FileUtils.rm_rf(backup)
      ensure
        FileUtils.rm_rf(archive_root)
      end
    end

    def validate_destinations!(lock, previous_lock)
      REPOSITORIES.each do |name, lock_key|
        destination = @workspace_root.join("modules", name)
        next unless destination.exist?

        old_pin = previous_lock && previous_lock[lock_key]
        expected_tree = old_pin && old_pin["tree_sha256"]
        next if expected_tree && destination.directory? && tree_digest(destination) == expected_tree

        raise "Refusing to overwrite #{destination}: it is not a verified OPSd-managed module tree"
      end
      lock
    end

    def synchronized_trees_intact?(lock)
      REPOSITORIES.all? do |name, key|
        pin = lock[key]
        path = @workspace_root.join("modules", name)
        pin && pin["tree_sha256"] && path.directory? && tree_digest(path) == pin["tree_sha256"]
      end
    end

    def tree_digest(root)
      base = Pathname(root)
      entries = base.glob("**/*", File::FNM_DOTMATCH).select(&:file?).sort
      digest = Digest::SHA256.new
      entries.each do |path|
        relative = path.relative_path_from(base).to_s
        digest.update(relative)
        digest.update("\0")
        digest.update(Digest::SHA256.file(path).digest)
      end
      digest.hexdigest
    end

    def canonicalize(value)
      case value
      when Hash then value.sort.to_h { |key, item| [key, canonicalize(item)] }
      when Array then value.map { |item| canonicalize(item) }
      else value
      end
    end

    def read_lock(path)
      return nil unless path.file?

      lock = YAML.load_file(path)
      raise "Invalid module lock file: #{path}" unless lock.is_a?(Hash)

      lock
    rescue Psych::SyntaxError => e
      raise "YAML syntax error in #{path}: #{e.message}"
    end

    def write_lock(path, lock)
      path.dirname.mkpath
      temporary = path.dirname.join(".#{path.basename}.#{Process.pid}.tmp")
      temporary.write(YAML.dump(lock))
      FileUtils.mv(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def git!(*args)
      stdout, stderr, status = Open3.capture3("git", *args)
      raise "git #{args.join(' ')} failed: #{stderr.empty? ? stdout : stderr}" unless status.success?

      stdout
    end
  end
end
