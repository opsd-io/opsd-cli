# frozen_string_literal: true

require "digest"
require "open3"
require "pathname"
require "tmpdir"
require "uri"
require "yaml"

require_relative "kubernetes_module"

module OPSd
  class KubernetesBootstrap
    MODULES_KUBERNETES_REPOSITORY = "https://github.com/opsd-io/modules-kubernetes.git"
    ARGOCD_MODULE_PATH = "modules/bootstrap/argocd/module.yaml"
    ARGOCD_MODULE_ID = "argocd"
    ARGOCD_NAMESPACE = "argocd"
    CLUSTER_TIMEOUT_SECONDS = 600
    POLL_INTERVAL_SECONDS = 5
    GITOPS_CREDENTIAL_ENV_KEYS = %w[
      OPSD_ARGOCD_REPO_USERNAME
      OPSD_ARGOCD_REPO_PASSWORD
      OPSD_ARGOCD_REPO_SSH_PRIVATE_KEY
    ].freeze

    def initialize(stdout: $stdout, env: ENV)
      @stdout = stdout
      @env = env
    end

    def run(gitops_repository: nil)
      repository_secret = build_gitops_repository_secret(gitops_repository)
      ensure_dependencies!
      Dir.mktmpdir("opsd-bootstrap-") do |directory|
        @stdout.puts "Resolving the Argo CD module from modules-kubernetes..."
        archive, defaults_path = prepare_argocd(directory)

        context = current_context
        @stdout.puts "Using Kubernetes context: #{context}"
        @stdout.puts "Waiting for Kubernetes nodes to become Ready..."
        wait_for_cluster(context)

        @stdout.puts "Installing Argo CD chart..."
        install_chart(archive, defaults_path)
        apply_gitops_repository_secret(repository_secret) if repository_secret
        @stdout.puts "Argo CD is ready in namespace #{ARGOCD_NAMESPACE}."
      end
    end

    private

    def ensure_dependencies!
      missing = %w[kubectl helm git].reject do |executable|
        @env.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
          path = directory.empty? ? executable : File.join(directory, executable)
          File.executable?(path)
        end
      end
      return if missing.empty?

      raise "opsd bootstrap requires #{missing.join(', ')} to be installed and available in PATH."
    end

    def current_context
      stdout, stderr, status = capture("kubectl", "config", "current-context")
      raise command_error("Unable to read the current Kubernetes context", stdout, stderr) unless status.success?

      context = stdout.strip
      raise "No Kubernetes context is selected. Configure kubectl before running opsd bootstrap." if context.empty?

      context
    end

    def wait_for_cluster(context)
      deadline = monotonic_time + CLUSTER_TIMEOUT_SECONDS
      last_error = "The Kubernetes API is not reachable yet."

      loop do
        stdout, stderr, status = capture(
          "kubectl", "get", "nodes", "--output=name", "--request-timeout=5s"
        )

        if status.success? && !stdout.strip.empty?
          remaining = (deadline - monotonic_time).ceil
          raise timeout_error(last_error) unless remaining.positive?

          wait_stdout, wait_stderr, wait_status = capture(
            "kubectl", "wait", "--for=condition=Ready", "--all", "nodes", "--timeout=#{remaining}s"
          )
          raise command_error("Kubernetes nodes did not become Ready", wait_stdout, wait_stderr) unless wait_status.success?

          return
        end

        last_error = if status.success?
                       "The Kubernetes API is reachable, but no nodes are registered yet."
                     else
                       stderr.strip
                     end

        if !status.success? && non_retryable_kubectl_error?(last_error)
          raise "Unable to use Kubernetes context '#{context}': #{last_error}"
        end

        remaining = deadline - monotonic_time
        raise timeout_error(last_error) unless remaining.positive?

        sleep([POLL_INTERVAL_SECONDS, remaining].min)
      end
    end

    def prepare_argocd(directory)
      module_root = File.join(directory, "modules-kubernetes")
      clone_modules_repository(module_root)

      module_path = File.join(module_root, ARGOCD_MODULE_PATH)
      kubernetes_module = KubernetesModule.load(module_path)
      begin
        kubernetes_module.validate!
      rescue KubernetesModule::ValidationError => e
        raise "Invalid Argo CD module metadata: #{e.errors.join('; ')}"
      end

      metadata = kubernetes_module.data.fetch("metadata")
      spec = kubernetes_module.data.fetch("spec")
      unless metadata.fetch("id") == ARGOCD_MODULE_ID && spec.fetch("layer") == "bootstrap"
        raise "Expected #{ARGOCD_MODULE_ID} to be a bootstrap module in #{module_path}."
      end

      source = spec.fetch("source")
      raise "The Argo CD bootstrap module must use a Helm source." unless source.fetch("type") == "helm"

      defaults_path = resolve_module_file(module_root, File.join(File.dirname(ARGOCD_MODULE_PATH), spec.fetch("defaults")))
      resolve_module_file(module_root, File.join(File.dirname(ARGOCD_MODULE_PATH), spec.fetch("schema")))

      archive = pull_chart(source, directory)
      verify_chart_digest!(source, archive)
      [archive, defaults_path]
    end

    def clone_modules_repository(destination)
      repository = @env.fetch("OPSD_MODULES_KUBERNETES_REPO", MODULES_KUBERNETES_REPOSITORY)
      ref = @env.fetch("OPSD_MODULES_KUBERNETES_REF", "main")
      raise "OPSD_MODULES_KUBERNETES_REF cannot be empty." if ref.strip.empty?

      if ref.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)
        _stdout, stderr, status = capture("git", "clone", "--no-checkout", "--depth", "1", repository, destination)
        raise command_error("Unable to clone modules-kubernetes", _stdout, stderr) unless status.success?

        _stdout, stderr, status = capture("git", "-C", destination, "fetch", "--depth", "1", "origin", ref)
        raise command_error("Unable to fetch modules-kubernetes ref #{ref}", _stdout, stderr) unless status.success?

        _stdout, stderr, status = capture("git", "-C", destination, "checkout", "--detach", "FETCH_HEAD")
        raise command_error("Unable to check out modules-kubernetes ref #{ref}", _stdout, stderr) unless status.success?
      else
        _stdout, stderr, status = capture("git", "clone", "--depth", "1", "--branch", ref, repository, destination)
        raise command_error("Unable to clone modules-kubernetes ref #{ref}", _stdout, stderr) unless status.success?
      end
    end

    def resolve_module_file(root, relative_path)
      relative = Pathname(relative_path)
      raise "Invalid path in Argo CD module metadata: #{relative_path}" if relative.absolute? || relative.each_filename.include?("..")

      root_path = Pathname(root).realpath
      path = root_path.join(relative).realpath
      raise "Invalid path in Argo CD module metadata: #{relative_path}" unless path.to_s.start_with?("#{root_path}/")
      raise "Argo CD module file not found: #{relative_path}" unless path.file?

      path.to_s
    rescue Errno::ENOENT
      raise "Argo CD module file not found: #{relative_path}"
    end

    def pull_chart(source, destination)
      chart = source.fetch("chart")
      version = source.fetch("version")
      _stdout, stderr, status = capture(
        "helm", "pull", chart,
        "--repo", source.fetch("repository"),
        "--version", version,
        "--destination", destination
      )
      raise command_error("Unable to download Argo CD chart #{chart} #{version}", _stdout, stderr) unless status.success?

      File.join(destination, "#{chart}-#{version}.tgz")
    end

    def verify_chart_digest!(source, archive)
      actual = "sha256:#{Digest::SHA256.file(archive).hexdigest}"
      expected = source.fetch("digest")
      return if actual == expected

      raise "Argo CD chart digest mismatch: expected #{expected}, got #{actual}."
    end

    def install_chart(archive, defaults_path)
      command = [
        "helm", "upgrade", "--install", ARGOCD_MODULE_ID, archive,
        "--namespace", ARGOCD_NAMESPACE,
        "--create-namespace",
        "--wait",
        "--timeout", "10m",
        "--values", defaults_path
      ]
      stdout, stderr, status = capture(*command)
      raise command_error("Argo CD installation failed", stdout, stderr) unless status.success?

      @stdout.print(stdout) unless stdout.empty?
    end

    def build_gitops_repository_secret(repository)
      credential_values = %w[
        OPSD_ARGOCD_REPO_USERNAME
        OPSD_ARGOCD_REPO_PASSWORD
        OPSD_ARGOCD_REPO_SSH_PRIVATE_KEY
      ].to_h { |name| [name, @env[name]] }
      username = credential_values.fetch("OPSD_ARGOCD_REPO_USERNAME")
      password = credential_values.fetch("OPSD_ARGOCD_REPO_PASSWORD")
      private_key = credential_values.fetch("OPSD_ARGOCD_REPO_SSH_PRIVATE_KEY")
      username = nil if username&.empty?
      password = nil if password&.empty?
      private_key = nil if private_key&.strip&.empty?

      if repository.nil?
        raise "Pass --manifest with a GitOps repository when Argo CD repository credentials are set." if [username, password, private_key].any?

        return nil
      end

      if username.nil? != password.nil?
        raise "Set both OPSD_ARGOCD_REPO_USERNAME and OPSD_ARGOCD_REPO_PASSWORD for HTTPS Git authentication."
      end
      if private_key && (username || password)
        raise "Choose either HTTPS Git credentials or OPSD_ARGOCD_REPO_SSH_PRIVATE_KEY, not both."
      end

      repository_url = repository.fetch("repository_url")
      scheme = URI.parse(repository_url).scheme
      credentials = if username && password
                     raise "HTTPS Git credentials require an https:// repository URL." unless scheme == "https"

                     { "username" => username, "password" => password }
                   elsif private_key
                     raise "OPSD_ARGOCD_REPO_SSH_PRIVATE_KEY requires an ssh:// repository URL." unless scheme == "ssh"

                     { "sshPrivateKey" => private_key }
                   else
                     return nil
                   end

      {
        "apiVersion" => "v1",
        "kind" => "Secret",
        "metadata" => {
          "name" => "opsd-gitops-repository",
          "namespace" => ARGOCD_NAMESPACE,
          "labels" => { "argocd.argoproj.io/secret-type" => "repository" }
        },
        "stringData" => {
          "type" => "git",
          "url" => repository_url
        }.merge(credentials)
      }
    end

    def apply_gitops_repository_secret(secret)
      _stdout, _stderr, status = capture(
        "kubectl", "apply", "--namespace", ARGOCD_NAMESPACE, "--filename", "-",
        stdin_data: YAML.dump(secret)
      )
      unless status.success?
        # Never include command output here: kubectl diagnostics can contain applied manifest data.
        raise "Unable to configure the Argo CD Git repository Secret (kubectl apply failed)."
      end

      @stdout.puts "Configured the Argo CD Git repository Secret."
    end

    def capture(*command, stdin_data: nil)
      options = stdin_data.nil? ? {} : { stdin_data: stdin_data }
      sanitized_environment = GITOPS_CREDENTIAL_ENV_KEYS.to_h { |name| [name, nil] }
      Open3.capture3(sanitized_environment, *command, **options)
    rescue Errno::ENOENT
      raise "Required command not found: #{command.first}"
    end

    def command_error(description, stdout, stderr)
      details = [stderr.strip, stdout.strip].reject(&:empty?).first
      details ? "#{description}: #{details}" : description
    end

    def non_retryable_kubectl_error?(message)
      message.match?(/unauthorized|forbidden|context .* does not exist|current-context is not set|provide credentials/i)
    end

    def timeout_error(last_error)
      "Timed out after #{CLUSTER_TIMEOUT_SECONDS / 60} minutes waiting for the Kubernetes cluster to become ready: #{last_error}"
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
