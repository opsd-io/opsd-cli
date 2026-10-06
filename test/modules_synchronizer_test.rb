# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

require "opsd/modules_synchronizer"

class ModulesSynchronizerTest < Minitest::Test
  def test_sync_pins_and_materializes_both_repositories_idempotently
    Dir.mktmpdir("opsd-modules-sync-test-") do |root|
      workspace = File.join(root, "client")
      provider_repo = File.join(root, "modules-digitalocean")
      kubernetes_repo = File.join(root, "modules-kubernetes")
      create_git_repo(provider_repo, { "blueprints/example.yaml" => "id: example\n" })
      create_git_repo(kubernetes_repo, { "modules/infrastructure/example/module.yaml" => "id: example\n" })
      kubernetes_commit = git_output("-C", kubernetes_repo, "rev-parse", "HEAD").strip
      manifest = File.join(workspace, "opsd.yaml")
      FileUtils.mkdir_p(workspace)
      File.write(manifest, "spec:\n  provider: digitalocean\n")

      provider_commit = git_output("-C", provider_repo, "rev-parse", "HEAD").strip
      catalog = FakeModuleCatalog.new(provider_repo:, provider_commit:)
      env = {
        "OPSD_MODULES_KUBERNETES_REPO" => kubernetes_repo,
        "OPSD_MODULES_KUBERNETES_REF" => kubernetes_commit
      }
      synchronizer = OPSd::ModulesSynchronizer.new(
        workspace_root: workspace,
        cache_root: File.join(workspace, ".opsd", "cache"),
        env:,
        module_catalog: catalog
      )

      lock = synchronizer.sync(manifest_path: manifest)
      assert_equal provider_commit, lock.dig("provider_modules", "commit")
      assert_equal kubernetes_commit, lock.dig("kubernetes_modules", "commit")
      assert File.file?(File.join(workspace, "modules", "digitalocean", "blueprints", "example.yaml"))
      assert File.file?(File.join(workspace, "modules", "kubernetes", "modules", "infrastructure", "example", "module.yaml"))

      prior_lock = File.read(File.join(workspace, "opsd.lock.yaml"))
      synchronizer.sync(manifest_path: manifest)
      assert_equal prior_lock, File.read(File.join(workspace, "opsd.lock.yaml"))
      assert_equal lock, synchronizer.verify(manifest_path: manifest)

      File.write(File.join(workspace, "modules", "digitalocean", "local.tf"), "# client edit\n")
      error = assert_raises(RuntimeError) { synchronizer.sync(manifest_path: manifest, update: true) }
      assert_includes error.message, "local changes"
      tree_error = assert_raises(RuntimeError) { synchronizer.verify(manifest_path: manifest) }
      assert_includes tree_error.message, "do not match opsd.lock.yaml"
    end
  end

  private

  def create_git_repo(path, files)
    FileUtils.mkdir_p(path)
    files.each do |relative, content|
      file = File.join(path, relative)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, content)
    end
    git_output("-C", path, "init", "--quiet")
    git_output("-C", path, "config", "user.name", "OPSd Test")
    git_output("-C", path, "config", "user.email", "opsd@example.test")
    git_output("-C", path, "add", ".")
    git_output("-C", path, "commit", "--quiet", "-m", "test fixture")
  end

  def git_output(*args)
    stdout, stderr, status = Open3.capture3("git", *args)
    raise stderr unless status.success?

    stdout
  end

  class FakeModuleCatalog
    def initialize(provider_repo:, provider_commit:)
      @provider_repo = provider_repo
      @provider_commit = provider_commit
    end

    def resolve(provider)
      { provider:, repo: @provider_repo, version: "fixture", commit: @provider_commit, resolved_at: "2026-01-01T00:00:00Z", workspace_root: Pathname(@provider_repo).parent }
    end

    def lock_data_for(resolution)
      { "provider_modules" => { "provider" => resolution.fetch(:provider), "repo" => resolution.fetch(:repo), "version" => resolution.fetch(:version), "commit" => resolution.fetch(:commit), "resolved_at" => resolution.fetch(:resolved_at) } }
    end
  end
end
