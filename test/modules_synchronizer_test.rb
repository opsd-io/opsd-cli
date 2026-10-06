# frozen_string_literal: true

require "fileutils"
require "digest"
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

require "opsd/modules_synchronizer"

class ModulesSynchronizerTest < Minitest::Test
  def test_sync_pins_repositories_and_helm_artifacts_idempotently
    Dir.mktmpdir("opsd-modules-sync-test-") do |root|
      workspace = File.join(root, "client")
      provider_repo = File.join(root, "modules-digitalocean")
      kubernetes_repo = File.join(root, "modules-kubernetes")
      chart_digest = "sha256:#{Digest::SHA256.hexdigest('test-chart')}"
      create_git_repo(provider_repo, { "blueprints/example.yaml" => "id: example\n" })
      create_git_repo(kubernetes_repo, {
        "modules/infrastructure/example/module.yaml" => helm_module(chart_digest),
        "modules/infrastructure/example/defaults.yaml" => "replicaCount: 1\n",
        "modules/infrastructure/example/schema.yaml" => "type: object\n"
      })
      kubernetes_commit = git_output("-C", kubernetes_repo, "rev-parse", "HEAD").strip
      manifest = File.join(workspace, "opsd.yaml")
      FileUtils.mkdir_p(workspace)
      File.write(manifest, "spec:\n  provider: digitalocean\n")

      fake_bin = File.join(root, "bin")
      FileUtils.mkdir_p(fake_bin)
      helm = File.join(fake_bin, "helm")
      File.write(helm, <<~'RUBY')
        #!/usr/bin/env ruby
        args = ARGV
        destination = args[args.index("--destination") + 1]
        chart = args.find { |arg| arg == "example" }
        version = args[args.index("--version") + 1]
        File.write(File.join(destination, "#{chart}-#{version}.tgz"), "test-chart")
      RUBY
      FileUtils.chmod("u+x", helm)

      provider_commit = git_output("-C", provider_repo, "rev-parse", "HEAD").strip
      catalog = FakeModuleCatalog.new(provider_repo:, provider_commit:)
      env = {
        "PATH" => "#{fake_bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}",
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
      assert_equal chart_digest, lock.dig("helm_charts", 0, "digest")
      assert File.file?(File.join(workspace, "modules", "digitalocean", "blueprints", "example.yaml"))
      assert File.file?(File.join(workspace, "modules", "kubernetes", "modules", "infrastructure", "example", "module.yaml"))
      assert File.file?(File.join(workspace, ".opsd", "cache", "helm", "#{chart_digest.delete_prefix('sha256:')}.tgz"))

      prior_lock = File.read(File.join(workspace, "opsd.lock.yaml"))
      synchronizer.sync(manifest_path: manifest)
      assert_equal prior_lock, File.read(File.join(workspace, "opsd.lock.yaml"))
      assert_equal lock, synchronizer.verify(manifest_path: manifest)

      chart_archive = File.join(workspace, ".opsd", "cache", "helm", "#{chart_digest.delete_prefix('sha256:')}.tgz")
      File.write(chart_archive, "tampered-chart")
      chart_error = assert_raises(RuntimeError) { synchronizer.verify(manifest_path: manifest) }
      assert_includes chart_error.message, "Helm chart digest mismatch"
      File.write(chart_archive, "test-chart")

      File.write(File.join(workspace, "modules", "digitalocean", "local.tf"), "# client edit\n")
      error = assert_raises(RuntimeError) { synchronizer.sync(manifest_path: manifest, update: true) }
      assert_includes error.message, "local changes"
      tree_error = assert_raises(RuntimeError) { synchronizer.verify(manifest_path: manifest) }
      assert_includes tree_error.message, "do not match opsd.lock.yaml"
    end
  end

  private

  def helm_module(digest)
    <<~YAML
      apiVersion: opsd.io/modules/v1alpha1
      kind: KubernetesModule
      metadata:
        id: example
        name: Example
        description: Test Helm module
      spec:
        layer: infrastructure
        source:
          type: helm
          repository: https://example.test/charts
          chart: example
          version: 1.2.3
          digest: #{digest}
        defaults: defaults.yaml
        schema: schema.yaml
        ownership:
          type: official
          repository: opsd-io/modules-kubernetes
        supported_providers: [digitalocean]
        validation:
          mode: strict
    YAML
  end

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
