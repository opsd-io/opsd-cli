# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"
require "yaml"
require "minitest/autorun"
require "opsd/module_catalog"

class ModuleCatalogTest < Minitest::Test
  def test_uses_local_workspace_when_provider_modules_are_present
    Dir.mktmpdir("opsd-workspace") do |workspace|
      provider_root = File.join(workspace, "modules", "digitalocean", "blueprints")
      FileUtils.mkdir_p(provider_root)

      catalog = OPSd::ModuleCatalog.new(workspace_root: workspace, cache_root: File.join(workspace, ".cache"))
      resolved = catalog.resolve("digitalocean")

      assert_equal workspace, resolved.fetch(:workspace_root).to_s
      assert_equal "local-workspace", resolved.fetch(:version)
    end
  end

  def test_uses_cached_release_when_only_provider_metadata_is_present_locally
    Dir.mktmpdir("opsd-workspace") do |workspace|
      FileUtils.mkdir_p(File.join(workspace, "modules", "digitalocean"))
      File.write(File.join(workspace, "modules", "digitalocean", "opsd.yaml"), <<~YAML)
        renderer:
          repo: local
          ref: local
        profiles:
          compute:
            droplet:
              - s-1vcpu-1gb
        addons:
          databases:
            - postgres
      YAML

      cached_blueprint_root = File.join(workspace, ".opsd", "cache", "releases", "digitalocean", "main", "modules", "digitalocean", "blueprints")
      FileUtils.mkdir_p(cached_blueprint_root)
      File.write(File.join(cached_blueprint_root, "kubernetes-foundation.yaml"), base_blueprint("Cached Release"))

      catalog = OPSd::ModuleCatalog.new(
        workspace_root: workspace,
        cache_root: File.join(workspace, ".opsd", "cache"),
        env: { "OPSD_MODULES_DIGITALOCEAN_REPO" => File.join(workspace, "unavailable-repository") }
      )
      resolved = catalog.resolve("digitalocean")

      assert_equal "main", resolved.fetch(:version)
      assert_equal File.join(workspace, ".opsd", "cache", "releases", "digitalocean", "main"), resolved.fetch(:workspace_root).to_s
    end
  end

  def test_default_cache_root_is_scoped_to_workspace
    Dir.mktmpdir("opsd-workspace") do |workspace|
      catalog = OPSd::ModuleCatalog.new(workspace_root: workspace)

      assert_equal File.join(workspace, ".opsd", "cache"), catalog.send(:default_cache_root).to_s
    end
  end

  def test_resolve_without_lock_uses_latest_release_tag
    Dir.mktmpdir("opsd-module-catalog") do |root|
      remote_repo = File.join(root, "digitalocean-remote")
      workspace = File.join(root, "workspace")
      cache = File.join(root, "cache")

      create_tagged_remote_repo(remote_repo)
      FileUtils.mkdir_p(workspace)

      catalog = OPSd::ModuleCatalog.new(
        workspace_root: workspace,
        cache_root: cache,
        env: { "OPSD_MODULES_DIGITALOCEAN_REPO" => remote_repo }
      )

      resolved = catalog.resolve("digitalocean")

      assert_equal "v1.1.0", resolved.fetch(:version)
      assert_equal File.join(cache, "releases", "digitalocean", "v1.1.0"), resolved.fetch(:workspace_root).to_s
      assert File.file?(File.join(cache, "releases", "digitalocean", "v1.1.0", "modules", "digitalocean", "blueprints", "kubernetes-foundation.yaml"))
    end
  end

  def test_resolve_without_lock_falls_back_to_cached_release_when_remote_is_unavailable
    Dir.mktmpdir("opsd-module-catalog") do |root|
      workspace = File.join(root, "workspace")
      cache = File.join(root, "cache")
      cached_release = File.join(cache, "releases", "digitalocean", "main", "modules", "digitalocean")

      FileUtils.mkdir_p(File.join(cached_release, "blueprints"))
      File.write(File.join(cached_release, "blueprints", "kubernetes-foundation.yaml"), base_blueprint("Cached Blueprint"))
      File.write(File.join(cached_release, "opsd.yaml"), <<~YAML)
        profiles:
          compute:
            droplet:
              - s-1vcpu-1gb
        addons:
          databases:
            - postgres
      YAML

      catalog = OPSd::ModuleCatalog.new(
        workspace_root: workspace,
        cache_root: cache,
        env: { "OPSD_MODULES_DIGITALOCEAN_REPO" => File.join(root, "missing-remote") }
      )

      resolved = catalog.resolve("digitalocean")

      assert_equal "main", resolved.fetch(:version)
      assert_equal File.join(cache, "releases", "digitalocean", "main"), resolved.fetch(:workspace_root).to_s
      assert_includes File.read(File.join(cached_release, "blueprints", "kubernetes-foundation.yaml")), "Cached Blueprint"
    end
  end

  def test_resolve_with_lock_reuses_pinned_version
    Dir.mktmpdir("opsd-module-catalog") do |root|
      remote_repo = File.join(root, "digitalocean-remote")
      workspace = File.join(root, "workspace")
      cache = File.join(root, "cache")
      lock_path = File.join(root, "opsd.lock.yaml")

      create_tagged_remote_repo(remote_repo)
      FileUtils.mkdir_p(workspace)

      catalog = OPSd::ModuleCatalog.new(
        workspace_root: workspace,
        cache_root: cache,
        env: { "OPSD_MODULES_DIGITALOCEAN_REPO" => remote_repo }
      )

      initial = catalog.resolve("digitalocean")
      older_repo_root = File.join(cache, "releases", "digitalocean", "v1.0.0", "modules", "digitalocean")
      FileUtils.mkdir_p(File.dirname(older_repo_root))
      run!("git", "clone", "--branch", "v1.0.0", "--depth", "1", remote_repo, older_repo_root)
      older_commit = git_output("git", "-C", older_repo_root, "rev-parse", "HEAD").strip

      File.write(lock_path, YAML.dump(
        "provider_modules" => {
          "provider" => "digitalocean",
          "repo" => remote_repo,
          "version" => "v1.0.0",
          "commit" => older_commit
        }
      ))

      pinned = catalog.resolve("digitalocean", lockfile_path: lock_path)

      assert_equal "v1.1.0", initial.fetch(:version)
      assert_equal "v1.0.0", pinned.fetch(:version)
      assert_equal older_commit, pinned.fetch(:commit)
    end
  end

  def test_resolve_with_local_workspace_lock_reuses_local_workspace
    Dir.mktmpdir("opsd-module-catalog") do |root|
      workspace = File.join(root, "workspace")
      provider_root = File.join(workspace, "modules", "digitalocean")
      lock_path = File.join(root, "opsd.lock.yaml")

      FileUtils.mkdir_p(File.join(provider_root, "blueprints"))
      File.write(File.join(provider_root, "blueprints", "kubernetes-foundation.yaml"), base_blueprint("Workspace Blueprint"))

      run!("git", "init", provider_root)
      run!("git", "-C", provider_root, "config", "user.name", "OPSd Test")
      run!("git", "-C", provider_root, "config", "user.email", "opsd@example.com")
      run!("git", "-C", provider_root, "add", ".")
      run!("git", "-C", provider_root, "commit", "-m", "workspace")
      commit = git_output("git", "-C", provider_root, "rev-parse", "HEAD").strip

      File.write(lock_path, YAML.dump(
        "provider_modules" => {
          "provider" => "digitalocean",
          "repo" => "local-workspace",
          "version" => "local-workspace",
          "commit" => commit
        }
      ))

      catalog = OPSd::ModuleCatalog.new(workspace_root: workspace, cache_root: File.join(root, "cache"))
      resolved = catalog.resolve("digitalocean", lockfile_path: lock_path)

      assert_equal workspace, resolved.fetch(:workspace_root).to_s
      assert_includes %w[main master], resolved.fetch(:version)
      assert_equal commit, resolved.fetch(:commit)
    end
  end

  def test_resolve_without_lock_honors_explicit_repo_ref
    Dir.mktmpdir("opsd-module-catalog") do |root|
      remote_repo = File.join(root, "digitalocean-remote")
      workspace = File.join(root, "workspace")
      cache = File.join(root, "cache")

      create_tagged_remote_repo(remote_repo)
      FileUtils.mkdir_p(workspace)
      run!("git", "-C", remote_repo, "branch", "-M", "main")

      File.write(File.join(remote_repo, "blueprints", "kubernetes-foundation.yaml"), base_blueprint("Main Branch Blueprint"))
      run!("git", "-C", remote_repo, "add", ".")
      run!("git", "-C", remote_repo, "commit", "-m", "main branch only")

      catalog = OPSd::ModuleCatalog.new(
        workspace_root: workspace,
        cache_root: cache,
        env: {
          "OPSD_MODULES_DIGITALOCEAN_REPO" => remote_repo,
          "OPSD_MODULES_DIGITALOCEAN_REF" => "main"
        }
      )

      resolved = catalog.resolve("digitalocean")

      assert_equal "main", resolved.fetch(:version)
      assert_equal File.join(cache, "releases", "digitalocean", "main"), resolved.fetch(:workspace_root).to_s
      assert_includes File.read(File.join(cache, "releases", "digitalocean", "main", "modules", "digitalocean", "blueprints", "kubernetes-foundation.yaml")), "Main Branch Blueprint"
    end
  end

  def test_resolve_without_tags_falls_back_to_main_branch
    Dir.mktmpdir("opsd-module-catalog") do |root|
      remote_repo = File.join(root, "digitalocean-remote")
      workspace = File.join(root, "workspace")
      cache = File.join(root, "cache")

      create_untagged_remote_repo(remote_repo)
      FileUtils.mkdir_p(workspace)

      catalog = OPSd::ModuleCatalog.new(
        workspace_root: workspace,
        cache_root: cache,
        env: { "OPSD_MODULES_DIGITALOCEAN_REPO" => remote_repo }
      )

      resolved = catalog.resolve("digitalocean")

      assert_equal "main", resolved.fetch(:version)
      assert_equal File.join(cache, "releases", "digitalocean", "main"), resolved.fetch(:workspace_root).to_s
      assert_includes File.read(File.join(cache, "releases", "digitalocean", "main", "modules", "digitalocean", "blueprints", "kubernetes-foundation.yaml")), "Main Only Blueprint"
    end
  end

  private

  def create_tagged_remote_repo(path)
    FileUtils.mkdir_p(File.join(path, "blueprints"))
    File.write(File.join(path, "blueprints", "kubernetes-foundation.yaml"), base_blueprint("Managed Runtime"))

    run!("git", "init", path)
    run!("git", "-C", path, "config", "user.name", "OPSd Test")
    run!("git", "-C", path, "config", "user.email", "opsd@example.com")
    run!("git", "-C", path, "add", ".")
    run!("git", "-C", path, "commit", "-m", "v1.0.0")
    run!("git", "-C", path, "tag", "v1.0.0")

    File.write(File.join(path, "blueprints", "kubernetes-foundation.yaml"), base_blueprint("Managed Runtime Updated"))
    run!("git", "-C", path, "add", ".")
    run!("git", "-C", path, "commit", "-m", "v1.1.0")
    run!("git", "-C", path, "tag", "v1.1.0")
  end

  def base_blueprint(title)
    <<~YAML
      id: kubernetes-foundation
      title: Backend API
      variants:
        - id: managed
          title: #{title}
    YAML
  end

  def create_untagged_remote_repo(path)
    FileUtils.mkdir_p(File.join(path, "blueprints"))
    File.write(File.join(path, "blueprints", "kubernetes-foundation.yaml"), base_blueprint("Main Only Blueprint"))

    run!("git", "init", path)
    run!("git", "-C", path, "config", "user.name", "OPSd Test")
    run!("git", "-C", path, "config", "user.email", "opsd@example.com")
    run!("git", "-C", path, "add", ".")
    run!("git", "-C", path, "commit", "-m", "initial main")
    run!("git", "-C", path, "branch", "-M", "main")
  end

  def git_output(*command)
    `#{command.map { |part| Shellwords.escape(part) }.join(" ")}`
  end

  def run!(*command)
    success = system(*command, out: File::NULL, err: File::NULL)
    return if success

    raise "Command failed: #{command.join(' ')}"
  end
end
