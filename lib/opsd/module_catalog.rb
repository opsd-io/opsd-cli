# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "rubygems"
require "time"
require "yaml"

require_relative "version"
require_relative "contract_store"

module OPSd
  class ModuleCatalog
    DEFAULT_REPOS = {
      "digitalocean" => "https://github.com/opsd-io/modules-digitalocean.git"
    }.freeze

    def initialize(workspace_root:, cache_root: nil, env: ENV, contract_store: nil)
      @workspace_root = Pathname(workspace_root).expand_path
      @env = env
      @cache_root = Pathname(cache_root || default_cache_root).expand_path
      @contract_store = contract_store
    end

    def workspace_root_for(provider)
      resolve(provider)[:workspace_root]
    end

    def provider_supported?(provider)
      return false unless supported_provider_names.include?(provider.to_s)

      provider_status(provider) != "placeholder"
    end

    def supported_provider_names
      names = if @contract_store
                @contract_store.provider_names
              else
                DEFAULT_REPOS.keys
              end

      names.sort
    end

    def resolve(provider, lockfile_path: nil)
      raise "Provider #{provider} is not supported yet." unless provider_supported?(provider)

      locked = load_lock(lockfile_path, provider)
      unless locked.nil?
        if local_workspace_lock?(locked)
          return resolve_local_workspace(
            provider,
            expected_commit: locked.fetch("commit"),
            expected_repo: locked.fetch("repo"),
            expected_version: locked.fetch("version")
          )
        end

        return resolve_remote_release(provider, repo_url: locked.fetch("repo"), version: locked.fetch("version"), expected_commit: locked.fetch("commit"))
      end

      return resolve_local_workspace(provider) if local_provider_root(provider).join("blueprints").directory?

      repo_url = repo_url_for(provider)
      requested_ref = repo_ref_for(provider)

      if repo_url
        version = requested_ref.nil? || requested_ref.empty? ? default_remote_ref(repo_url) : requested_ref
        return resolve_remote_release(provider, repo_url: repo_url, version: version)
      end

      resolve_cached_release(provider, requested_ref: requested_ref) || raise("Provider #{provider} is not supported yet.")
    rescue StandardError => e
      cached = resolve_cached_release(provider, requested_ref: requested_ref)
      return cached unless cached.nil?

      raise e
    end

    def repo_url_for(provider)
      @env["OPSD_MODULES_#{provider.upcase}_REPO"] || DEFAULT_REPOS[provider]
    end

    def repo_ref_for(provider)
      @env["OPSD_MODULES_#{provider.upcase}_REF"]
    end

    def lock_data_for(resolution)
      {
        "provider_modules" => {
          "provider" => resolution.fetch(:provider),
          "repo" => resolution.fetch(:repo),
          "version" => resolution.fetch(:version),
          "commit" => resolution.fetch(:commit),
          "resolved_at" => resolution.fetch(:resolved_at)
        },
        "opsd_cli" => {
          "version" => OPSd::VERSION
        }
      }
    end

    def write_lock(path, resolution)
      lock_path = Pathname(path)
      lock_path.dirname.mkpath
      lock_path.write(YAML.dump(lock_data_for(resolution)))
    end

  private

    def provider_status(provider)
      return "reference" unless @contract_store

      @contract_store.provider_status(provider) || "reference"
    end

    def resolve_local_workspace(provider, expected_commit: nil, expected_repo: nil, expected_version: nil)
      provider_root = local_provider_root(provider)
      raise "Locked local workspace modules not found for provider=#{provider} at #{provider_root}" unless provider_root.directory?

      repo = normalize_repo_url(try_git(%W[-C #{provider_root} remote get-url origin]).to_s.strip)
      repo = "local-workspace" if repo.empty?

      version = try_git(%W[-C #{provider_root} describe --tags --exact-match]).to_s.strip
      version = try_git(%W[-C #{provider_root} symbolic-ref --short HEAD]).to_s.strip if version.empty?
      version = "local-workspace" if version.empty?

      commit = try_git(%W[-C #{provider_root} rev-parse HEAD]).to_s.strip
      commit = "unknown" if commit.empty?

      normalized_expected_repo = normalize_repo_url(expected_repo)

      if expected_repo && normalized_expected_repo != "local-workspace" && normalized_expected_repo != repo
        raise "Locked module repo mismatch for provider=#{provider}. Expected #{expected_repo}, got #{repo}."
      end

      if expected_version && expected_version != "local-workspace" && expected_version != version
        raise "Locked module version mismatch for provider=#{provider}. Expected #{expected_version}, got #{version}."
      end

      if expected_commit && expected_commit != "unknown" && commit != "unknown" && expected_commit != commit
        raise "Locked module commit mismatch for provider=#{provider}. Expected #{expected_commit}, got #{commit}."
      end

      {
        provider: provider,
        repo: repo,
        version: version,
        commit: commit,
        resolved_at: Time.now.utc.iso8601,
        workspace_root: @workspace_root
      }
    end

    def resolve_remote_release(provider, repo_url:, version:, expected_commit: nil)
      workspace_root = release_workspace_root(provider, version)
      repo_root = workspace_root.join("modules", provider)

      sync_remote_release!(provider, repo_url, version, repo_root)
      commit = run_git!(%W[-C #{repo_root} rev-parse HEAD]).strip

      if expected_commit && commit != expected_commit
        raise "Locked module commit mismatch for provider=#{provider}. Expected #{expected_commit}, got #{commit}."
      end

      {
        provider: provider,
        repo: normalize_repo_url(repo_url),
        version: version,
        commit: commit,
        resolved_at: Time.now.utc.iso8601,
        workspace_root: workspace_root
      }
    end

    def sync_remote_release!(provider, repo_url, version, repo_root)
      return if repo_root.directory?

      modules_root = repo_root.dirname
      FileUtils.mkdir_p(modules_root)

      temp_root = modules_root.join(".#{provider}-#{sanitize_ref(version)}-#{Process.pid}-#{Time.now.to_i}")
      FileUtils.rm_rf(temp_root)

      begin
        if version.match?(/\A[0-9a-f]{40}\z/i)
          run_git!(["clone", "--no-checkout", "--depth", "1", repo_url, temp_root.to_s])
          run_git!(["-C", temp_root.to_s, "fetch", "--depth", "1", "origin", version])
          run_git!(["-C", temp_root.to_s, "checkout", "--detach", "FETCH_HEAD"])
        else
          run_git!(["clone", "--branch", version, "--depth", "1", repo_url, temp_root.to_s])
        end
        FileUtils.mv(temp_root, repo_root)
      ensure
        FileUtils.rm_rf(temp_root)
      end
    end

    def default_remote_ref(repo_url)
      latest_release_version(repo_url) || default_branch(repo_url)
    end

    def latest_release_version(repo_url)
      tags = run_git!(["ls-remote", "--tags", "--refs", repo_url]).lines.filter_map do |line|
        _sha, ref = line.strip.split(/\s+/, 2)
        next nil if ref.nil?

        ref.delete_prefix("refs/tags/")
      end

      return nil if tags.empty?

      semver_tags = tags.filter_map do |tag|
        normalized = tag.delete_prefix("v")
        next nil unless normalized.match?(/\A\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.-]+)?\z/)

        [Gem::Version.new(normalized), tag]
      end

      return semver_tags.max_by(&:first).last unless semver_tags.empty?

      tags.sort.last
    end

    def default_branch(repo_url)
      ref = run_git!(["ls-remote", "--symref", repo_url, "HEAD"]).lines.find do |line|
        line.start_with?("ref:")
      end

      branch = ref&.split&.[](1)&.delete_prefix("refs/heads/")
      return branch unless branch.nil? || branch.empty?

      "main"
    rescue StandardError
      "main"
    end

    def load_lock(lockfile_path, provider)
      return nil if lockfile_path.nil?

      path = Pathname(lockfile_path)
      return nil unless path.file?

      data = YAML.load_file(path)
      raise "Invalid module lock file: #{path}" unless data.is_a?(Hash)

      provider_modules = data["provider_modules"]
      raise "Invalid module lock file: #{path}" unless provider_modules.is_a?(Hash)
      return nil unless provider_modules["provider"] == provider

      %w[repo version commit].each do |key|
        value = provider_modules[key]
        raise "Invalid module lock file: missing provider_modules.#{key} in #{path}" if value.nil? || value.to_s.empty?
      end

      provider_modules
    rescue Psych::SyntaxError => e
      raise "YAML syntax error in #{path}: #{e.message}"
    end

    def local_workspace_lock?(provider_modules)
      provider_modules["repo"] == "local-workspace" || provider_modules["version"] == "local-workspace"
    end

    def local_provider_root(provider)
      @workspace_root.join("modules", provider)
    end

    def release_workspace_root(provider, version)
      @cache_root.join("releases", provider, sanitize_ref(version))
    end

    def resolve_cached_release(provider, requested_ref: nil)
      version = cached_release_version(provider, requested_ref: requested_ref)
      return nil if version.nil?

      workspace_root = release_workspace_root(provider, version)
      repo_root = workspace_root.join("modules", provider)
      return nil unless repo_root.directory?

      repo = normalize_repo_url(try_git(%W[-C #{repo_root} remote get-url origin]).to_s.strip)
      repo = normalize_repo_url(repo_url_for(provider).to_s.strip) if repo.empty?
      repo = "cached-release" if repo.empty?

      commit = try_git(%W[-C #{repo_root} rev-parse HEAD]).to_s.strip
      commit = "unknown" if commit.empty?

      {
        provider: provider,
        repo: repo,
        version: version,
        commit: commit,
        resolved_at: Time.now.utc.iso8601,
        workspace_root: workspace_root
      }
    end

    def cached_release_version(provider, requested_ref: nil)
      versions = cached_release_versions(provider)
      return nil if versions.empty?

      return requested_ref if !requested_ref.nil? && !requested_ref.empty? && versions.include?(requested_ref)
      return "main" if versions.include?("main")

      versions.sort.last
    end

    def cached_release_versions(provider)
      releases_root = @cache_root.join("releases", provider)
      return [] unless releases_root.directory?

      releases_root.children.select(&:directory?).map(&:basename).map(&:to_s)
    end

    def sanitize_ref(ref)
      ref.gsub(/[^A-Za-z0-9._-]+/, "-")
    end

    def normalize_repo_url(repo)
      repo = repo.to_s
      return repo if repo.empty?

      repo.sub(/\Agit@gitlab\.com:/, "https://gitlab.com/")
    end

    def run_git!(args)
      stdout, stderr, status = Open3.capture3("git", *args)
      return stdout if status.success?

      message = stderr.to_s.strip
      message = stdout.to_s.strip if message.empty?
      raise "Failed to sync provider modules: #{message}"
    rescue Errno::ENOENT
      raise "Failed to sync provider modules: git is not installed or not available in PATH"
    end

    def try_git(args)
      stdout, _stderr, status = Open3.capture3("git", *args)
      return stdout if status.success?

      nil
    rescue Errno::ENOENT
      nil
    end

    def default_cache_root
      @workspace_root.join(".opsd", "cache")
    end
  end
end
