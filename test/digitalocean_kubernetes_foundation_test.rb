# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"

require "opsd/contract_store"
require "opsd/manifest"
require "opsd/renderer"
require "opsd/template_store"

class KubernetesFoundationTest < Minitest::Test
  def test_verified_module_sync_uses_local_relative_sources
    renderer = OPSd::Renderer.new(app_root: File.expand_path("..", __dir__), workspace_root: "/workspace")
    source = "/workspace/modules/digitalocean//modules/vpc"

    rendered = renderer.send(
      :externalize_module_sources,
      %(source = "#{source}"),
      { repo: "https://github.com/opsd-io/modules-digitalocean.git", version: "v1.0.0", synced: true },
      "/workspace/modules/digitalocean",
      output_path: "/workspace/environments/production"
    )

    assert_includes rendered, "../../modules/digitalocean/modules/vpc"
    refute_includes rendered, "git::"
  end

  def test_provider_catalog_exposes_only_the_current_foundation_blueprint
    Dir.mktmpdir("opsd-foundation-catalog") do |workspace|
      blueprint_root = File.join(workspace, "modules", "digitalocean", "blueprints")
      FileUtils.mkdir_p(blueprint_root)
      File.write(File.join(blueprint_root, "kubernetes-foundation.yaml"), <<~YAML)
        id: kubernetes-foundation
        title: Kubernetes foundation
        provider: digitalocean
        variants:
          - id: kubernetes
            stack: kubernetes-foundation
      YAML

      store = OPSd::TemplateStore.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: workspace,
        contract_store: OPSd::ContractStore.new(app_root: File.expand_path("..", __dir__))
      )

      assert_equal ["kubernetes-foundation"], store.blueprint_ids(provider: "digitalocean")
      blueprint = store.blueprint(provider: "digitalocean", id: "kubernetes-foundation")
      assert_equal ["kubernetes"], blueprint.fetch(:variants).map { |variant| variant.fetch("id") }
      assert_equal "kubernetes-foundation", blueprint.fetch(:variants).first.fetch("stack")
    end
  end

  def test_kubernetes_foundation_renders_ordered_layer_plan
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    delivery = manifest_data.dig("spec", "compute_groups", 0, "delivery")
    delivery["secret_env"] = { "GIT_TOKEN" => "keep-out-of-generated-files" }
    delivery.dig("source", "github").merge!(
      "repository_url" => "https://github.com/customer/platform.git",
      "revision" => "release/production",
      "environment_path" => "clusters/production"
    )
    manifest = OPSd::Manifest.new(manifest_data)
    manifest.validate!

    Dir.mktmpdir("opsd-foundation-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      scenario = OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: output_dir
      ).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890abcdef1234567890abcdef12"
        }
      )

      assert_equal "kubernetes-foundation", scenario
      main_tf = File.read(File.join(output_path, "main.tf"))
      assert_includes main_tf, "modules-digitalocean.git//modules/kubernetes?ref=v1.0.0"
      assert_includes main_tf, "modules-digitalocean.git//modules/vpc?ref=v1.0.0"
      assert_includes main_tf, 'module "bastion"'
      assert_includes main_tf, "count  = 0"
      refute_includes main_tf, "module.vpc[0].urn"
      assert File.file?(File.join(output_path, "opsd.layers.yaml"))
      plan = YAML.load_file(File.join(output_path, "opsd.layers.yaml"))
      refute_includes File.read(File.join(output_path, "opsd.layers.yaml")), "keep-out-of-generated-files"
      assert_equal(
        {
          "repository_url" => "https://github.com/customer/platform.git",
          "revision" => "release/production",
          "environment_path" => "clusters/production"
        },
        plan.dig("gitops", "repository")
      )
      bootstrap_root = File.join(output_path, "layers", "00-bootstrap", "argocd")
      root_application = YAML.load_file(File.join(bootstrap_root, "root-application.yaml"))
      assert_equal "Application", root_application.fetch("kind")
      assert_equal "opsd-root", root_application.dig("metadata", "name")
      assert_equal "bootstrap", root_application.dig("spec", "project")
      assert_equal "https://github.com/customer/platform.git", root_application.dig("spec", "source", "repoURL")
      assert_equal "release/production", root_application.dig("spec", "source", "targetRevision")
      assert_equal "clusters/production/layers/00-bootstrap/argocd", root_application.dig("spec", "source", "path")
      assert_equal true, root_application.dig("spec", "source", "directory", "recurse")
      assert_equal({ "prune" => true, "selfHeal" => true }, root_application.dig("spec", "syncPolicy", "automated"))

      layer_applications = Dir.glob(File.join(bootstrap_root, "applications", "*.yaml")).map { |path| YAML.load_file(path) }
      assert_equal %w[applications bootstrap infrastructure monitoring tools], layer_applications.map { |application| application.dig("metadata", "name").delete_prefix("opsd-") }.sort
      assert_equal ["0", "10", "20", "30", "40"], layer_applications.sort_by { |application| application.dig("metadata", "annotations", "argocd.argoproj.io/sync-wave").to_i }.map { |application| application.dig("metadata", "annotations", "argocd.argoproj.io/sync-wave") }
      assert layer_applications.all? { |application| application.dig("spec", "syncPolicy", "automated", "prune") }
      bootstrap_application = layer_applications.find { |application| application.dig("metadata", "name") == "opsd-bootstrap" }
      assert_equal "clusters/production/layers/00-bootstrap", bootstrap_application.dig("spec", "source", "path")
      assert_equal "argocd/**", bootstrap_application.dig("spec", "source", "directory", "exclude")
      assert_equal "clusters/production/layers/40-applications", layer_applications.find { |application| application.dig("metadata", "name") == "opsd-applications" }.dig("spec", "source", "path")
      argocd_config = YAML.load_file(File.join(bootstrap_root, "argocd-cm.yaml"))
      assert_equal "ConfigMap", argocd_config.fetch("kind")
      assert_equal "-1", argocd_config.dig("metadata", "annotations", "argocd.argoproj.io/sync-wave")
      assert_includes argocd_config.dig("data", "resource.customizations.health.argoproj.io_Application"), "obj.status.health.status"

      projects = Dir.glob(File.join(bootstrap_root, "projects", "*.yaml")).map { |path| YAML.load_file(path) }
      assert_equal %w[applications bootstrap infrastructure monitoring tools], projects.map { |project| project.dig("metadata", "name") }.sort
      assert projects.all? { |project| project.dig("spec", "sourceRepos") == ["https://github.com/customer/platform.git"] }
      assert_equal "argocd", projects.find { |project| project.dig("metadata", "name") == "bootstrap" }.dig("spec", "destinations", 0, "namespace")
      assert_equal [
        { "group" => "argoproj.io", "kind" => "AppProject" }
      ], projects.find { |project| project.dig("metadata", "name") == "bootstrap" }.dig("spec", "clusterResourceWhitelist")
      assert_includes File.read(File.join(bootstrap_root, "root-application.yaml")), "opsd-root"
      refute_includes Dir.glob(File.join(bootstrap_root, "**", "*.yaml")).map { |path| File.read(path) }.join("\n"), "keep-out-of-generated-files"
      assert_equal %w[bootstrap infrastructure monitoring tools applications], plan.fetch("layers").map { |layer| layer.fetch("id") }
      assert_equal [0, 10, 20, 30, 40], plan.fetch("layers").map { |layer| layer.fetch("order") }
      assert File.file?(File.join(output_path, "layers", "00-bootstrap", "README.md"))
      assert File.file?(File.join(output_path, "layers", "10-infrastructure", "README.md"))
      refute File.exist?(File.join(output_path, "layers", "10-infrastructure", "gateways"))
      assert_includes File.read(File.join(output_path, "layers", "00-bootstrap", "README.md")), "root app-of-apps"
      assert_includes File.read(File.join(output_path, "layers", "00-bootstrap", "README.md")), "client repository"
      assert_includes File.read(File.join(output_path, "layers", "00-bootstrap", "README.md")), "kubectl port-forward"
      assert_includes File.read(File.join(output_path, "layers", "00-bootstrap", "README.md")), "bastion"
      assert_includes File.read(File.join(output_path, "layers", "00-bootstrap", "README.md")), "clusters/production/layers/00-bootstrap/argocd/projects/bootstrap.yaml"
    end
  end

  def test_kubernetes_foundation_renders_digitalocean_dns_certificates_and_gateway_tls
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    manifest_data.dig("spec", "compute_groups", 0, "config").merge!(
      "kubernetes_version" => "1.33.1-do.0",
      "cluster_subnet" => "10.240.0.0/16",
      "service_subnet" => "10.241.0.0/19"
    )
    manifest_data.dig("spec", "layers", "infrastructure", "components")["gateway-api"] = {
      "enabled" => true,
      "values" => {
        "acme" => { "email" => "platform@example.com", "server" => "staging" },
        "public" => { "enabled" => true, "hostname" => "app.example.com" }
      }
    }
    manifest = OPSd::Manifest.new(manifest_data)
    manifest.validate!

    Dir.mktmpdir("opsd-gateway-certificate-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: output_dir
      ).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890abcdef1234567890abcdef12"
        }
      )

      gateway_root = File.join(output_path, "layers", "10-infrastructure", "gateways")
      gateway = YAML.load_file(File.join(gateway_root, "public.yaml"))
      issuer = YAML.load_file(File.join(gateway_root, "certificates", "cluster-issuer.yaml"))
      certificate = YAML.load_file(File.join(gateway_root, "certificates", "public.yaml"))
      cert_manager = YAML.load_file(File.join(gateway_root, "certificates", "cert-manager.yaml"))
      infrastructure_project = YAML.load_file(File.join(output_path, "layers", "00-bootstrap", "argocd", "projects", "infrastructure.yaml"))

      https_listener = gateway.dig("spec", "listeners").find { |listener| listener["name"] == "https" }
      assert_equal "app.example.com", https_listener.fetch("hostname")
      assert_equal "Terminate", https_listener.dig("tls", "mode")
      assert_equal "opsd-public-gateway-tls", https_listener.dig("tls", "certificateRefs", 0, "name")
      assert_equal "https://acme-staging-v02.api.letsencrypt.org/directory", issuer.dig("spec", "acme", "server")
      assert_equal "digitalocean", issuer.dig("spec", "acme", "solvers", 0, "dns01").keys.first
      assert_equal "digitalocean-dns", issuer.dig("spec", "acme", "solvers", 0, "dns01", "digitalocean", "tokenSecretRef", "name")
      assert_equal "opsd-public-gateway-tls", certificate.dig("spec", "secretName")
      assert_equal "app.example.com", certificate.dig("spec", "dnsNames", 0)
      assert_equal "cert-manager", cert_manager.dig("spec", "destination", "namespace")
      assert_equal "v1.21.2", cert_manager.dig("spec", "source", "targetRevision")
      assert_includes infrastructure_project.dig("spec", "sourceRepos"), "https://charts.jetstack.io"
    end
  end

  def test_kubernetes_foundation_renders_public_and_private_gateways_independently
    %w[public private].each do |profile|
      manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
      manifest_data.dig("spec", "compute_groups", 0, "config").merge!(
        "kubernetes_version" => "1.33.1-do.0",
        "cluster_subnet" => "10.240.0.0/16",
        "service_subnet" => "10.241.0.0/19"
      )
      manifest_data.dig("spec", "layers", "infrastructure", "components")["gateway-api"] = {
        "enabled" => true,
        "values" => { profile => { "enabled" => true } }
      }
      manifest = OPSd::Manifest.new(manifest_data)
      manifest.validate!

      Dir.mktmpdir("opsd-gateway-profile") do |workspace|
        output_path = File.join(workspace, "generated")
        OPSd::Renderer.new(
          app_root: File.expand_path("..", __dir__),
          workspace_root: workspace
        ).render(manifest, output_path)

        gateway_dir = File.join(output_path, "layers", "10-infrastructure", "gateways")
        assert_equal ["#{profile}.yaml"], Dir.glob(File.join(gateway_dir, "*.yaml")).map { |path| File.basename(path) }
        gateway = YAML.load_file(File.join(gateway_dir, "#{profile}.yaml"))
        assert_equal "Gateway", gateway.fetch("kind")
        assert_equal "cilium", gateway.dig("spec", "gatewayClassName")
        assert_equal "HTTP", gateway.dig("spec", "listeners", 0, "protocol")

        if profile == "private"
          assert_equal "INTERNAL", gateway.dig("spec", "infrastructure", "annotations", "service.beta.kubernetes.io/do-loadbalancer-network")
        else
          refute gateway.dig("spec", "infrastructure", "annotations")
        end
      end
    end
  end

  def test_kubernetes_foundation_renders_external_dns_with_scoped_secret_and_ownership
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    manifest_data.dig("spec", "layers", "infrastructure", "components")["external-dns"] = {
      "enabled" => true,
      "values" => {
        "domain_filters" => ["example.com"],
        "txt_owner_id" => "production-cluster",
        "token_secret_name" => "digitalocean-dns-token"
      }
    }
    manifest = OPSd::Manifest.new(manifest_data)
    manifest.validate!

    Dir.mktmpdir("opsd-external-dns") do |workspace|
      output_path = File.join(workspace, "generated")
      OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: workspace
      ).render(manifest, output_path)

      app_path = File.join(output_path, "layers", "10-infrastructure", "external-dns.yaml")
      app = YAML.load_file(app_path)
      values = YAML.safe_load(app.dig("spec", "source", "helm", "values"))
      infra_project = YAML.load_file(File.join(output_path, "layers", "00-bootstrap", "argocd", "projects", "infrastructure.yaml"))

      assert_equal "external-dns", app.dig("spec", "source", "chart")
      assert_equal "1.23.0", app.dig("spec", "source", "targetRevision")
      assert_equal "external-dns", app.dig("spec", "destination", "namespace")
      assert_equal %w[gateway-httproute service], values.fetch("sources")
      assert_equal "upsert-only", values.fetch("policy")
      assert_equal "txt", values.fetch("registry")
      assert_equal "production-cluster", values.fetch("txtOwnerId")
      assert_equal ["example.com"], values.fetch("domainFilters")
      assert_equal "digitalocean-dns-token", values.dig("provider", "webhook", "env", 0, "valueFrom", "secretKeyRef", "name")
      assert_equal "access-token", values.dig("provider", "webhook", "env", 0, "valueFrom", "secretKeyRef", "key")
      assert_equal true, values.dig("provider", "webhook", "securityContext", "readOnlyRootFilesystem")
      assert_includes infra_project.dig("spec", "sourceRepos"), "https://kubernetes-sigs.github.io/external-dns/"
      refute_includes File.read(app_path), "DO_TOKEN\":\n        value:"
    end
  end

  def test_kubernetes_foundation_renders_external_secrets_operator_when_enabled
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    manifest_data.dig("spec", "layers", "infrastructure", "components")["external-secrets"] = {
      "enabled" => true
    }
    manifest = OPSd::Manifest.new(manifest_data)
    manifest.validate!

    Dir.mktmpdir("opsd-external-secrets") do |workspace|
      output_path = File.join(workspace, "generated")
      OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: workspace
      ).render(manifest, output_path)

      app_path = File.join(output_path, "layers", "10-infrastructure", "external-secrets.yaml")
      app = YAML.load_file(app_path)
      values = YAML.safe_load(app.dig("spec", "source", "helm", "values"))
      infra_project = YAML.load_file(File.join(output_path, "layers", "00-bootstrap", "argocd", "projects", "infrastructure.yaml"))

      assert_equal "external-secrets", app.dig("spec", "source", "chart")
      assert_equal "https://charts.external-secrets.io", app.dig("spec", "source", "repoURL")
      assert_equal "2.12.0", app.dig("spec", "source", "targetRevision")
      assert_equal "external-secrets", app.dig("spec", "destination", "namespace")
      assert_equal true, values.fetch("installCRDs")
      assert_equal ["CreateNamespace=true"], app.dig("spec", "syncPolicy", "syncOptions")
      assert_includes infra_project.dig("spec", "sourceRepos"), "https://charts.external-secrets.io"
      refute_includes File.read(app_path), "accessToken"
    end
  end

  def test_kubernetes_foundation_renders_enabled_bastion_and_control_plane_sources
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    manifest_data["spec"]["layers"]["infrastructure"] = {
      "enabled" => true,
      "components" => {
        "bastion" => {
          "enabled" => true,
          "values" => {
            "digitalocean_keys" => [{ "ref" => "do-key-id", "description" => "Platform team" }],
            "authorized_keys" => [{ "key" => "ssh-ed25519 AAAA", "description" => "Alice laptop" }],
            "ssh_allow_cidrs" => ["198.51.100.0/24"],
            "control_plane_cidrs" => ["203.0.113.10/32"]
          }
        }
      }
    }
    manifest = OPSd::Manifest.new(manifest_data)

    Dir.mktmpdir("opsd-foundation-bastion-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      OPSd::Renderer.new(app_root: File.expand_path("..", __dir__), workspace_root: output_dir).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890abcdef1234567890abcdef12"
        }
      )

      main_tf = File.read(File.join(output_path, "main.tf"))
      assert_includes main_tf, 'module "bastion"'
      assert_includes main_tf, "modules-digitalocean.git//modules/bastion?ref=v1.0.0"
      assert_includes main_tf, '"do-key-id"'
      assert_includes main_tf, 'description = "Alice laptop"'
      assert_includes main_tf, '"203.0.113.10/32"'
      assert_includes main_tf, '"${module.bastion[0].ip_address}/32"'
      assert File.file?(File.join(output_path, "bastion-access.md"))
      handoff = File.read(File.join(output_path, "bastion-access.md"))
      assert_includes handoff, "does not receive a kubeconfig"
      assert_includes handoff, "Platform team"
      assert_includes handoff, "tls-server-name"
      assert_includes handoff, "PRIVATE_POSTGRES_HOST"
      assert_includes handoff, "Host opsd-bastion"
      assert_includes handoff, "ExitOnForwardFailure yes"
    end
  end

  def test_kubernetes_foundation_renders_optional_valkey
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    manifest_data.fetch("spec").fetch("caches") << {
      "id" => "cache-main",
      "engine" => "valkey",
      "profile" => "db-s-1vcpu-1gb"
    }
    manifest = OPSd::Manifest.new(manifest_data)

    Dir.mktmpdir("opsd-foundation-valkey-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: output_dir
      ).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890abcdef1234567890abcdef12"
        }
      )

      main_tf = File.read(File.join(output_path, "main.tf"))
      assert_includes main_tf, 'module "valkey"'
      assert_includes main_tf, "modules-digitalocean.git//modules/managed-valkey?ref=v1.0.0"
      assert_includes main_tf, "project_resource_urns = concat"
      assert_includes main_tf, 'module "project_resources"'
      assert_includes main_tf, "module.valkey.urn"
    end
  end

  def test_kubernetes_foundation_renders_optional_postgres_databases
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    manifest_data.fetch("spec").fetch("databases") << {
      "id" => "db-main",
      "engine" => "postgres",
      "profile" => "db-s-1vcpu-1gb",
      "config" => { "database_name" => "app", "app_user_name" => "app" }
    }
    manifest = OPSd::Manifest.new(manifest_data)

    Dir.mktmpdir("opsd-foundation-postgres-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: output_dir
      ).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890abcdef1234567890abcdef12"
        }
      )

      main_tf = File.read(File.join(output_path, "main.tf"))
      assert_includes main_tf, 'module "postgres"'
      assert_includes main_tf, "modules-digitalocean.git//modules/managed-postgres?ref=v1.0.0"
      assert_includes main_tf, "module.postgres.urn"
      assert_includes main_tf, 'postgres_version     = "16"'
    end
  end

  def test_kubernetes_foundation_renders_multiple_postgres_databases
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    databases = manifest_data.fetch("spec").fetch("databases")
    2.times do |index|
      databases << {
        "id" => "db-#{index + 1}",
        "engine" => "postgres",
        "profile" => "db-s-1vcpu-1gb"
      }
    end
    manifest = OPSd::Manifest.new(manifest_data)

    Dir.mktmpdir("opsd-foundation-postgres-multi-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: output_dir
      ).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890abcdef1234567890abcdef12"
        }
      )

      main_tf = File.read(File.join(output_path, "main.tf"))
      assert_includes main_tf, 'module "postgres"'
      assert_includes main_tf, 'module "postgres_2"'
      assert_includes main_tf, "module.postgres.urn"
      assert_includes main_tf, "module.postgres_2.urn"
    end
  end

  def test_kubernetes_foundation_renders_optional_mysql_database
    manifest_data = YAML.load_file(File.expand_path("../examples/kubernetes-environment.yaml", __dir__))
    manifest_data.fetch("spec").fetch("databases") << {
      "id" => "db-main",
      "engine" => "mysql",
      "profile" => "db-s-1vcpu-1gb",
      "config" => { "database_name" => "app", "app_user_name" => "app" }
    }
    manifest = OPSd::Manifest.new(manifest_data)

    Dir.mktmpdir("opsd-foundation-mysql-render") do |output_dir|
      output_path = File.join(output_dir, "generated")
      OPSd::Renderer.new(
        app_root: File.expand_path("..", __dir__),
        workspace_root: output_dir
      ).render(
        manifest,
        output_path,
        module_source: {
          repo: "https://github.com/opsd-io/modules-digitalocean.git",
          version: "v1.0.0",
          commit: "abcdef1234567890abcdef1234567890abcdef12"
        }
      )

      main_tf = File.read(File.join(output_path, "main.tf"))
      assert_includes main_tf, 'module "mysql"'
      assert_includes main_tf, "modules-digitalocean.git//modules/managed-mysql?ref=v1.0.0"
      assert_includes main_tf, "module.mysql.urn"
      assert_includes main_tf, 'mysql_version        = "8"'
    end
  end
end
