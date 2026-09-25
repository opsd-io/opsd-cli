# frozen_string_literal: true

module OPSd
  class Manifest
    SUPPORTED_PROVIDERS = %w[digitalocean aws azure gcp].freeze
    SUPPORTED_EGRESS_PRESETS = %w[open web dns_only].freeze
    KUBERNETES_COMPONENT_KEYS = %w[enabled values provider_overrides].freeze
    KUBERNETES_COMPONENT_ID_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    GIT_COMMIT_PATTERN = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/i
    KUBERNETES_LAYERS = [
      {
        "id" => "bootstrap",
        "order" => 0,
        "directory" => "00-bootstrap",
        "name" => "Bootstrap",
        "description" => "Bootstrap GitOps by applying the root app-of-apps.",
        "default_enabled" => true
      }.freeze,
      {
        "id" => "infrastructure",
        "order" => 10,
        "directory" => "10-infrastructure",
        "name" => "Infrastructure",
        "description" => "Provider and cluster infrastructure integrations.",
        "default_enabled" => true
      }.freeze,
      {
        "id" => "monitoring",
        "order" => 20,
        "directory" => "20-monitoring",
        "name" => "Monitoring",
        "description" => "Metrics, logs, alerts and dashboards.",
        "default_enabled" => false
      }.freeze,
      {
        "id" => "tools",
        "order" => 30,
        "directory" => "30-tools",
        "name" => "Tools",
        "description" => "Ingress, certificates, DNS and registries.",
        "default_enabled" => false
      }.freeze,
      {
        "id" => "applications",
        "order" => 40,
        "directory" => "40-applications",
        "name" => "Applications",
        "description" => "Application namespaces and workloads.",
        "default_enabled" => false
      }.freeze
    ].freeze

    class ValidationError < StandardError
      attr_reader :errors

      def initialize(errors)
        super("Manifest is invalid")
        @errors = errors
      end
    end

    attr_reader :data, :source_path

    def initialize(data, source_path: nil, profile_catalog: nil, supported_providers: SUPPORTED_PROVIDERS)
      @data = data || {}
      @source_path = source_path
      @profile_catalog = profile_catalog.is_a?(Hash) ? profile_catalog : {}
      @supported_providers = Array(supported_providers).map(&:to_s)
    end

    def validate!
      errors = []

      errors << "root document must be a YAML mapping" unless data.is_a?(Hash)
      raise ValidationError.new(errors) unless errors.empty?

      errors.concat(validate_common)
      errors.concat(validate_v2_manifest)
      errors.concat(validate_provider_v2_scope)

      raise ValidationError.new(errors) unless errors.empty?
    end

    def api_version
      data["apiVersion"]
    end

    def family
      origin["family"]
    end

    def provider
      dig("spec", "provider")
    end

    def metadata_name
      dig("metadata", "name")
    end

    def environment
      dig("metadata", "environment")
    end

    def region
      dig("metadata", "region")
    end

    def workload_kind
      workload_kind_for(primary_compute_entry)
    end

    def workload_topology
      workload_topology_for(primary_compute_entry)
    end

    def workload_profile
      if family == "spaces"
        primary_object_storage&.fetch("profile", nil)
      else
        primary_compute_entry&.fetch("profile", nil)
      end
    end

    def workload_image
      primary_compute_entry&.fetch("image", nil)
    end

    def workload_port
      primary_compute_entry&.fetch("port", nil)
    end

    def workload_instances
      primary_compute_group&.fetch("replicas", nil)
    end

    def composer_stack
      origin["stack"]
    end

    def composer_blueprint
      origin["blueprint"]
    end

    def composer_variant
      origin["variant"]
    end

    def spec
      data.fetch("spec", {})
    end

    def security
      value = spec["security"]
      value.is_a?(Hash) ? value : {}
    end

    def security_egress
      value = security["egress"]
      value.is_a?(Hash) ? value : {}
    end

    def security_egress_for(resource)
      value = resource.is_a?(Hash) ? resource["security"] : nil
      egress = value.is_a?(Hash) ? value["egress"] : nil
      return egress if egress.is_a?(Hash)

      security_egress
    end

    def origin
      value = spec["origin"]
      value.is_a?(Hash) ? value : {}
    end

    def dig(*keys)
      keys.reduce(data) do |memo, key|
        memo.is_a?(Hash) ? memo[key] : nil
      end
    end

    def compute_groups
      value = spec["compute_groups"]
      value.is_a?(Array) ? value : []
    end

    def nodes
      value = spec["nodes"]
      value.is_a?(Array) ? value : []
    end

    def databases
      value = spec["databases"]
      value.is_a?(Array) ? value : []
    end

    def caches
      value = spec["caches"]
      value.is_a?(Array) ? value : []
    end

    def load_balancers
      value = spec["load_balancers"]
      value.is_a?(Array) ? value : []
    end

    def object_storage
      value = spec["object_storage"]
      value.is_a?(Array) ? value : []
    end

    def cdn_endpoints
      value = spec["cdn_endpoints"]
      value.is_a?(Array) ? value : []
    end

    def primary_compute_group
      compute_groups.first
    end

    def primary_kubernetes_config
      value = primary_compute_group&.fetch("config", nil)
      value.is_a?(Hash) ? value : {}
    end

    def primary_node
      nodes.first
    end

    def primary_compute_entry
      primary_compute_group || primary_node
    end

    def primary_database
      databases.first
    end

    def primary_database_config
      value = primary_database&.fetch("config", nil)
      value.is_a?(Hash) ? value : {}
    end

    def primary_cache
      caches.first
    end

    def primary_cache_config
      value = primary_cache&.fetch("config", nil)
      value.is_a?(Hash) ? value : {}
    end

    def primary_public_load_balancer
      attached_ids = Array(primary_compute_group&.fetch("attach_to", nil))
      return nil if attached_ids.empty?

      load_balancers.find do |entry|
        entry.is_a?(Hash) &&
          entry["visibility"] == "public" &&
          attached_ids.include?(entry["id"])
      end
    end

    def primary_object_storage
      object_storage.first
    end

    def primary_object_storage_config
      value = primary_object_storage&.fetch("config", nil)
      value.is_a?(Hash) ? value : {}
    end

    def primary_public_cdn_endpoint
      cdn_endpoints.find { |entry| entry.is_a?(Hash) && entry["visibility"] == "public" }
    end

    def primary_cdn_config
      value = primary_public_cdn_endpoint&.fetch("config", nil)
      value.is_a?(Hash) ? value : {}
    end

    def primary_exposure_source
      compute_exposure = primary_compute_entry.is_a?(Hash) ? primary_compute_entry["exposure"] : nil
      return compute_exposure if compute_exposure.is_a?(Hash)

      load_balancer = primary_public_load_balancer
      if load_balancer.is_a?(Hash)
        return {
          "public" => true,
          "dns" => load_balancer["dns"]
        }
      end

      cdn_endpoint = primary_public_cdn_endpoint
      if cdn_endpoint.is_a?(Hash)
        return {
          "public" => true,
          "dns" => cdn_endpoint["dns"]
        }
      end

      nil
    end

    def exposure_public?
      source = primary_exposure_source
      source.is_a?(Hash) ? source.fetch("public", true) : false
    end

    def exposure_dns
      source = primary_exposure_source
      dns = source.is_a?(Hash) ? source["dns"] : nil
      dns.is_a?(Hash) ? dns : {}
    end

    def delivery
      compute = primary_compute_entry
      value = compute.is_a?(Hash) ? compute["delivery"] : nil
      value.is_a?(Hash) ? value : {}
    end

    def layers
      value = spec["layers"]
      value.is_a?(Hash) ? value : {}
    end

    def kubernetes_layer_plan
      KUBERNETES_LAYERS.map do |definition|
        config = layers[definition["id"]] || {}
        definition.merge(
          "enabled" => config.fetch("enabled", definition["default_enabled"]),
          "components" => config.fetch("components", {})
        ).reject { |key, _| key == "default_enabled" }
      end
    end

    def kubernetes_component_values(layer:, component:, module_defaults: {}, provider_defaults: {})
      layer_config = layers.fetch(layer.to_s, {})
      component_config = layer_config.fetch("components", {}).fetch(component.to_s, {})
      provider_values = component_config.fetch("provider_overrides", {}).fetch(provider.to_s, {}).fetch("values", {})

      deep_merge(
        module_defaults,
        provider_defaults,
        component_config.fetch("values", {}),
        provider_values
      )
    end

    def kubernetes_component_enabled?(layer:, component:)
      layers.fetch(layer.to_s, {}).fetch("components", {}).fetch(component.to_s, {}).fetch("enabled", false) == true
    end

    private

    def validate_common
      errors = []

      errors << "apiVersion must be opsd.io/v2alpha1" unless api_version == "opsd.io/v2alpha1"
      errors << "kind must be Environment" unless data["kind"] == "Environment"
      errors << "metadata.name is required" if blank?(metadata_name)
      errors << "metadata.environment is required" if blank?(environment)
      errors << "metadata.region is required" if blank?(region)
      errors << "spec is required" unless data["spec"].is_a?(Hash)
      errors << "spec.provider is required" if blank?(provider)
      if !blank?(provider) && !@supported_providers.include?(provider)
        errors << "spec.provider must be one of: #{@supported_providers.join(', ')}"
      end

      errors
    end

    def validate_v2_manifest
      errors = []
      metadata = data["metadata"]
      errors << "metadata.tags must be an array" unless metadata["tags"].is_a?(Array)
      errors << "metadata.labels must be a mapping" unless metadata["labels"].is_a?(Hash)

      origin = spec["origin"]
      defaults = spec["defaults"]
      compute_groups = spec["compute_groups"]
      nodes = spec["nodes"]
      databases = spec["databases"]
      caches = spec["caches"]
      load_balancers = spec["load_balancers"]
      object_storage = spec["object_storage"]
      cdn_endpoints = spec["cdn_endpoints"]
      policies = spec["policies"]
      layers = spec["layers"]

      errors << "spec.origin is required" unless origin.is_a?(Hash)
      errors << "spec.defaults must be a mapping" if spec.key?("defaults") && !defaults.is_a?(Hash)
      errors << "spec.compute_groups must be an array" unless compute_groups.is_a?(Array)
      errors << "spec.nodes must be an array" unless nodes.is_a?(Array)
      errors << "spec.databases must be an array" unless databases.is_a?(Array)
      errors << "spec.caches must be an array" unless caches.is_a?(Array)
      errors << "spec.load_balancers must be an array" unless load_balancers.is_a?(Array)
      errors << "spec.object_storage must be an array" unless object_storage.is_a?(Array)
      errors << "spec.cdn_endpoints must be an array" unless cdn_endpoints.is_a?(Array)
      errors << "spec.policies must be a mapping" if spec.key?("policies") && !policies.is_a?(Hash)
      errors.concat(validate_v2_layers(layers)) if spec.key?("layers")
      errors << "spec.security must be a mapping" if spec.key?("security") && !spec["security"].is_a?(Hash)

      validate_security_egress(spec["security"], "spec.security", errors)
      compute_groups.each_with_index do |group, index|
        validate_security_egress(group["security"], "spec.compute_groups[#{index}].security", errors)
      end
      nodes.each_with_index do |node, index|
        validate_security_egress(node["security"], "spec.nodes[#{index}].security", errors)
      end

      if origin.is_a?(Hash)
        errors << "spec.origin.blueprint is required" if blank?(origin["blueprint"])
        errors << "spec.origin.variant is required" if blank?(origin["variant"])
        errors << "spec.origin.family is required" if blank?(origin["family"])
        errors << "spec.origin.stack is required" if blank?(origin["stack"])
        modules = origin["modules"]
        errors << "spec.origin.modules is required" unless modules.is_a?(Hash)
        if modules.is_a?(Hash)
          %w[repo version commit].each do |key|
            errors << "spec.origin.modules.#{key} is required" if blank?(modules[key])
          end
          errors << "spec.origin.modules.repo must be a non-empty string" unless non_empty_string?(modules["repo"])
          errors << "spec.origin.modules.version must be a non-empty string" unless non_empty_string?(modules["version"])
          errors << "spec.origin.modules.commit must be a full Git commit SHA" unless modules["commit"].to_s.match?(GIT_COMMIT_PATTERN)
        end
      end

      return errors unless compute_groups.is_a?(Array) &&
                           nodes.is_a?(Array) &&
                           databases.is_a?(Array) &&
                           caches.is_a?(Array) &&
                           load_balancers.is_a?(Array) &&
                           object_storage.is_a?(Array) &&
                           cdn_endpoints.is_a?(Array)

      node_ids = nodes.filter_map { |entry| entry["id"] if entry.is_a?(Hash) && !blank?(entry["id"]) }

      errors.concat(validate_v2_compute_groups(compute_groups, node_ids: node_ids, family: family))
      errors.concat(validate_v2_nodes(nodes, node_ids: node_ids, family: family))
      errors.concat(validate_v2_databases(databases))
      errors.concat(validate_v2_caches(caches))
      errors.concat(validate_v2_load_balancers(load_balancers))
      errors.concat(validate_v2_object_storage(object_storage))
      errors.concat(validate_v2_cdn_endpoints(cdn_endpoints))
      errors.concat(validate_v2_references(compute_groups, nodes, databases, caches, load_balancers, object_storage, cdn_endpoints))

      errors
    end

    def validate_v2_layers(layers)
      return ["spec.layers must be a mapping"] unless layers.is_a?(Hash)

      allowed_layers = KUBERNETES_LAYERS.map { |layer| layer["id"] }
      errors = []
      layers.each do |name, config|
        prefix = "spec.layers.#{name}"
        errors << "#{prefix} is not supported" unless allowed_layers.include?(name.to_s)
        unless config.is_a?(Hash)
          errors << "#{prefix} must be a mapping"
          next
        end

        errors << "#{prefix}.enabled is required" unless config.key?("enabled")
        unless [true, false].include?(config["enabled"])
          errors << "#{prefix}.enabled must be a boolean"
        end
        errors << "#{prefix}.components must be a mapping" if config.key?("components") && !config["components"].is_a?(Hash)
        next unless config["components"].is_a?(Hash)

        config["components"].each do |component_id, component_config|
          component_prefix = "#{prefix}.components.#{component_id}"
          errors << "#{component_prefix} must be a DNS-like component identifier" unless component_id.to_s.match?(KUBERNETES_COMPONENT_ID_PATTERN)
          errors.concat(validate_v2_component(component_config, component_prefix, layer_enabled: config["enabled"] == true))
          errors.concat(validate_v2_bastion_component(component_config, component_prefix)) if name.to_s == "infrastructure" && component_id.to_s == "bastion"
        end
      end
      errors
    end

    def validate_v2_component(component, prefix, layer_enabled:)
      return ["#{prefix} must be a mapping"] unless component.is_a?(Hash)

      errors = []
      component.each_key do |key|
        errors << "#{prefix}.#{key} is not supported" unless KUBERNETES_COMPONENT_KEYS.include?(key.to_s)
      end
      errors << "#{prefix}.enabled is required" unless component.key?("enabled")
      errors << "#{prefix}.enabled must be a boolean" unless [true, false].include?(component["enabled"])
      errors << "#{prefix}.values must be a mapping" if component.key?("values") && !component["values"].is_a?(Hash)
      unless layer_enabled
        errors << "#{prefix}.enabled must be false when its layer is disabled" if component["enabled"] == true
      end

      overrides = component["provider_overrides"]
      if component.key?("provider_overrides") && !overrides.is_a?(Hash)
        errors << "#{prefix}.provider_overrides must be a mapping"
      elsif overrides.is_a?(Hash)
        overrides.each do |provider_name, override|
          provider_prefix = "#{prefix}.provider_overrides.#{provider_name}"
          errors << "#{provider_prefix} uses an unsupported provider" unless @supported_providers.include?(provider_name.to_s)
          errors << "#{provider_prefix} must be a mapping" unless override.is_a?(Hash)
          next unless override.is_a?(Hash)

          override.each_key do |key|
            errors << "#{provider_prefix}.#{key} is not supported" unless key.to_s == "values"
          end
          errors << "#{provider_prefix}.values is required" unless override.key?("values")
          errors << "#{provider_prefix}.values must be a mapping" if override.key?("values") && !override["values"].is_a?(Hash)
        end
      end

      errors
    end

    def validate_v2_bastion_component(component, prefix)
      return [] unless component.is_a?(Hash) && component["values"].is_a?(Hash)

      values = component["values"]
      errors = []
      allowed_keys = %w[size image user digitalocean_keys authorized_keys ssh_allow_cidrs control_plane_cidrs egress_preset]
      values.each_key do |key|
        errors << "#{prefix}.values.#{key} is not supported" unless allowed_keys.include?(key.to_s)
      end

      %w[size image user egress_preset].each do |key|
        errors << "#{prefix}.values.#{key} must be a non-empty string" if values.key?(key) && blank?(values[key])
      end
      if values.key?("egress_preset") && !SUPPORTED_EGRESS_PRESETS.include?(values["egress_preset"].to_s)
        errors << "#{prefix}.values.egress_preset must be one of: #{SUPPORTED_EGRESS_PRESETS.join(', ')}"
      end

      %w[ssh_allow_cidrs control_plane_cidrs].each do |key|
        errors << "#{prefix}.values.#{key} must be an array" if values.key?(key) && !values[key].is_a?(Array)
      end

      errors.concat(validate_v2_bastion_keys(values["digitalocean_keys"], "#{prefix}.values.digitalocean_keys", reference: true)) if values.key?("digitalocean_keys")
      errors.concat(validate_v2_bastion_keys(values["authorized_keys"], "#{prefix}.values.authorized_keys", reference: false)) if values.key?("authorized_keys")
      errors
    end

    def validate_v2_bastion_keys(keys, prefix, reference:)
      return ["#{prefix} must be an array"] unless keys.is_a?(Array)

      keys.each_with_index.flat_map do |entry, index|
        entry_prefix = "#{prefix}[#{index}]"
        unless entry.is_a?(Hash)
          next ["#{entry_prefix} must be a mapping"]
        end

        errors = []
        allowed_keys = reference ? %w[ref description] : %w[key description]
        entry.each_key do |key|
          errors << "#{entry_prefix}.#{key} is not supported" unless allowed_keys.include?(key.to_s)
        end
        required_key = reference ? "ref" : "key"
        errors << "#{entry_prefix}.#{required_key} must be a non-empty string" if blank?(entry[required_key])
        errors << "#{entry_prefix}.description must be a string" if entry.key?("description") && !entry["description"].is_a?(String)
        errors
      end
    end

    def validate_v2_compute_groups(compute_groups, node_ids:, family:)
      compute_groups.each_with_index.flat_map do |group, index|
        prefix = "spec.compute_groups[#{index}]"
        validate_v2_compute_like(group, prefix:, require_replicas: true, node_ids:, family:)
      end
    end

    def validate_v2_nodes(nodes, node_ids:, family:)
      nodes.each_with_index.flat_map do |node, index|
        prefix = "spec.nodes[#{index}]"
        validate_v2_compute_like(node, prefix:, require_replicas: false, node_ids:, family:)
      end
    end

    def validate_v2_compute_like(entry, prefix:, require_replicas:, node_ids:, family:)
      errors = []
      unless entry.is_a?(Hash)
        errors << "#{prefix} must be a mapping"
        return errors
      end

      %w[id type role profile].each do |key|
        errors << "#{prefix}.#{key} is required" if blank?(entry[key])
      end

      if require_replicas
        errors << "#{prefix}.replicas is required" unless positive_integer?(entry["replicas"])
      elsif entry.key?("replicas") && !positive_integer?(entry["replicas"])
        errors << "#{prefix}.replicas must be a positive integer when set"
      end

      errors << "#{prefix}.attach_to must be an array" if entry.key?("attach_to") && !entry["attach_to"].is_a?(Array)
      errors << "#{prefix}.links must be an array" if entry.key?("links") && !entry["links"].is_a?(Array)
      errors << "#{prefix}.network must be a mapping" if entry.key?("network") && !entry["network"].is_a?(Hash)
      errors << "#{prefix}.delivery must be a mapping" if entry.key?("delivery") && !entry["delivery"].is_a?(Hash)
      errors << "#{prefix}.metadata must be a mapping" if entry.key?("metadata") && !entry["metadata"].is_a?(Hash)
      errors << "#{prefix}.exposure must be a mapping" if entry.key?("exposure") && !entry["exposure"].is_a?(Hash)
      errors.concat(validate_v2_resource_lifecycle(entry["lifecycle"], "#{prefix}.lifecycle")) if entry.key?("lifecycle")
      errors.concat(validate_v2_kubernetes_config(entry["config"], "#{prefix}.config")) if entry["type"] == "cluster" && entry.key?("config")

      if entry["metadata"].is_a?(Hash)
        errors << "#{prefix}.metadata.tags must be an array" if entry["metadata"].key?("tags") && !entry["metadata"]["tags"].is_a?(Array)
        errors << "#{prefix}.metadata.labels must be a mapping" if entry["metadata"].key?("labels") && !entry["metadata"]["labels"].is_a?(Hash)
      end

      if entry["delivery"].is_a?(Hash)
        bootstrap = entry["delivery"]["bootstrap"]
        if entry["delivery"].key?("bootstrap") && !bootstrap.is_a?(Hash)
          errors << "#{prefix}.delivery.bootstrap must be a mapping"
        elsif bootstrap.is_a?(Hash)
          user_data = bootstrap["user_data"]
          errors << "#{prefix}.delivery.bootstrap.user_data must be a string" if bootstrap.key?("user_data") && !user_data.is_a?(String)
          errors << "#{prefix}.delivery.bootstrap.ssh_keys must be an array" if bootstrap.key?("ssh_keys") && !bootstrap["ssh_keys"].is_a?(Array)
          errors << "#{prefix}.delivery.bootstrap.ssh_authorized_keys must be an array" if bootstrap.key?("ssh_authorized_keys") && !bootstrap["ssh_authorized_keys"].is_a?(Array)
        end
      end

      if entry["exposure"].is_a?(Hash) && entry["exposure"].key?("public") && ![true, false].include?(entry["exposure"]["public"])
        errors << "#{prefix}.exposure.public must be true or false"
      end

      if entry["exposure"].is_a?(Hash) && entry["exposure"].key?("reserved_ip")
        reserved_ip = entry["exposure"]["reserved_ip"]
        errors << "#{prefix}.exposure.reserved_ip must be true or false" unless [true, false].include?(reserved_ip)
        if reserved_ip == true
          errors << "#{prefix}.exposure.reserved_ip is supported only for droplet resources" unless family == "droplet"
          errors << "#{prefix}.exposure.reserved_ip requires exposure.public=true" unless entry["exposure"]["public"] == true
          errors << "#{prefix}.exposure.reserved_ip requires replicas=1" if require_replicas && entry["replicas"] != 1
        end
      end

      if entry["exposure"].is_a?(Hash)
        dns = entry["exposure"]["dns"]
        errors.concat(validate_v2_dns_settings(dns, "#{prefix}.exposure.dns", allow_target_ref: true, node_ids:))
        if family == "droplet" && entry["exposure"]["public"] == true
          errors << "#{prefix}.exposure.ports is required when exposure.public is true" if blank?(entry["exposure"]["ports"])
          errors.concat(validate_v2_public_ingress_ports(entry["exposure"]["ports"], "#{prefix}.exposure.ports"))
        elsif entry["exposure"].key?("ports")
          errors.concat(validate_v2_public_ingress_ports(entry["exposure"]["ports"], "#{prefix}.exposure.ports"))
        end
      end

      errors
    end

    def validate_v2_resource_lifecycle(lifecycle, prefix)
      return ["#{prefix} must be a mapping"] unless lifecycle.is_a?(Hash)

      errors = []
      lifecycle.each_key do |key|
        errors << "#{prefix}.#{key} is not supported" unless key.to_s == "prevent_destroy"
      end
      if lifecycle.key?("prevent_destroy") && ![true, false].include?(lifecycle["prevent_destroy"])
        errors << "#{prefix}.prevent_destroy must be a boolean"
      end
      errors
    end

    def validate_v2_kubernetes_config(config, prefix)
      return ["#{prefix} must be a mapping"] unless config.is_a?(Hash)

      errors = []
      allowed_keys = %w[kubernetes_version auto_upgrade surge_upgrade ha create_vpc vpc_uuid vpc_ip_range node_pool_name node_size node_count node_auto_scale node_min_nodes node_max_nodes node_tags node_labels maintenance_day maintenance_start_time maintenance_duration]
      config.each_key do |key|
        errors << "#{prefix}.#{key} is not supported" unless allowed_keys.include?(key.to_s)
      end
      %w[kubernetes_version vpc_uuid vpc_ip_range node_pool_name node_size maintenance_day maintenance_start_time].each do |key|
        errors << "#{prefix}.#{key} must be a non-empty string" if config.key?(key) && blank?(config[key])
      end
      %w[auto_upgrade surge_upgrade ha create_vpc node_auto_scale].each do |key|
        errors << "#{prefix}.#{key} must be a boolean" if config.key?(key) && ![true, false].include?(config[key])
      end
      %w[node_count node_min_nodes node_max_nodes].each do |key|
        errors << "#{prefix}.#{key} must be a positive integer" if config.key?(key) && !positive_integer?(config[key])
      end
      errors << "#{prefix}.node_tags must be an array" if config.key?("node_tags") && !config["node_tags"].is_a?(Array)
      errors << "#{prefix}.node_labels must be a mapping" if config.key?("node_labels") && !config["node_labels"].is_a?(Hash)
      if config.key?("maintenance_duration") && (!config["maintenance_duration"].is_a?(Numeric) || config["maintenance_duration"] <= 0)
        errors << "#{prefix}.maintenance_duration must be a positive number"
      end
      errors
    end

    def validate_v2_public_ingress_ports(ports, prefix)
      return ["#{prefix} must be an array"] unless ports.is_a?(Array)
      return ["#{prefix} must not be empty when set"] if ports.empty?

      ports.each_with_index.flat_map do |port, index|
        port_prefix = "#{prefix}[#{index}]"
        positive_integer?(port) ? [] : ["#{port_prefix} must be a positive integer"]
      end
    end

    def validate_v2_databases(databases)
      databases.each_with_index.flat_map do |database, index|
        prefix = "spec.databases[#{index}]"
        errors = validate_v2_service_like(database, prefix:, required_keys: %w[id engine profile])
        errors.concat(validate_v2_database_config(database["config"], "#{prefix}.config")) if database.is_a?(Hash) && database.key?("config")
        errors
      end
    end

    def validate_v2_database_config(config, prefix)
      return ["#{prefix} must be a mapping"] unless config.is_a?(Hash)

      errors = []
      allowed_keys = %w[node_count database_name app_user_name]
      config.each_key do |key|
        errors << "#{prefix}.#{key} is not supported" unless allowed_keys.include?(key.to_s)
      end
      if config.key?("node_count") && !positive_integer?(config["node_count"])
        errors << "#{prefix}.node_count must be a positive integer"
      end
      %w[database_name app_user_name].each do |key|
        errors << "#{prefix}.#{key} must be a non-empty string" if config.key?(key) && blank?(config[key])
      end
      errors
    end

    def validate_v2_caches(caches)
      caches.each_with_index.flat_map do |cache, index|
        prefix = "spec.caches[#{index}]"
        errors = validate_v2_service_like(cache, prefix:, required_keys: %w[id engine profile])
        errors.concat(validate_v2_cache_config(cache["config"], "#{prefix}.config")) if cache.is_a?(Hash) && cache.key?("config")
        errors
      end
    end

    def validate_v2_cache_config(config, prefix)
      return ["#{prefix} must be a mapping"] unless config.is_a?(Hash)

      errors = []
      allowed_keys = %w[node_count eviction_policy]
      config.each_key do |key|
        errors << "#{prefix}.#{key} is not supported" unless allowed_keys.include?(key.to_s)
      end
      if config.key?("node_count") && !positive_integer?(config["node_count"])
        errors << "#{prefix}.node_count must be a positive integer"
      end
      if config.key?("eviction_policy") && blank?(config["eviction_policy"])
        errors << "#{prefix}.eviction_policy must be a non-empty string"
      end
      errors
    end

    def validate_v2_service_like(entry, prefix:, required_keys:)
      errors = []
      unless entry.is_a?(Hash)
        errors << "#{prefix} must be a mapping"
        return errors
      end

      required_keys.each do |key|
        errors << "#{prefix}.#{key} is required" if blank?(entry[key])
      end

      errors.concat(validate_v2_resource_lifecycle(entry["lifecycle"], "#{prefix}.lifecycle")) if entry.key?("lifecycle")

      errors
    end

    def validate_v2_dns_settings(dns, prefix, allow_target_ref: false, node_ids: [])
      errors = []
      errors << "#{prefix} must be a mapping" if dns && !dns.is_a?(Hash)
      return errors unless dns.is_a?(Hash)

      if dns["enabled"] == true
        manage_zone = dns.fetch("manage_zone", true)
        errors << "#{prefix}.record is required when dns is enabled" if blank?(dns["record"])
        if manage_zone == false
          errors << "#{prefix}.domain is required when dns is enabled and manage_zone is false" if blank?(dns["domain"])
        end
      end

      if !blank?(dns["target_ref"])
        if allow_target_ref
          errors.concat(validate_v2_dns_target_ref("#{prefix}.target_ref", dns["target_ref"], node_ids))
        else
          errors << "#{prefix}.target_ref is not supported here"
        end
      end

      if dns.key?("records")
        if !dns["records"].is_a?(Array)
          errors << "#{prefix}.records must be an array"
        else
          errors.concat(validate_v2_dns_records(dns["records"], "#{prefix}.records", allow_target_ref:, node_ids:))
        end
      end

      errors
    end

    def validate_v2_dns_records(records, prefix, allow_target_ref: false, node_ids: [])
      records.each_with_index.flat_map do |record, index|
        record_prefix = "#{prefix}[#{index}]"
        errors = []
        unless record.is_a?(Hash)
          errors << "#{record_prefix} must be a mapping"
          next errors
        end

        %w[type name].each do |key|
          errors << "#{record_prefix}.#{key} is required" if blank?(record[key])
        end

        if record["type"] == "A"
          if blank?(record["value"]) && blank?(record["target_ref"])
            errors << "#{record_prefix}.value or target_ref is required for A records"
          end
        else
          errors << "#{record_prefix}.value is required" if blank?(record["value"])
          errors << "#{record_prefix}.target_ref is not supported for #{record["type"]} records" unless blank?(record["target_ref"])
        end

        errors << "#{record_prefix}.priority is required for MX records" if record["type"] == "MX" && blank?(record["priority"])

        errors << "#{record_prefix}.ttl must be a positive integer when set" if record.key?("ttl") && !positive_integer?(record["ttl"])
        errors << "#{record_prefix}.priority must be a positive integer when set" if record.key?("priority") && !positive_integer?(record["priority"])
        errors << "#{record_prefix}.port must be a positive integer when set" if record.key?("port") && !positive_integer?(record["port"])
        errors << "#{record_prefix}.weight must be a positive integer when set" if record.key?("weight") && !positive_integer?(record["weight"])
        errors << "#{record_prefix}.flags must be a positive integer when set" if record.key?("flags") && !positive_integer?(record["flags"])

        if allow_target_ref && !blank?(record["target_ref"])
          errors.concat(validate_v2_dns_target_ref("#{record_prefix}.target_ref", record["target_ref"], node_ids))
        elsif !allow_target_ref && !blank?(record["target_ref"])
          errors << "#{record_prefix}.target_ref is not supported here"
        end

        errors
      end
    end

    def validate_v2_dns_target_ref(prefix, target_ref, node_ids)
      errors = []
      return errors if blank?(target_ref)

      unless target_ref.is_a?(String)
        errors << "#{prefix} must be a string"
        return errors
      end

      unless node_ids.include?(target_ref)
        errors << "#{prefix} references unknown node=#{target_ref}"
      end

      errors
    end

    def validate_v2_load_balancers(load_balancers)
      load_balancers.each_with_index.flat_map do |load_balancer, index|
        prefix = "spec.load_balancers[#{index}]"
        errors = []
        unless load_balancer.is_a?(Hash)
          errors << "#{prefix} must be a mapping"
          next errors
        end

        errors << "#{prefix}.id is required" if blank?(load_balancer["id"])
        visibility = load_balancer["visibility"]
        errors << "#{prefix}.visibility must be one of: public, private" unless %w[public private].include?(visibility)
        if load_balancer.key?("forwarding_rules")
          if !load_balancer["forwarding_rules"].is_a?(Array)
            errors << "#{prefix}.forwarding_rules must be an array"
          elsif load_balancer["forwarding_rules"].empty?
            errors << "#{prefix}.forwarding_rules must not be empty when set"
          else
            errors.concat(validate_v2_load_balancer_forwarding_rules(load_balancer["forwarding_rules"], "#{prefix}.forwarding_rules"))
          end
        else
          errors.concat(validate_v2_load_balancer_protocol(load_balancer["protocol"], "#{prefix}.protocol"))
          errors << "#{prefix}.port is required" unless positive_integer?(load_balancer["port"])
          errors << "#{prefix}.target_port is required" unless positive_integer?(load_balancer["target_port"])
        end
        errors.concat(validate_v2_resource_lifecycle(load_balancer["lifecycle"], "#{prefix}.lifecycle")) if load_balancer.key?("lifecycle")
        errors.concat(validate_v2_load_balancer_tls(load_balancer, prefix))
        errors.concat(validate_v2_dns_settings(load_balancer["dns"], "#{prefix}.dns"))

        errors
      end
    end

    def validate_v2_load_balancer_forwarding_rules(rules, prefix)
      rules.each_with_index.flat_map do |rule, index|
        rule_prefix = "#{prefix}[#{index}]"
        errors = []
        unless rule.is_a?(Hash)
          errors << "#{rule_prefix} must be a mapping"
          next errors
        end

        errors.concat(validate_v2_load_balancer_protocol(rule["entry_protocol"], "#{rule_prefix}.entry_protocol"))
        errors << "#{rule_prefix}.entry_port is required" unless positive_integer?(rule["entry_port"])
        errors.concat(validate_v2_load_balancer_protocol(rule["target_protocol"], "#{rule_prefix}.target_protocol"))
        errors << "#{rule_prefix}.target_port is required" unless positive_integer?(rule["target_port"])

        errors
      end
    end

    def validate_v2_load_balancer_protocol(protocol, prefix)
      return ["#{prefix} is required"] if blank?(protocol)
      return [] if %w[http https tcp udp].include?(protocol.to_s.downcase)

      ["#{prefix} must be one of: http, https, tcp, udp"]
    end

    def validate_v2_load_balancer_tls(load_balancer, prefix)
      tls = load_balancer["tls"]
      rules = load_balancer_forwarding_rules_payload_for_validation(load_balancer)
      https = rules.any? { |rule| rule["entry_protocol"].to_s.downcase == "https" }
      return ["#{prefix}.tls.certificate is required for HTTPS forwarding rules"] if tls.nil? && https
      return [] if tls.nil?
      return ["#{prefix}.tls must be a mapping"] unless tls.is_a?(Hash)

      certificate = tls["certificate"]
      return ["#{prefix}.tls.certificate is required for HTTPS forwarding rules"] if certificate.nil? && https
      return ["#{prefix}.tls.certificate must be a mapping"] unless certificate.is_a?(Hash)

      mode = certificate["mode"]
      errors = []
      errors << "#{prefix}.tls.certificate.mode must be one of: managed, existing" unless %w[managed existing].include?(mode)
      errors << "#{prefix}.tls.certificate.name is required" if blank?(certificate["name"])
      if mode == "managed"
        domains = certificate["domains"]
        errors << "#{prefix}.tls.certificate.domains must be a non-empty array" unless domains.is_a?(Array) && domains.any? { |domain| !blank?(domain) }
      elsif certificate.key?("domains") && !certificate["domains"].is_a?(Array)
        errors << "#{prefix}.tls.certificate.domains must be an array"
      end

      errors
    end

    def load_balancer_forwarding_rules_payload_for_validation(load_balancer)
      rules = Array(load_balancer["forwarding_rules"])
      return rules if rules.any?

      [{
        "entry_protocol" => load_balancer["protocol"],
        "entry_port" => load_balancer["port"],
        "target_protocol" => load_balancer["target_protocol"],
        "target_port" => load_balancer["target_port"]
      }]
    end

    def validate_v2_object_storage(object_storage)
      object_storage.each_with_index.flat_map do |storage, index|
        prefix = "spec.object_storage[#{index}]"
        errors = []
        unless storage.is_a?(Hash)
          errors << "#{prefix} must be a mapping"
          next errors
        end

        %w[id profile visibility].each do |key|
          errors << "#{prefix}.#{key} is required" if blank?(storage[key])
        end
        unless %w[private public].include?(storage["visibility"])
          errors << "#{prefix}.visibility must be one of: public, private"
        end
        errors.concat(validate_v2_resource_lifecycle(storage["lifecycle"], "#{prefix}.lifecycle")) if storage.key?("lifecycle")
        errors.concat(validate_v2_object_storage_config(storage["config"], "#{prefix}.config")) if storage.key?("config")

        errors
      end
    end

    def validate_v2_object_storage_config(config, prefix)
      return ["#{prefix} must be a mapping"] unless config.is_a?(Hash)

      errors = []
      allowed_keys = %w[acl force_destroy versioning_enabled]
      config.each_key do |key|
        errors << "#{prefix}.#{key} is not supported" unless allowed_keys.include?(key.to_s)
      end
      if config.key?("acl") && !%w[private public-read].include?(config["acl"])
        errors << "#{prefix}.acl must be one of: private, public-read"
      end
      %w[force_destroy versioning_enabled].each do |key|
        errors << "#{prefix}.#{key} must be a boolean" if config.key?(key) && ![true, false].include?(config[key])
      end
      errors
    end

    def validate_v2_cdn_endpoints(cdn_endpoints)
      cdn_endpoints.each_with_index.flat_map do |endpoint, index|
        prefix = "spec.cdn_endpoints[#{index}]"
        errors = []
        unless endpoint.is_a?(Hash)
          errors << "#{prefix} must be a mapping"
          next errors
        end

        %w[id origin visibility].each do |key|
          errors << "#{prefix}.#{key} is required" if blank?(endpoint[key])
        end
        unless %w[public private].include?(endpoint["visibility"])
          errors << "#{prefix}.visibility must be one of: public, private"
        end
        errors.concat(validate_v2_resource_lifecycle(endpoint["lifecycle"], "#{prefix}.lifecycle")) if endpoint.key?("lifecycle")
        errors.concat(validate_v2_cdn_config(endpoint["config"], "#{prefix}.config")) if endpoint.key?("config")
        errors.concat(validate_v2_dns_settings(endpoint["dns"], "#{prefix}.dns"))

        errors
      end
    end

    def validate_v2_cdn_config(config, prefix)
      return ["#{prefix} must be a mapping"] unless config.is_a?(Hash)

      errors = []
      allowed_keys = %w[ttl custom_domain certificate_name]
      config.each_key do |key|
        errors << "#{prefix}.#{key} is not supported" unless allowed_keys.include?(key.to_s)
      end
      if config.key?("ttl") && !positive_integer?(config["ttl"])
        errors << "#{prefix}.ttl must be a positive integer"
      end
      %w[custom_domain certificate_name].each do |key|
        errors << "#{prefix}.#{key} must be a non-empty string" if config.key?(key) && blank?(config[key])
      end
      errors
    end

    def validate_v2_references(compute_groups, nodes, databases, caches, load_balancers, object_storage, cdn_endpoints)
      errors = []
      all_ids = Hash.new(0)
      objects = compute_groups + nodes + databases + caches + load_balancers + object_storage + cdn_endpoints

      objects.each do |entry|
        next unless entry.is_a?(Hash)
        next if blank?(entry["id"])

        all_ids[entry["id"]] += 1
      end

      all_ids.each do |id, count|
        errors << "resource id=#{id} is defined more than once in v2 manifest" if count > 1
      end

      load_balancer_ids = load_balancers.filter_map { |entry| entry["id"] if entry.is_a?(Hash) && !blank?(entry["id"]) }

      compute_groups.each_with_index do |group, index|
        next unless group.is_a?(Hash)

        Array(group["attach_to"]).each do |target|
          errors << "spec.compute_groups[#{index}].attach_to references unknown load_balancer=#{target}" unless load_balancer_ids.include?(target)
        end

        Array(group["links"]).each do |target|
          errors << "spec.compute_groups[#{index}].links references unknown target=#{target}" unless all_ids.key?(target)
        end
      end

      nodes.each_with_index do |node, index|
        next unless node.is_a?(Hash)

        Array(node["links"]).each do |target|
          errors << "spec.nodes[#{index}].links references unknown target=#{target}" unless all_ids.key?(target)
        end
      end

      object_storage_ids = object_storage.filter_map { |entry| entry["id"] if entry.is_a?(Hash) && !blank?(entry["id"]) }
      cdn_endpoints.each_with_index do |endpoint, index|
        next unless endpoint.is_a?(Hash)

        origin = endpoint["origin"]
        unless blank?(origin) || object_storage_ids.include?(origin)
          errors << "spec.cdn_endpoints[#{index}].origin references unknown object_storage=#{origin}"
        end
      end

      errors
    end

    def validate_provider_v2_scope
      return [] if @profile_catalog.empty?

      errors = []

      Array(spec["compute_groups"]).each_with_index do |group, index|
        next unless group.is_a?(Hash)

        allowed_profiles = allowed_compute_profiles_for(group["type"])
        errors.concat(validate_profile_allowed("spec.compute_groups[#{index}]", group["profile"], allowed_profiles, resource_label_for_compute_type(group["type"])))
      end

      Array(spec["nodes"]).each_with_index do |node, index|
        next unless node.is_a?(Hash)

        allowed_profiles = allowed_compute_profiles_for(node["type"])
        errors.concat(validate_profile_allowed("spec.nodes[#{index}]", node["profile"], allowed_profiles, resource_label_for_compute_type(node["type"])))
      end

      Array(spec["databases"]).each_with_index do |database, index|
        next unless database.is_a?(Hash)

        allowed_profiles = allowed_profiles_for_service("databases", database["engine"])
        errors.concat(validate_profile_allowed("spec.databases[#{index}]", database["profile"], allowed_profiles, "database"))
      end

      Array(spec["caches"]).each_with_index do |cache, index|
        next unless cache.is_a?(Hash)

        allowed_profiles = allowed_profiles_for_service("caches", cache["engine"])
        errors.concat(validate_profile_allowed("spec.caches[#{index}]", cache["profile"], allowed_profiles, "cache"))
      end

      Array(spec["object_storage"]).each_with_index do |storage, index|
        next unless storage.is_a?(Hash)

        allowed_profiles = allowed_object_storage_profiles
        errors.concat(validate_profile_allowed("spec.object_storage[#{index}]", storage["profile"], allowed_profiles, "object storage"))
      end

      errors
    end

    def allowed_compute_profiles_for(type)
      compute = @profile_catalog["compute"]
      return [] unless compute.is_a?(Hash)

      key = case type
            when "vm" then "droplet"
            when "cluster" then "kubernetes"
            else
              type.to_s
            end

      Array(compute[key])
    end

    def allowed_profiles_for_service(section_key, engine)
      section = @profile_catalog[section_key]
      return [] unless section.is_a?(Hash)

      Array(section[engine.to_s])
    end

    def allowed_object_storage_profiles
      section = @profile_catalog["object_storage"]
      return [] unless section.is_a?(Hash)

      Array(section["spaces"])
    end

    def validate_profile_allowed(prefix, profile, allowed_profiles, label)
      return [] if allowed_profiles.empty?
      return [] if allowed_profiles.include?(profile)

      ["#{prefix}.profile=#{profile} is not a supported DigitalOcean #{label} profile. Use one of: #{allowed_profiles.join(', ')}"]
    end

    def resource_label_for_compute_type(type)
      case type
      when "vm" then "vm"
      when "cluster" then "kubernetes"
      else
        type.to_s
      end
    end

    def workload_kind_for(compute)
      return nil unless compute.is_a?(Hash)

      case compute["type"]
      when "vm" then "vm-service"
      when "service" then "service"
      when "static-site" then "static-site"
      when "cluster" then "cluster-service"
      else compute["type"]
      end
    end

    def workload_topology_for(compute)
      return nil unless compute.is_a?(Hash)

      case compute["type"]
      when "vm"
        Array(compute["attach_to"]).empty? ? "single" : "load-balanced"
      when "service", "static-site"
        "platform-service"
      when "cluster"
        "cluster"
      else
        nil
      end
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def non_empty_string?(value)
      value.is_a?(String) && !value.empty?
    end

    def deep_merge(*maps)
      maps.compact.reduce({}) do |merged, map|
        map.each_with_object(merged) do |(key, value), result|
          result[key] = if result[key].is_a?(Hash) && value.is_a?(Hash)
                          deep_merge(result[key], value)
                        else
                          value
                        end
        end
      end
    end

    def validate_security_egress(value, path, errors)
      return if value.nil?

      unless value.is_a?(Hash)
        errors << "#{path} must be a mapping"
        return
      end

      egress = value["egress"]
      if value.key?("egress") && !egress.is_a?(Hash)
        errors << "#{path}.egress must be a mapping"
        return
      end

      return unless egress.is_a?(Hash)

      errors << "#{path}.egress.preset is required" if blank?(egress["preset"])
      if !blank?(egress["preset"]) && !SUPPORTED_EGRESS_PRESETS.include?(egress["preset"].to_s)
        errors << "#{path}.egress.preset must be one of: #{SUPPORTED_EGRESS_PRESETS.join(', ')}"
      end
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value >= 1
    end
  end
end
