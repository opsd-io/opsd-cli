# frozen_string_literal: true

require "digest"
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "opsd/cli"

class KubernetesBootstrapTest < Minitest::Test
  class FakeBootstrap < OPSd::KubernetesBootstrap
    Status = Struct.new(:success) do
      def success?
        success
      end
    end

    attr_reader :commands, :stdin_payloads

    def initialize(repository:, chart_content:, stdout: StringIO.new, env: {})
      super(stdout: stdout, env: env)
      @repository = repository
      @chart_content = chart_content
      @commands = []
      @stdin_payloads = []
    end

    private

    def ensure_dependencies!
      nil
    end

    def capture(*command, stdin_data: nil)
      @commands << command
      @stdin_payloads << stdin_data unless stdin_data.nil?

      case command
      when ["kubectl", "config", "current-context"]
        ["demo-cluster\n", "", Status.new(true)]
      when ["kubectl", "get", "nodes", "--output=name", "--request-timeout=5s"]
        ["node/demo\n", "", Status.new(true)]
      when ->(args) { args.first(2) == %w[kubectl wait] }
        ["", "", Status.new(true)]
      else
        capture_repository_or_chart(command)
      end
    end

    def capture_repository_or_chart(command)
      if command.first == "git"
        destination = command.last
        FileUtils.mkdir_p(destination)
        FileUtils.cp_r(File.join(@repository, "."), destination)
        ["", "", Status.new(true)]
      elsif command.first == "helm" && command[1] == "pull"
        destination = command[command.index("--destination") + 1]
        File.write(File.join(destination, "argo-cd-10.9.6.tgz"), @chart_content)
        ["", "", Status.new(true)]
      else
        ["", "", Status.new(true)]
      end
    end
  end

  def test_bootstraps_from_the_module_and_can_be_repeated
    Dir.mktmpdir("opsd-bootstrap-test-") do |directory|
      chart_content = "fake pinned chart archive"
      repository = write_module_repository(directory, chart_content: chart_content)
      bootstrap = FakeBootstrap.new(repository: repository, chart_content: chart_content)

      2.times { bootstrap.run }

      assert_equal 2, bootstrap.commands.count { |command| command.first(2) == %w[helm upgrade] }
      install_commands = bootstrap.commands.select { |command| command.first(2) == %w[helm upgrade] }
      assert install_commands.all? { |command| command.include?("--install") }
      assert install_commands.all? { |command| command.include?("--namespace") && command[command.index("--namespace") + 1] == "argocd" }
      assert_equal 2, bootstrap.commands.count { |command| command[0..2] == %w[kubectl wait --for=condition=Ready] }
      refute bootstrap.commands.any? { |command| command[0..1] == %w[kubectl apply] }
    end
  end

  def test_creates_https_repository_secret_from_environment_without_putting_credentials_in_arguments
    Dir.mktmpdir("opsd-bootstrap-test-") do |directory|
      repository = write_module_repository(directory, chart_content: "fake pinned chart archive")
      stdout = StringIO.new
      bootstrap = FakeBootstrap.new(
        repository: repository,
        chart_content: "fake pinned chart archive",
        stdout: stdout,
        env: {
          "OPSD_ARGOCD_REPO_USERNAME" => "x-access-token",
          "OPSD_ARGOCD_REPO_PASSWORD" => "private-token-value"
        }
      )

      bootstrap.run(gitops_repository: { "repository_url" => "https://github.com/acme/platform.git" })

      secret_command = bootstrap.commands.find { |command| command[0..1] == %w[kubectl apply] }
      assert_equal %w[kubectl apply --namespace argocd --filename -], secret_command
      secret = YAML.safe_load(bootstrap.stdin_payloads.fetch(0))
      assert_equal "Secret", secret.fetch("kind")
      assert_equal "repository", secret.dig("metadata", "labels", "argocd.argoproj.io/secret-type")
      assert_equal "https://github.com/acme/platform.git", secret.dig("stringData", "url")
      assert_equal "x-access-token", secret.dig("stringData", "username")
      assert_equal "private-token-value", secret.dig("stringData", "password")
      refute_includes bootstrap.commands.flatten.join(" "), "private-token-value"
      refute_includes stdout.string, "private-token-value"
    end
  end

  def test_creates_ssh_repository_secret
    Dir.mktmpdir("opsd-bootstrap-test-") do |directory|
      repository = write_module_repository(directory, chart_content: "fake pinned chart archive")
      private_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nprivate-key-value\n-----END OPENSSH PRIVATE KEY-----\n"
      bootstrap = FakeBootstrap.new(
        repository: repository,
        chart_content: "fake pinned chart archive",
        env: { "OPSD_ARGOCD_REPO_SSH_PRIVATE_KEY" => private_key }
      )

      bootstrap.run(gitops_repository: { "repository_url" => "ssh://git@github.com/acme/platform.git" })

      secret = YAML.safe_load(bootstrap.stdin_payloads.fetch(0))
      assert_equal private_key, secret.dig("stringData", "sshPrivateKey")
      refute secret.dig("stringData").key?("password")
    end
  end

  def test_rejects_mismatched_repository_credentials_before_cluster_operations
    Dir.mktmpdir("opsd-bootstrap-test-") do |directory|
      repository = write_module_repository(directory, chart_content: "fake pinned chart archive")
      bootstrap = FakeBootstrap.new(
        repository: repository,
        chart_content: "fake pinned chart archive",
        env: { "OPSD_ARGOCD_REPO_SSH_PRIVATE_KEY" => "private-key-value" }
      )

      error = assert_raises(RuntimeError) do
        bootstrap.run(gitops_repository: { "repository_url" => "https://github.com/acme/platform.git" })
      end

      assert_includes error.message, "requires an ssh:// repository URL"
      assert_empty bootstrap.commands
    end
  end

  def test_requires_a_gitops_manifest_when_credentials_are_configured
    Dir.mktmpdir("opsd-bootstrap-test-") do |directory|
      repository = write_module_repository(directory, chart_content: "fake pinned chart archive")
      bootstrap = FakeBootstrap.new(
        repository: repository,
        chart_content: "fake pinned chart archive",
        env: {
          "OPSD_ARGOCD_REPO_USERNAME" => "x-access-token",
          "OPSD_ARGOCD_REPO_PASSWORD" => "private-token-value"
        }
      )

      error = assert_raises(RuntimeError) { bootstrap.run }

      assert_includes error.message, "Pass --manifest with a GitOps repository"
      assert_empty bootstrap.commands
    end
  end

  def test_rejects_chart_when_its_digest_does_not_match_module_metadata
    Dir.mktmpdir("opsd-bootstrap-test-") do |directory|
      repository = write_module_repository(directory, chart_content: "pinned content", digest_content: "different content")
      bootstrap = FakeBootstrap.new(repository: repository, chart_content: "pinned content")

      error = assert_raises(RuntimeError) { bootstrap.run }

      assert_includes error.message, "Argo CD chart digest mismatch"
      refute bootstrap.commands.any? { |command| command.first == "kubectl" }
    end
  end

  def test_bootstrap_help_is_available_without_cluster_dependencies
    stdout, = capture_io { OPSd::CLI.new(["bootstrap", "--help"]).run }

    assert_includes stdout, "Usage: opsd bootstrap"
    assert_includes stdout, "Requires kubectl, Helm and Git"
    assert_includes stdout, "OPSD_ARGOCD_REPO_USERNAME"
    assert_includes stdout, "OPSD_ARGOCD_REPO_SSH_PRIVATE_KEY"
  end

  def test_bootstrap_reads_gitops_repository_from_manifest
    manifest_path = File.expand_path("../examples/kubernetes-environment.yaml", __dir__)
    manifest = OPSd::Manifest.new(YAML.load_file(manifest_path))
    captured_repositories = []
    bootstrap = Object.new
    bootstrap.define_singleton_method(:run) do |gitops_repository:|
      captured_repositories << gitops_repository
    end

    OPSd::KubernetesBootstrap.stub(:new, bootstrap) do
      capture_io { OPSd::CLI.new(["bootstrap", "--manifest", manifest_path]).run }
    end

    assert_equal manifest.gitops_repository, captured_repositories.fetch(0)
  end

  private

  def write_module_repository(directory, chart_content:, digest_content: chart_content)
    repository = File.join(directory, "modules-kubernetes")
    module_directory = File.join(repository, "modules", "bootstrap", "argocd")
    FileUtils.mkdir_p(module_directory)
    File.write(File.join(module_directory, "module.yaml"), module_metadata(digest_content))
    File.write(File.join(module_directory, "values.yaml"), "server:\n  service:\n    type: ClusterIP\n")
    File.write(File.join(module_directory, "values.schema.json"), "{}\n")
    repository
  end

  def module_metadata(digest_content)
    <<~YAML
      apiVersion: opsd.io/modules/v1alpha1
      kind: KubernetesModule
      metadata:
        id: argocd
        name: Argo CD
        description: Argo CD bootstrap module
      spec:
        layer: bootstrap
        source:
          type: helm
          repository: https://example.invalid/charts
          chart: argo-cd
          version: 10.9.6
          digest: sha256:#{Digest::SHA256.hexdigest(digest_content)}
        defaults: values.yaml
        schema: values.schema.json
        ownership:
          type: official
          repository: opsd-io/modules-kubernetes
        supported_providers:
          - digitalocean
        validation:
          mode: strict
    YAML
  end
end
