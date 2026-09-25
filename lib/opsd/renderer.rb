# frozen_string_literal: true

require "pathname"
require "fileutils"
require "yaml"
require "erb"
require "json"

require_relative "composer_store"
require_relative "render_provider_catalog"

module OPSd
  class Renderer
    def initialize(app_root:, workspace_root:, render_provider_catalog: nil)
      @app_root = Pathname(app_root)
      @workspace_root = Pathname(workspace_root)
      @render_provider_catalog = render_provider_catalog || RenderProviderCatalog.new
    end

    def render(manifest, output_dir, module_lock: nil, module_source: nil)
      provider = provider_for(manifest.provider)
      ensure_provider_supported!(provider, manifest)
      @current_render_provider = provider

      scenario_id = scenario_id_for(manifest, provider: provider)
      output_path = Pathname(output_dir)
      raise "Refusing to overwrite existing directory: #{output_path}" if output_path.exist?

      FileUtils.mkdir_p(output_path.dirname)
      generate_scenario(output_path, manifest, scenario_id, provider: provider, module_source: module_source)
      generate_layer_plan(output_path, manifest) if manifest.family == "kubernetes"
      generate_bastion_handoff(output_path, manifest) if manifest.family == "kubernetes" && manifest.kubernetes_component_enabled?(layer: "infrastructure", component: "bastion")

      tfvars_path = output_path.join("opsd.auto.tfvars")
      tfvars_path.write(render_tfvars(manifest, scenario_id, provider: provider))

      manifest_path = output_path.join("opsd.manifest.yaml")
      manifest_path.write(YAML.dump(manifest.data))

      unless module_lock.nil?
        lock_path = output_path.join("opsd.lock.yaml")
        lock_path.write(YAML.dump(module_lock))
      end

      scenario_id
    end

    private

    def ensure_provider_supported!(provider, manifest)
      return if provider

      available = @render_provider_catalog.supported_provider_names
      if available.empty?
        raise "Render currently supports no providers yet. Manifest provider: #{manifest.provider || 'unset'}"
      end

      if available.length == 1
        raise "Render currently supports only provider=#{available.first}. Manifest provider: #{manifest.provider || 'unset'}"
      end

      raise "Render currently supports providers: #{available.join(', ')}. Manifest provider: #{manifest.provider || 'unset'}"
    end

    def scenario_id_for(manifest, provider:)
      return composer_scenario_id_for(manifest) || family_kubernetes_scenario_id(manifest) if manifest.family == "kubernetes"

      raise "Unsupported family for the current provider catalog: #{manifest.family}"
    end

    def composer_scenario_id_for(manifest)
      return nil if blank?(manifest.composer_stack)

      scenario_id = composer_store.scenario_for_stack(provider: manifest.provider, id: manifest.composer_stack)
      raise "Composer stack not found for provider=#{manifest.provider}: #{manifest.composer_stack}" if scenario_id.nil?

      scenario_id
    end

    def generate_scenario(output_path, manifest, scenario_id, provider:, module_source: nil)
      output_path.mkpath

      case scenario_id
      when "kubernetes-foundation"
        generate_from_template(output_path, "kubernetes-foundation", manifest, provider: provider, module_source: module_source)
      else
        raise "No composer generator implemented for scenario: #{scenario_id}"
      end
    end

    def generate_from_template(output_path, template_name, manifest, provider:, module_source: nil)
      template_root = @app_root.join("composer", provider.template_namespace, "templates", template_name)
      module_package_root = @workspace_root.join("modules", provider.module_namespace).to_s
      stack_id = manifest.composer_stack || template_name

      main_tf = ERB.new(template_root.join("main.tf.erb").read, trim_mode: "-").result(binding)
      main_tf = externalize_module_sources(main_tf, module_source, module_package_root)
      readme = ERB.new(template_root.join("README.md.erb").read, trim_mode: "-").result(binding)
      scenario_json = ERB.new(template_root.join("scenario.json.erb").read, trim_mode: "-").result(binding)

      output_path.join("main.tf").write(main_tf)
      output_path.join("variables.tf").write(template_root.join("variables.tf").read)
      output_path.join("outputs.tf").write(template_root.join("outputs.tf").read)
      output_path.join("README.md").write(readme)
      output_path.join("scenario.json").write(scenario_json)
      output_path.join("tofu.tfvars.example").write(template_root.join("tofu.tfvars.example").read)
    end

    def generate_layer_plan(output_path, manifest)
      layers = manifest.kubernetes_layer_plan
      layer_root = output_path.join("layers")
      layer_root.mkpath

      plan = {
        "apiVersion" => "opsd.io/layers/v1alpha1",
        "kind" => "LayerPlan",
        "status" => "planned",
        "layers" => layers
      }
      output_path.join("opsd.layers.yaml").write(YAML.dump(plan))

      layers.each do |layer|
        layer_path = layer_root.join(layer.fetch("directory"))
        layer_path.mkpath
        layer_path.join("README.md").write(<<~README)
          # #{layer.fetch("name")}

          #{layer.fetch("description")}

          Status: #{layer.fetch("enabled") ? "enabled" : "disabled"}.

          This layer is planned in `opsd.layers.yaml` but is not generated yet.
        README
      end
    end

    def generate_bastion_handoff(output_path, manifest)
      config = manifest.kubernetes_component_values(layer: "infrastructure", component: "bastion")
      user = config.fetch("user", "bastion")
      key_descriptions = (Array(config["digitalocean_keys"]) + Array(config["authorized_keys"])).filter_map do |key|
        description = key.is_a?(Hash) ? key["description"] : nil
        description.is_a?(String) && !description.strip.empty? ? "- #{description}" : nil
      end
      key_summary = key_descriptions.empty? ? "- No additional key descriptions were provided." : key_descriptions.join("\n")
      output_path.join("bastion-access.md").write(<<~MARKDOWN)
        # Bastion access

        The bastion is provisioned with a Reserved IP and the non-root SSH user
        `#{user}`. The bastion does not receive a kubeconfig or Kubernetes
        credentials.

        Configured SSH keys:

        #{key_summary}

        Retrieve the address from the generated stack:

        ```sh
        BASTION_IP="$(tofu output -raw bastion_ip_address)"
        CLUSTER_HOST="$(tofu output -raw cluster_endpoint | sed -E 's#^https?://##; s#/$##')"
        ```

        Use a local tunnel when the Kubernetes API must be reached through the
        bastion:

        ```sh
        ssh -N -L 6443:${CLUSTER_HOST}:443 #{user}@${BASTION_IP}
        ```

        Keep the kubeconfig on the operator workstation and configure its API
        server as `https://127.0.0.1:6443` for the duration of the tunnel.
      MARKDOWN
    end

    def module_source_path(module_path, provider: @current_render_provider, module_source: nil)
      provider ||= @current_render_provider
      raise "Render provider is not configured" if provider.nil?

      return "#{@workspace_root.join("modules", provider.module_namespace).to_s}//#{module_path}" if module_source.nil?

      repo = normalize_repo_url(module_source[:repo] || module_source["repo"])
      version = module_source[:version] || module_source["version"]
      raise "module_source repo is required" if repo.nil? || repo.to_s.empty?
      raise "module_source version is required" if version.nil? || version.to_s.empty?

      "git::#{repo}//#{module_path}?ref=#{version}"
    end

    def externalize_module_sources(main_tf, module_source, module_package_root)
      return main_tf if module_source.nil?

      repo = normalize_repo_url(module_source[:repo] || module_source["repo"])
      version = module_source[:version] || module_source["version"]
      return main_tf if repo.nil? || repo.to_s.empty? || version.nil? || version.to_s.empty?

      local_root = Regexp.escape(module_package_root.to_s)
      main_tf.gsub(/#{local_root}\/\/(modules\/[^\"\s]+)/) do
        "git::#{repo}//#{$1}?ref=#{version}"
      end
    end

    def normalize_repo_url(repo)
      repo = repo.to_s
      return repo if repo.empty?

      repo.sub(/\Agit@gitlab\.com:/, "https://gitlab.com/")
    end

    def render_tfvars(manifest, scenario_id, provider: nil)
      case scenario_id
      when "kubernetes-foundation"
        render_kubernetes_basic(manifest)
      else
        raise "Unsupported scenario for render: #{scenario_id}"
      end
    end

    def render_droplet_single(manifest)
      bootstrap = manifest.delivery["bootstrap"] || {}
      dns = manifest.exposure_dns
      public_ingress_ports = public_ingress_ports_payload(manifest)
      lines = []
      lines << %(digitalocean_token = "set-via-TF_VAR_digitalocean_token")
      lines << %(region               = "#{manifest.region}")
      lines << %(droplet_name_prefix  = "#{manifest.metadata_name}")
      lines << %(droplet_size         = "#{profile_value(manifest.workload_profile)}")
      lines << %(droplet_image        = "#{normalize_droplet_image(manifest.workload_image)}")
      lines << %(ssh_keys             = #{hcl_list(array_value(bootstrap["ssh_keys"]))})
      lines << %(volume_ids           = [])
      lines << %(user_data            = #{hcl_scalar(cloud_init_user_data(bootstrap))})
      lines << %(cloudinit_ssh_authorized_keys = #{hcl_list(cloudinit_authorized_keys(bootstrap))})
      lines << %(cloudinit_user                = "#{bootstrap["cloud_init_user"]}")
      lines << %(cloudinit_user_groups         = ["sudo"])
      lines << %(cloudinit_user_shell          = "/bin/bash")
      lines << %(cloudinit_user_sudo           = "ALL=(ALL) NOPASSWD:ALL")
      lines << %(cloudinit_user_lock_passwd    = true)
      lines << %(extra_nodes                   = #{hcl_list_of_objects(extra_nodes_payload(manifest))})
      lines << %(vpc_uuid                      = null)
      lines << %(tags                          = #{hcl_list(default_tags(manifest, "droplet-single-do-dns"))})
      lines << %(ipv6                          = false)
      lines << %(monitoring                    = true)
      lines << %(backups                       = true)
      lines << %(droplet_agent                 = true)
      lines << %(graceful_shutdown             = false)
      lines << %(resize_disk                   = true)
      lines << %(enable_reserved_ip = #{reserved_ip_enabled?(manifest)})
      lines << %(firewall_public_ingress_ports = #{hcl_list(public_ingress_ports)})
      lines << %(enable_dns           = #{dns["enabled"] == true})
      lines << %(create_dns_zone      = #{dns_manage_zone?(manifest)})
      lines << %(dns_zone_name_prefix = "#{manifest.metadata_name}")
      lines << %(dns_domain           = #{hcl_scalar(dns_domain_value(manifest))}) unless dns_manage_zone?(manifest)
      lines << %(dns_record_name      = "#{dns["record"] || "app"}")
      lines << %(dns_record_target_ref = #{hcl_scalar(dns["target_ref"])})
      lines << %(dns_ttl              = 300)
      lines << %(additional_dns_records = #{hcl_map_of_objects(additional_dns_records_payload(dns))})
      lines << %(project_name        = "#{manifest.metadata_name}")
      lines << %(project_description = "#{default_project_description(manifest)}")
      lines << %(project_purpose     = "#{default_project_purpose(manifest)}")
      lines << %(project_environment = "#{capitalize(manifest.environment)}")
      lines.join("\n") + "\n"
    end

    def render_droplet_single_with_database(manifest, engine:, fallback_scenario: nil)
      database = manifest.primary_database || {}
      database_config = manifest.primary_database_config
      bootstrap = manifest.delivery["bootstrap"] || {}
      dns = manifest.exposure_dns
      public_ingress_ports = public_ingress_ports_payload(manifest)
      version = engine == "postgres" ? database.fetch("version", "16") : database.fetch("version", "8")
      scenario_tag = fallback_scenario || (engine == "postgres" ? "droplet-managed-postgres-do-dns" : "droplet-managed-mysql-do-dns")

      lines = []
      lines << %(region = "#{manifest.region}")
      lines << ""
      lines << %(droplet_name_prefix = "#{manifest.metadata_name}")
      lines << %(droplet_size        = "#{profile_value(manifest.workload_profile)}")
      lines << %(droplet_image       = "#{normalize_droplet_image(manifest.workload_image)}")
      lines << %(ssh_keys            = #{hcl_list(array_value(bootstrap["ssh_keys"]))})
      lines << %(volume_ids          = [])
      lines << %(user_data          = #{hcl_scalar(cloud_init_user_data(bootstrap))})
      lines << %(extra_nodes         = #{hcl_list_of_objects(extra_nodes_payload(manifest))})
      lines << ""
      lines << %(tags = #{hcl_list(default_tags(manifest, scenario_tag))})
      lines << ""
      lines << %(cloudinit_ssh_authorized_keys = #{hcl_list(cloudinit_authorized_keys(bootstrap))})
      lines << %(cloudinit_user                = "#{bootstrap["cloud_init_user"]}")
      lines << %(cloudinit_user_groups         = ["sudo"])
      lines << %(cloudinit_user_shell          = "/bin/bash")
      lines << %(cloudinit_user_sudo           = "ALL=(ALL) NOPASSWD:ALL")
      lines << %(cloudinit_user_lock_passwd    = true)
      lines << ""
      lines << %(vpc_uuid = null)
      lines << ""
      lines << %(db_name_prefix    = "#{manifest.metadata_name}")
      lines << %(db_version        = "#{version}")
      lines << %(db_size           = "#{profile_value(database.fetch("profile", "db-s-1vcpu-1gb"))}")
      lines << %(db_node_count     = #{database_config.fetch("node_count", 1)})
      lines << %(db_database_name  = #{hcl_scalar(database_config.fetch("database_name", "app"))})
      lines << %(db_app_user_name  = #{hcl_scalar(database_config.fetch("app_user_name", "app"))})
      lines << ""
      lines << %(firewall_public_ingress_ports = #{hcl_list(public_ingress_ports)})
      lines << %(enable_dns           = #{dns["enabled"] == true})
      lines << %(create_dns_zone      = #{dns_manage_zone?(manifest)})
      lines << %(dns_zone_name_prefix = "#{manifest.metadata_name}")
      lines << %(dns_domain           = #{hcl_scalar(dns_domain_value(manifest))}) unless dns_manage_zone?(manifest)
      lines << %(dns_record_name      = "#{dns["record"] || "app"}")
      lines << %(dns_record_target_ref = #{hcl_scalar(dns["target_ref"])})
      lines << %(dns_ttl              = 300)
      lines << %(additional_dns_records = #{hcl_map_of_objects(additional_dns_records_payload(dns))})
      lines << ""
      lines << %(project_name        = "#{manifest.metadata_name}")
      lines << %(project_description = "#{default_project_description(manifest)}")
      lines << %(project_purpose     = "Web Application")
      lines << %(project_environment = "#{capitalize(manifest.environment)}")
      lines.compact.join("\n") + "\n"
    end

    def render_droplet_single_with_database_and_valkey(manifest)
      database = manifest.primary_database || {}
      database_config = manifest.primary_database_config
      cache = manifest.primary_cache || {}
      cache_config = manifest.primary_cache_config
      bootstrap = manifest.delivery["bootstrap"] || {}
      dns = manifest.exposure_dns
      public_ingress_ports = public_ingress_ports_payload(manifest)

      lines = []
      lines << %(region = "#{manifest.region}")
      lines << ""
      lines << %(droplet_name_prefix = "#{manifest.metadata_name}")
      lines << %(droplet_size        = "#{profile_value(manifest.workload_profile)}")
      lines << %(droplet_image       = "#{normalize_droplet_image(manifest.workload_image)}")
      lines << %(ssh_keys            = #{hcl_list(array_value(bootstrap["ssh_keys"]))})
      lines << %(volume_ids          = [])
      lines << %(user_data          = #{hcl_scalar(cloud_init_user_data(bootstrap))})
      lines << %(extra_nodes         = #{hcl_list_of_objects(extra_nodes_payload(manifest))})
      lines << ""
      lines << %(tags = #{hcl_list(default_tags(manifest, "droplet-managed-postgres-valkey-do-dns"))})
      lines << ""
      lines << %(cloudinit_ssh_authorized_keys = #{hcl_list(cloudinit_authorized_keys(bootstrap))})
      lines << %(cloudinit_user                = "#{bootstrap["cloud_init_user"]}")
      lines << %(cloudinit_user_groups         = ["sudo"])
      lines << %(cloudinit_user_shell          = "/bin/bash")
      lines << %(cloudinit_user_sudo           = "ALL=(ALL) NOPASSWD:ALL")
      lines << %(cloudinit_user_lock_passwd    = true)
      lines << ""
      lines << %(vpc_uuid = null)
      lines << ""
      lines << %(db_name_prefix    = "#{manifest.metadata_name}")
      lines << %(db_version        = "#{database.fetch("version", "16")}")
      lines << %(db_size           = "#{profile_value(database.fetch("profile", "db-s-1vcpu-1gb"))}")
      lines << %(db_node_count     = #{database_config.fetch("node_count", 1)})
      lines << %(db_database_name  = #{hcl_scalar(database_config.fetch("database_name", "app"))})
      lines << %(db_app_user_name  = #{hcl_scalar(database_config.fetch("app_user_name", "app"))})
      lines << ""
      lines << %(valkey_name_prefix = "#{manifest.metadata_name}")
      lines << %(valkey_version     = "7")
      lines << %(valkey_size        = "#{profile_value(cache.fetch("profile", "db-s-1vcpu-1gb"))}")
      lines << %(valkey_node_count  = #{cache_config.fetch("node_count", 1)})
      lines << %(valkey_eviction_policy = #{hcl_scalar(cache_config["eviction_policy"])})
      lines << ""
      lines << %(firewall_public_ingress_ports = #{hcl_list(public_ingress_ports)})
      lines << %(enable_dns           = #{dns["enabled"] == true})
      lines << %(create_dns_zone      = #{dns_manage_zone?(manifest)})
      lines << %(dns_zone_name_prefix = "#{manifest.metadata_name}")
      lines << %(dns_domain           = #{hcl_scalar(dns_domain_value(manifest))}) unless dns_manage_zone?(manifest)
      lines << %(dns_record_name      = "#{dns["record"] || "app"}")
      lines << %(dns_record_target_ref = #{hcl_scalar(dns["target_ref"])})
      lines << %(dns_ttl              = 300)
      lines << %(additional_dns_records = #{hcl_map_of_objects(additional_dns_records_payload(dns))})
      lines << ""
      lines << %(project_name        = "#{manifest.metadata_name}")
      lines << %(project_description = "#{default_project_description(manifest)}")
      lines << %(project_purpose     = "Web Application")
      lines << %(project_environment = "#{capitalize(manifest.environment)}")
      lines.compact.join("\n") + "\n"
    end

    def render_droplet_lb_with_database(manifest, engine:)
      database = manifest.primary_database || {}
      database_config = manifest.primary_database_config
      load_balancer = manifest.primary_public_load_balancer || {}
      bootstrap = manifest.delivery["bootstrap"] || {}
      dns = manifest.exposure_dns
      version = engine == "postgres" ? database.fetch("version", "16") : database.fetch("version", "8")
      forwarding_rules = load_balancer_forwarding_rules_payload(load_balancer, fallback_target_port: manifest.workload_port || 80)
      primary_rule = forwarding_rules.first || {}
      target_port = primary_rule.fetch("target_port", load_balancer.fetch("target_port", manifest.workload_port || 80))
      entry_port = primary_rule.fetch("entry_port", load_balancer.fetch("port", 80))
      entry_protocol = primary_rule.fetch("entry_protocol", load_balancer.fetch("protocol", "http"))
      target_protocol = primary_rule.fetch("target_protocol", load_balancer.fetch("target_protocol", "http"))
      tls = load_balancer_tls_payload(load_balancer)
      healthcheck_path = %w[tcp udp].include?(target_protocol.to_s.downcase) ? nil : "/"

      lines = []
      lines << %(region = "#{manifest.region}")
      lines << ""
      lines << %(app_node_count      = #{manifest.workload_instances || 1})
      lines << %(droplet_name_prefix = "#{manifest.metadata_name}")
      lines << %(droplet_size        = "#{profile_value(manifest.workload_profile)}")
      lines << %(droplet_image       = "#{normalize_droplet_image(manifest.workload_image)}")
      lines << %(ssh_keys            = #{hcl_list(array_value(bootstrap["ssh_keys"]))})
      lines << %(volume_ids          = [])
      lines << %(user_data          = #{hcl_scalar(cloud_init_user_data(bootstrap))})
      lines << %(extra_nodes         = #{hcl_list_of_objects(extra_nodes_payload(manifest))})
      lines << ""
      lines << %(tags = #{hcl_list(default_tags(manifest, engine == "postgres" ? "droplet-lb-managed-postgres-do-dns" : "droplet-lb-managed-mysql-do-dns"))})
      lines << ""
      lines << %(cloudinit_ssh_authorized_keys = #{hcl_list(cloudinit_authorized_keys(bootstrap))})
      lines << %(cloudinit_user                = "#{bootstrap["cloud_init_user"]}")
      lines << %(cloudinit_user_groups         = ["sudo"])
      lines << %(cloudinit_user_shell          = "/bin/bash")
      lines << %(cloudinit_user_sudo           = "ALL=(ALL) NOPASSWD:ALL")
      lines << %(cloudinit_user_lock_passwd    = true)
      lines << ""
      lines << %(vpc_uuid = null)
      lines << ""
      lines << %(lb_name_prefix            = "#{manifest.metadata_name}")
      lines << %(lb_entry_protocol         = "#{entry_protocol}")
      lines << %(lb_entry_port             = #{entry_port})
      lines << %(lb_target_protocol        = "#{target_protocol}")
      lines << %(lb_target_port            = #{target_port})
      lines << %(lb_certificate_mode      = #{hcl_scalar(tls["mode"])})
      lines << %(lb_certificate_name      = #{hcl_scalar(tls["name"])})
      lines << %(lb_certificate_domains   = #{hcl_list(tls["domains"])})
      lines << %(lb_healthcheck_path       = #{hcl_scalar(healthcheck_path)})
      lines << %(lb_redirect_http_to_https = false)
      lines << ""
      lines << %(db_name_prefix    = "#{manifest.metadata_name}")
      lines << %(db_version        = "#{version}")
      lines << %(db_size           = "#{profile_value(database.fetch("profile", "db-s-1vcpu-1gb"))}")
      lines << %(db_node_count     = #{database_config.fetch("node_count", 1)})
      lines << %(db_database_name  = #{hcl_scalar(database_config.fetch("database_name", "app"))})
      lines << %(db_app_user_name  = #{hcl_scalar(database_config.fetch("app_user_name", "app"))})
      lines << ""
      lines << %(enable_dns           = #{dns["enabled"] == true})
      lines << %(create_dns_zone      = #{dns_manage_zone?(manifest)})
      lines << %(dns_zone_name_prefix = "#{manifest.metadata_name}")
      lines << %(dns_domain           = #{hcl_scalar(dns_domain_value(manifest))}) unless dns_manage_zone?(manifest)
      lines << %(dns_record_name      = "#{dns["record"] || "app"}")
      lines << %(dns_record_target_ref = #{hcl_scalar(dns["target_ref"])})
      lines << %(dns_ttl              = 300)
      lines << %(lb_forwarding_rules  = #{hcl_list_of_objects(forwarding_rules)})
      lines << %(additional_dns_records = #{hcl_map_of_objects(additional_dns_records_payload(dns))})
      lines << ""
      lines << %(project_name        = "#{manifest.metadata_name}")
      lines << %(project_description = "#{default_project_description(manifest)}")
      lines << %(project_purpose     = "Web Application")
      lines << %(project_environment = "#{capitalize(manifest.environment)}")
      lines.compact.join("\n") + "\n"
    end

    def render_kubernetes_basic(manifest)
      config = manifest.primary_kubernetes_config
      lines = []
      lines << %(digitalocean_token = "set-via-TF_VAR_digitalocean_token")
      lines << ""
      lines << %(cluster_name        = "#{manifest.metadata_name}")
      lines << %(region              = "#{manifest.region}")
      lines << %(kubernetes_version  = #{hcl_scalar(config.fetch("kubernetes_version", "latest"))})
      lines << %(cluster_tags        = #{hcl_list(default_tags(manifest, "kubernetes-basic"))})
      lines << %(auto_upgrade        = #{config.fetch("auto_upgrade", true)})
      lines << %(surge_upgrade       = #{config.fetch("surge_upgrade", true)})
      lines << %(ha                  = #{config.fetch("ha", false)})
      lines << ""
      lines << %(create_vpc      = #{config.fetch("create_vpc", true)})
      lines << %(vpc_uuid        = #{hcl_scalar(config["vpc_uuid"])})
      lines << %(vpc_name        = "#{manifest.metadata_name}-vpc")
      lines << %(vpc_description = "#{default_project_description(manifest)} VPC")
      lines << %(vpc_ip_range    = #{hcl_scalar(config["vpc_ip_range"])})
      lines << ""
      lines << %(node_pool_name  = #{hcl_scalar(config.fetch("node_pool_name", "default"))})
      lines << %(node_size       = #{hcl_scalar(config.fetch("node_size", profile_value(manifest.workload_profile)))})
      lines << %(node_count      = #{config.fetch("node_count", 1)})
      lines << %(node_auto_scale = #{config.fetch("node_auto_scale", false)})
      lines << %(node_min_nodes  = #{config.fetch("node_min_nodes", 1)})
      lines << %(node_max_nodes  = #{config.fetch("node_max_nodes", 3)})
      lines << %(node_tags       = #{hcl_list(config.fetch("node_tags", manifest.dig("metadata", "tags") || []))})
      lines << %(node_labels     = #{hcl_map(config.fetch("node_labels", manifest.dig("metadata", "labels") || {}))})
      lines << ""
      lines << %(maintenance_day        = #{hcl_scalar(config["maintenance_day"])})
      lines << %(maintenance_start_time = #{hcl_scalar(config["maintenance_start_time"])})
      lines << %(maintenance_duration   = #{hcl_scalar(config["maintenance_duration"])})
      lines << ""
      lines << %(project_name        = "#{manifest.metadata_name}")
      lines << %(project_description = "#{default_project_description(manifest)}")
      lines << %(project_purpose     = "#{default_project_purpose(manifest)}")
      lines << %(project_environment = "#{capitalize(manifest.environment)}")
      lines.join("\n") + "\n"
    end

    def render_kubernetes_registry_basic(manifest)
      config = manifest.primary_kubernetes_config
      lines = []
      lines << %(digitalocean_token = "set-via-TF_VAR_digitalocean_token")
      lines << ""
      lines << %(cluster_name        = "#{manifest.metadata_name}")
      lines << %(region              = "#{manifest.region}")
      lines << %(kubernetes_version  = #{hcl_scalar(config.fetch("kubernetes_version", "latest"))})
      lines << %(cluster_tags        = #{hcl_list(default_tags(manifest, "kubernetes-registry-basic"))})
      lines << %(auto_upgrade        = #{config.fetch("auto_upgrade", true)})
      lines << %(surge_upgrade       = #{config.fetch("surge_upgrade", true)})
      lines << %(ha                  = #{config.fetch("ha", false)})
      lines << ""
      lines << %(create_vpc      = #{config.fetch("create_vpc", true)})
      lines << %(vpc_uuid        = #{hcl_scalar(config["vpc_uuid"])})
      lines << %(vpc_name        = "#{manifest.metadata_name}-vpc")
      lines << %(vpc_description = "#{default_project_description(manifest)} VPC")
      lines << %(vpc_ip_range    = #{hcl_scalar(config["vpc_ip_range"])})
      lines << ""
      lines << %(node_pool_name  = #{hcl_scalar(config.fetch("node_pool_name", "default"))})
      lines << %(node_size       = #{hcl_scalar(config.fetch("node_size", profile_value(manifest.workload_profile)))})
      lines << %(node_count      = #{config.fetch("node_count", 1)})
      lines << %(node_auto_scale = #{config.fetch("node_auto_scale", false)})
      lines << %(node_min_nodes  = #{config.fetch("node_min_nodes", 1)})
      lines << %(node_max_nodes  = #{config.fetch("node_max_nodes", 3)})
      lines << %(node_tags       = #{hcl_list(config.fetch("node_tags", manifest.dig("metadata", "tags") || []))})
      lines << %(node_labels     = #{hcl_map(config.fetch("node_labels", manifest.dig("metadata", "labels") || {}))})
      lines << ""
      lines << %(maintenance_day        = #{hcl_scalar(config["maintenance_day"])})
      lines << %(maintenance_start_time = #{hcl_scalar(config["maintenance_start_time"])})
      lines << %(maintenance_duration   = #{hcl_scalar(config["maintenance_duration"])})
      lines << ""
      lines << %(registry_name_prefix   = "opsdreg")
      lines << %(subscription_tier_slug = "starter")
      lines << %(registry_region        = null)
      lines << ""
      lines << %(project_name        = "#{manifest.metadata_name}")
      lines << %(project_description = "#{default_project_description(manifest)}")
      lines << %(project_purpose     = "#{default_project_purpose(manifest)}")
      lines << %(project_environment = "#{capitalize(manifest.environment)}")
      lines.join("\n") + "\n"
    end

    def render_spaces_only(manifest)
      storage_config = manifest.primary_object_storage_config
      lines = []
      lines << %(digitalocean_token = "set-via-TF_VAR_digitalocean_token")
      lines << %(bucket_name_prefix  = "#{manifest.metadata_name}")
      lines << %(region              = "#{manifest.region}")
      lines << %(acl                 = #{hcl_scalar(storage_config.fetch("acl", "private"))})
      lines << %(force_destroy       = #{storage_config.fetch("force_destroy", true)})
      lines << %(versioning_enabled  = #{storage_config.fetch("versioning_enabled", true)})
      lines << %(project_name        = "#{manifest.metadata_name}")
      lines << %(project_description = "#{default_project_description(manifest)}")
      lines << %(project_purpose     = "Web Site")
      lines << %(project_environment = "#{capitalize(manifest.environment)}")
      lines.join("\n") + "\n"
    end

    def render_spaces_cdn(manifest)
      storage_config = manifest.primary_object_storage_config
      cdn_config = manifest.primary_cdn_config
      lines = []
      lines << %(digitalocean_token  = "set-via-TF_VAR_digitalocean_token")
      lines << %(bucket_name_prefix  = "#{manifest.metadata_name}")
      lines << %(region              = "#{manifest.region}")
      lines << %(acl                 = #{hcl_scalar(storage_config.fetch("acl", "private"))})
      lines << %(force_destroy       = #{storage_config.fetch("force_destroy", true)})
      lines << %(versioning_enabled  = #{storage_config.fetch("versioning_enabled", true)})
      lines << %(cdn_ttl             = #{cdn_config.fetch("ttl", 3600)})
      lines << %(cdn_custom_domain  = #{hcl_scalar(cdn_config["custom_domain"])})
      lines << %(cdn_certificate_name = #{hcl_scalar(cdn_config["certificate_name"])})
      dns = manifest.exposure_dns
      lines << %(enable_dns_cname    = #{dns["enabled"] == true})
      lines << %(create_dns_zone     = #{dns_manage_zone?(manifest)})
      lines << %(dns_zone_name_prefix = "#{manifest.metadata_name}")
      lines << %(dns_domain          = #{hcl_scalar(dns_domain_value(manifest))}) unless dns_manage_zone?(manifest)
      lines << %(dns_record_name     = "#{dns["record"] || "assets"}")
      lines << %(dns_ttl             = 300)
      lines << %(additional_dns_records = #{hcl_map_of_objects(additional_dns_records_payload(dns))})
      lines << %(project_name        = "#{manifest.metadata_name}")
      lines << %(project_description = "#{default_project_description(manifest)}")
      lines << %(project_purpose     = "Web Site")
      lines << %(project_environment = "#{capitalize(manifest.environment)}")
      lines.compact.join("\n") + "\n"
    end

    def hcl_map(hash)
      return "{}" if hash.empty?

      body = hash.map do |key, value|
        %(  #{key} = #{hcl_scalar(value)})
      end.join("\n")
      "{\n#{body}\n}"
    end

    def hcl_list(items)
      "[" + items.map { |item| hcl_scalar(item) }.join(", ") + "]"
    end

    def hcl_object(hash, indent: 0)
      outer_indent = " " * indent
      inner_indent = " " * (indent + 2)
      body = hash.map do |key, value|
        %(#{inner_indent}#{key} = #{hcl_value(value, indent: indent + 2)})
      end.join("\n")
      "{\n#{body}\n#{outer_indent}}"
    end

    def hcl_list_of_objects(items)
      return "[]" if items.empty?

      body = items.map { |item| hcl_object(item, indent: 2) }.join(",\n")
      "[\n#{body}\n]"
    end

    def hcl_map_of_objects(hash)
      return "{}" if hash.empty?

      body = hash.map do |key, value|
        %(  #{key} = #{hcl_object(value, indent: 2)})
      end.join("\n")
      "{\n#{body}\n}"
    end

    def hcl_scalar(value)
      case value
      when nil
        "null"
      when true, false
        value.to_s
      when Integer
        value.to_s
      else
        JSON.generate(value.to_s)
      end
    end

    def hcl_value(value, indent: 0)
      case value
      when Array
        hcl_list(value)
      when Hash
        hcl_object(value, indent: indent)
      else
        hcl_scalar(value)
      end
    end

    def bastion_ssh_keys_payload(config)
      Array(config["digitalocean_keys"]).filter_map do |entry|
        next unless entry.is_a?(Hash)

        next unless entry["ref"].is_a?(String) && !entry["ref"].strip.empty?

        { "ref" => entry["ref"], "description" => entry["description"] }
      end
    end

    def bastion_authorized_keys_payload(config)
      Array(config["authorized_keys"]).filter_map do |entry|
        next unless entry.is_a?(Hash)
        next unless entry["key"].is_a?(String) && !entry["key"].strip.empty?

        {
          "key" => entry["key"],
          "description" => entry["description"]
        }
      end
    end

    def bastion_outbound_rules_hcl(config)
      rules = case config.fetch("egress_preset", "web")
      when "dns_only"
        egress_outbound_rules(["53"], protocols: %w[tcp udp])
      when "open"
        egress_outbound_rules(["1-65535"], protocols: %w[tcp udp]) +
          egress_outbound_rules([nil], protocols: ["icmp"])
      else
        egress_outbound_rules(["53"], protocols: %w[tcp udp]) +
          egress_outbound_rules(["80", "443"], protocols: ["tcp"]) +
          egress_outbound_rules(["123"], protocols: ["udp"])
      end
      hcl_list_of_objects(rules)
    end

    def egress_outbound_rules(ports, protocols:)
      ports.flat_map do |port|
        protocols.map do |protocol|
          {
            "protocol" => protocol,
            "port_range" => port,
            "destination_addresses" => ["0.0.0.0/0", "::/0"]
          }.compact
        end
      end
    end

    def cloudinit_authorized_keys(bootstrap)
      value = bootstrap["ssh_authorized_keys"]
      value.is_a?(Array) ? value : []
    end

    def cloud_init_user_data(bootstrap)
      raw_user_data = bootstrap["user_data"]
      document = if raw_user_data.nil? || raw_user_data.strip.empty?
        {}
      else
        YAML.safe_load(raw_user_data)
      end
      raise "bootstrap.user_data must contain a cloud-config YAML mapping" unless document.is_a?(Hash)

      users = Array(document["users"])
      users << {
        "name" => bootstrap.fetch("cloud_init_user", "opsd"),
        "groups" => ["sudo"],
        "shell" => "/bin/bash",
        "sudo" => "ALL=(ALL) NOPASSWD:ALL",
        "lock_passwd" => true,
        "ssh_authorized_keys" => cloudinit_authorized_keys(bootstrap)
      } unless users.any? { |user| user.is_a?(Hash) && user["name"] == bootstrap.fetch("cloud_init_user", "opsd") }
      document["users"] = users

      "#cloud-config\n#{YAML.dump(document).sub(/\A---\s*\n/, "")}"
    rescue Psych::Exception => e
      raise "bootstrap.user_data must contain valid cloud-config YAML: #{e.message}"
    end

    def capitalize(value)
      return value if value.nil? || value.empty?

      value[0].upcase + value[1..]
    end

    def family_droplet_scenario_id(manifest)
      topology = manifest.workload_topology
      database = manifest.primary_database
      cache = manifest.primary_cache
      database_enabled = !database.nil?
      engine = database&.fetch("engine", nil)
      cache_enabled = !cache.nil?

      case topology
      when "single"
        return "droplet-single-do-dns" unless database_enabled
        return "droplet-managed-postgres-valkey-do-dns" if database_enabled && engine == "postgres" && cache_enabled
        return "droplet-managed-postgres-do-dns" if engine == "postgres"
        return "droplet-managed-mysql-vpc-firewall-do-dns" if engine == "mysql" && manifest.composer_stack == "droplet-managed-mysql-vpc-firewall"
        return "droplet-managed-mysql-do-dns" if engine == "mysql"
      when "load-balanced"
        return "droplet-lb-managed-postgres-do-dns" if database_enabled && engine == "postgres"
        return "droplet-lb-managed-mysql-do-dns" if database_enabled && engine == "mysql"
        raise "Load-balanced droplet render currently requires a managed postgres or mysql database"
      end

      raise "Unsupported droplet topology/database combination"
    end

    def family_kubernetes_scenario_id(manifest)
      "kubernetes-foundation"
    end

    def default_tags(manifest, fallback_scenario)
      tags = manifest.dig("metadata", "tags")
      tags = tags.is_a?(Array) && !tags.empty? ? tags.dup : [manifest.environment, "managed-by-opsd"]
      tags << fallback_scenario unless tags.include?(fallback_scenario)
      tags
    end

    def default_project_description(manifest)
      "OPSd #{manifest.family} environment #{manifest.metadata_name}"
    end

    def default_project_purpose(manifest)
      "Service or API"
    end

    def normalize_droplet_image(image)
      image.to_s == "ubuntu-24-04" ? "ubuntu-24-04-x64" : image
    end

    def profile_value(value)
      value.to_s
    end

    def extra_nodes_payload(manifest)
      Array(manifest.nodes).filter_map do |node|
        next unless node.is_a?(Hash)

        {
          "id" => node["id"],
          "role" => node["role"],
          "size" => profile_value(node["profile"]),
          "image" => normalize_droplet_image(node["image"]),
          "reserved_ip" => node.dig("exposure", "reserved_ip") == true
        }
      end
    end

    def reserved_ip_enabled?(manifest)
      manifest.primary_compute_entry&.dig("exposure", "reserved_ip") == true
    end

    def dns_manage_zone?(manifest)
      dns = manifest.exposure_dns
      return false unless dns.is_a?(Hash) && dns["enabled"] == true

      dns.fetch("manage_zone", true) == true
    end

    def dns_domain_value(manifest)
      return nil if dns_manage_zone?(manifest)

      manifest.exposure_dns["domain"]
    end

    def composer_store
      @composer_store ||= ComposerStore.new(app_root: @app_root)
    end

    def provider_for(provider_name)
      @render_provider_catalog.provider(provider_name)
    end

    def array_value(value)
      value.is_a?(Array) ? value : []
    end

    def additional_dns_records_payload(dns)
      records = Array(dns.is_a?(Hash) ? dns["records"] : nil)
      records.each_with_index.each_with_object({}) do |(record, index), payload|
        next unless record.is_a?(Hash)

        payload["record_#{index + 1}"] = {
          "type" => record["type"],
          "name" => record["name"],
          "value" => record["value"],
          "target_ref" => record["target_ref"],
          "ttl" => record["ttl"],
          "priority" => record["priority"],
          "port" => record["port"],
          "weight" => record["weight"],
          "flags" => record["flags"],
          "tag" => record["tag"]
        }
      end
    end

    def load_balancer_forwarding_rules_payload(load_balancer, fallback_target_port:)
      rules = Array(load_balancer.is_a?(Hash) ? load_balancer["forwarding_rules"] : nil)
      if rules.any?
        return rules.filter_map { |rule| load_balancer_forwarding_rule_payload(rule) }
      end

      [
        load_balancer_forwarding_rule_payload(
          "entry_protocol" => load_balancer.is_a?(Hash) ? load_balancer.fetch("protocol", "http") : "http",
          "entry_port" => load_balancer.is_a?(Hash) ? load_balancer.fetch("port", 80) : 80,
          "target_protocol" => load_balancer.is_a?(Hash) ? load_balancer.fetch("target_protocol", "http") : "http",
          "target_port" => load_balancer.is_a?(Hash) ? load_balancer.fetch("target_port", fallback_target_port) : fallback_target_port
        )
      ]
    end

    def load_balancer_forwarding_rule_payload(rule)
      return nil unless rule.is_a?(Hash)

      {
        "entry_protocol" => rule["entry_protocol"],
        "entry_port" => rule["entry_port"],
        "target_protocol" => rule["target_protocol"],
        "target_port" => rule["target_port"]
      }
    end

    def load_balancer_tls_payload(load_balancer)
      certificate = load_balancer.is_a?(Hash) ? load_balancer.dig("tls", "certificate") : nil
      certificate = {} unless certificate.is_a?(Hash)
      {
        "mode" => certificate["mode"],
        "name" => certificate["name"],
        "domains" => Array(certificate["domains"])
      }
    end

    def public_ingress_ports_payload(manifest)
      exposure = manifest.primary_exposure_source
      ports = exposure.is_a?(Hash) ? exposure["ports"] : nil
      ports = Array(ports).filter_map { |port| port.is_a?(Integer) ? port : port.to_i } if ports.is_a?(Array)
      return ports if ports.is_a?(Array) && ports.any?

      workload_port = manifest.primary_compute_entry.is_a?(Hash) ? manifest.primary_compute_entry["port"] : nil
      Array(workload_port).filter_map { |port| port.is_a?(Integer) ? port : port.to_i }
    end

    def egress_outbound_rules_hcl(manifest, resource = nil)
      case security_egress_preset(manifest, resource)
      when "dns_only"
        <<~HCL.chomp
          [
            {
              protocol              = "tcp"
              port_range            = "53"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            },
            {
              protocol              = "udp"
              port_range            = "53"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            }
          ]
        HCL
      when "web"
        <<~HCL.chomp
          [
            {
              protocol              = "tcp"
              port_range            = "53"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            },
            {
              protocol              = "udp"
              port_range            = "53"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            },
            {
              protocol              = "tcp"
              port_range            = "80"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            },
            {
              protocol              = "tcp"
              port_range            = "443"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            },
            {
              protocol              = "udp"
              port_range            = "123"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            }
          ]
        HCL
      else
        <<~HCL.chomp
          [
            {
              protocol              = "tcp"
              port_range            = "1-65535"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            },
            {
              protocol              = "udp"
              port_range            = "1-65535"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            },
            {
              protocol              = "icmp"
              destination_addresses = toset(["0.0.0.0/0", "::/0"])
            }
          ]
        HCL
      end
    end

    def security_egress_preset(manifest, resource = nil)
      manifest.security_egress_for(resource).fetch("preset", "open").to_s
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end
