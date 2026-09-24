# frozen_string_literal: true

require "pathname"
require "json"
require "shellwords"
require "open3"
require "yaml"
require "fileutils"

require_relative "manifest"
require_relative "kubernetes_module"
require_relative "renderer"
require_relative "template_store"
require_relative "wizard_catalog"
require_relative "config_store"
require_relative "composer_store"
require_relative "module_catalog"
require_relative "contract_store"
require_relative "config_verifier"
require_relative "plan_verifier"
require_relative "lifecycle_verifier"
require_relative "exit_pack_exporter"
require_relative "manifest_capabilities_validator"
require_relative "provider_catalog_store"
require_relative "version"

module OPSd
  class CLI
    COMPLETION_COMMANDS = %w[
      version completion config list describe init validate verify render export add resize scale attach detach remove blueprints help
    ].freeze
    COMPLETION_SUBCOMMANDS = {
      completion: %w[install bash zsh fish],
      config: %w[profile],
      config_profile: %w[list show create edit use current],
      list: %w[blueprints],
      describe: %w[blueprint],
      init: %w[blueprint],
      validate_render: %w[manifest module],
      verify: %w[config plan lifecycle],
      export: %w[exit-pack],
      add: %w[compute-group database cache object-storage cdn-endpoint load-balancer node],
      resize: %w[compute-group cache database],
      scale: %w[compute-group],
      attach_detach: %w[compute-group],
      remove: %w[compute-group database cache object-storage load-balancer cdn-endpoint node],
      add_database: %w[postgres mysql],
      add_cache: %w[valkey],
      add_node: %w[vm]
    }.freeze
    COMPLETION_OPTIONS = {
      resize: %w[--profile],
      scale: %w[--replicas],
      attach: %w[--to],
      detach: %w[--from]
    }.freeze

    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
      @app_root = Pathname(ENV.fetch("OPSD_APP_ROOT", Pathname(__dir__).join("../..").realpath.to_s)).expand_path
      @workspace = Pathname(ENV.fetch("OPSD_WORKSPACE_ROOT", @app_root.to_s)).expand_path
    end

    def run
      command = @argv.shift

      case command
      when nil
        puts usage
      when "help"
        run_help
      when "--help", "-h"
        puts usage
      when "version", "--version", "-v"
        puts OPSd::VERSION
      when "completion"
        run_completion
      when "config"
        run_config
      when "list"
        run_list
      when "describe"
        run_describe
      when "init"
        run_init
      when "validate"
        run_validate
      when "verify"
        run_verify
      when "render"
        run_render
      when "export"
        run_export
      when "add"
        run_add
      when "resize"
        run_resize
      when "scale"
        run_scale
      when "attach"
        run_attach
      when "detach"
        run_detach
      when "remove"
        run_remove
      when "blueprints"
        print_blueprints
      else
        puts usage
        exit(1)
      end
    rescue OPSd::Manifest::ValidationError => e
      warn "Validation failed:"
      e.errors.each { |error| warn "- #{error}" }
      exit 1
    rescue OPSd::ConfigVerifier::VerificationError => e
      warn "Config verification failed: #{e.manifest_path}" if e.manifest_path
      warn "Config verification failed" if e.manifest_path.nil?
      print_verification_findings(e.findings)
      exit 1
    rescue OPSd::PlanVerifier::VerificationError => e
      warn "Plan verification failed: #{e.plan_path}" if e.plan_path
      warn "Plan verification failed" if e.plan_path.nil?
      print_plan_verification_findings(e.findings)
      exit 1
    rescue OPSd::LifecycleVerifier::VerificationError => e
      warn "Lifecycle verification failed: #{e.lifecycle_path}" if e.lifecycle_path
      warn "Lifecycle verification failed" if e.lifecycle_path.nil?
      print_lifecycle_verification_findings(e.findings)
      exit 1
    rescue StandardError => e
      warn e.message
      exit 1
    end

    private

    def run_help
      topic = @argv.shift

      case topic
      when nil, "--help", "-h"
        puts usage
      when "version"
        puts version_usage
      when "completion"
        if @argv.first == "install"
          @argv.shift
          puts completion_install_usage
        else
          puts completion_usage
        end
      when "config"
        if @argv.first == "profile"
          @argv.shift
          if @argv.first == "use"
            @argv.shift
            puts config_profile_use_usage
          elsif @argv.first == "current"
            @argv.shift
            puts config_profile_current_usage
          else
            puts config_profile_usage
          end
        else
          puts config_usage
        end
      when "list", "blueprints"
        puts list_usage
      when "describe"
        puts describe_usage
      when "init"
        puts init_usage
      when "validate"
        puts validate_usage
      when "verify"
        puts verify_usage
      when "render"
        puts render_usage
      when "export"
        puts export_usage
      when "add"
        puts add_usage
      when "resize"
        puts resize_usage
      when "scale"
        puts scale_usage
      when "attach"
        puts attach_usage
      when "detach"
        puts detach_usage
      when "remove"
        puts remove_usage
      else
        puts usage
      end
    end

    def run_completion
      shell = @argv.shift

      case shell
      when nil, "--help", "-h"
        puts completion_usage
      when "install"
        run_completion_install
      when "bash"
        puts bash_completion_script
      when "zsh"
        puts zsh_completion_script
      when "fish"
        puts fish_completion_script
      else
        raise "Unsupported completion shell: #{shell}"
      end
    end

    def run_completion_install
      args = @argv.dup
      return puts(completion_install_usage) if args.empty? || args.any? { |value| help_flag?(value) }

      snapshot = args.delete("--snapshot")
      unknown_option = args.find { |value| value.start_with?("-") }
      raise "Unknown completion install option: #{unknown_option}" if unknown_option

      shell = args.shift
      return puts(completion_install_usage) if shell.nil?
      raise "Usage: opsd completion install [--snapshot] <bash|zsh|fish>" if args.any?

      warm_completion_cache
      script, destination = completion_install_payload(shell, snapshot: snapshot)
      destination.dirname.mkpath
      destination.write(script)
      hook_path = completion_hook_path(shell)
      append_block(path: hook_path, text: completion_install_hook(shell, destination))

      puts "Installed #{shell} completion #{snapshot ? 'snapshot' : 'loader'}."
      puts "Touched: #{display_path(destination)}, #{display_path(hook_path)}"
      puts "Run now: source #{display_path(hook_path)} to activate shell completion."
    end

    def run_config
      subcommand = @argv.shift

      case subcommand
      when nil, "--help", "-h"
        puts config_usage
      when "help"
        puts config_usage
      when "profile"
        run_config_profile
      else
        raise "Unsupported config command: #{subcommand}"
      end
    end

    def run_config_profile
      subcommand = @argv.shift

      case subcommand
      when nil, "--help", "-h", "help"
        puts config_profile_usage
        puts profile_creation_hint
        puts profile_edit_hint
      when "list"
        run_config_profile_list
      when "show"
        run_config_profile_show
      when "create"
        run_config_profile_create
      when "edit"
        run_config_profile_edit
      when "use"
        run_config_profile_use
      when "current"
        run_config_profile_current
      when "configure"
        run_config_profile_configure
      else
        raise "Unsupported config profile command: #{subcommand}"
      end
    end

    def run_config_profile_list
      profiles = config_store.profile_names

      if profiles.empty?
        puts "No profiles configured"
        return
      end

      puts "Profiles:"
      profiles.each do |name|
        marker = name == selected_profile_name ? " (current)" : ""
        puts "  #{name}#{marker}"
      end
    end

    def run_config_profile_show
      name = @argv.shift
      if name.nil? || help_flag?(name) || help_requested?
        puts "Usage: opsd config profile show <profile>"
        show_available_profiles
        puts profile_show_hint
        return
      end

      profile = config_store.profile(name)
      raise "Profile not found: #{name}" if profile.nil?

      puts "Profile: #{name}"
      puts "Status: #{name == selected_profile_name ? 'current' : 'available'}"
      profile.each do |key, value|
        puts "  #{key}: #{value}"
      end
    end

    def run_config_profile_create
      name = @argv.shift
      if help_flag?(name) || help_requested? || placeholder_profile_name?(name)
        puts "Usage: opsd config profile create <profile>"
        puts profile_creation_hint
        return
      end

      if name.nil? || name.empty?
        puts "Usage: opsd config profile create <profile>"
        puts profile_creation_hint
        return
      end

      if config_store.profile(name)
        raise "Profile already exists: #{name}. Use `opsd config profile edit #{name}` to update it."
      end

      write_profile_values(name, create_default: true)
    end

    def run_config_profile_edit
      name = @argv.shift
      if name.nil? || help_flag?(name) || help_requested?
        puts "Usage: opsd config profile edit <profile>"
        show_available_profiles
        puts profile_edit_hint
        return
      end

      if config_store.profile(name).nil?
        available = config_store.profile_names
        suffix = available.empty? ? "" : ". Available profiles: #{available.join(', ')}"
        raise "Profile not found: #{name}#{suffix}. Use `opsd config profile create #{name}` to add it."
      end

      write_profile_values(name, create_default: false)
    end

    def run_config_profile_configure
      name = @argv.shift
      return run_config_profile_create if name.nil? || help_flag?(name) || help_requested?

      config_store.ensure_profile(name)

      write_profile_values(name, create_default: false, legacy_configure: true)
    end

    def write_profile_values(name, create_default:, legacy_configure: false)
      profile = config_store.profile(name) || {}
      provider_default = profile["provider"] || "digitalocean"
      region_default = profile["region"] || "fra1"

      answers = {}
      answers["provider"] = prompt_profile_field(
        "Provider",
        default: provider_default,
        hint: nil
      )

      answers["token"] = prompt_profile_field(
        "API token",
        default: nil,
        hint: "Create it here: https://cloud.digitalocean.com/account/api/tokens"
      )

      answers["region"] = prompt_profile_field(
        "Region",
        default: region_default,
        hint: "Available regions: nyc1, nyc2, nyc3, ams3, sfo2, sfo3, sgp1, lon1, fra1, tor1, blr1, syd1, atl1, ric1"
      )

      answers.each do |key, value|
        next if value.nil? || value.empty?

        config_store.set_profile_value(name, key, value)
      end

      puts legacy_configure ? "Profile configured: #{name}" : (create_default ? "Profile created: #{name}" : "Profile updated: #{name}")
      puts "Config file: #{display_path(config_store.path)}"
    end

    def run_config_profile_use
      name = @argv.shift
      if name.nil? || help_flag?(name) || help_requested?
        puts config_profile_use_usage
        show_available_profiles
        puts profile_use_hint
        return
      end

      if config_store.profile(name).nil?
        available = config_store.profile_names
        suffix = available.empty? ? "" : ". Available profiles: #{available.join(', ')}"
        raise "Profile not found: #{name}#{suffix}"
      end

      config_store.set_current_profile(name)
      puts "Current profile: #{name}"
      puts "Config file: #{display_path(config_store.path)}"
    end

    def run_config_profile_current
      name = selected_profile_name

      if help_flag?(@argv.first) || help_requested?
        puts config_profile_current_usage
        return
      end

      if name.nil?
        puts "No current profile selected"
        return
      end

      puts "Current profile: #{name}"
      provider = selected_profile_provider
      puts "Provider: #{provider}" unless provider.nil?
      puts "Config file: #{display_path(config_store.path)}"
    end

    def run_list
      topic = @argv.shift

      case topic
      when nil, "--help", "-h", "help"
        puts list_usage
      when "blueprints"
        raise "Unknown list blueprints option: #{@argv.first}" unless @argv.empty?
        print_blueprints
      else
        raise "Unsupported list topic: #{topic}"
      end
    end

    def run_describe
      subject = @argv.shift

      case subject
      when nil, "--help", "-h", "help"
        puts describe_usage
      when "blueprint"
        run_describe_blueprint
      else
        raise "Unsupported describe subject: #{subject}"
      end
    end

    def run_describe_blueprint
      blueprint_id = @argv.shift
      return puts(describe_usage) if blueprint_id.nil? || help_flag?(blueprint_id) || help_requested?
      raise "Usage: opsd describe blueprint <blueprint> [--variant <variant>]" if blueprint_id.nil?

      variant_id = nil
      until @argv.empty?
        token = @argv.shift
        case token
        when "--variant"
          variant_id = @argv.shift
          raise "Missing value for --variant" if variant_id.nil? || variant_id.empty?
        else
          raise "Unknown describe blueprint option: #{token}"
        end
      end

      ensure_provider_supported_for_catalog!

      blueprint = template_store.blueprint(provider: effective_provider, id: blueprint_id)
      raise "Unsupported blueprint: #{blueprint_id}" if blueprint.nil?

      print_blueprint_details(
        blueprint,
        requested_variant_id: variant_id,
        profile_catalog: provider_catalog_store.profile_catalog(effective_provider),
        addons_catalog: provider_catalog_store.addons_catalog(effective_provider)
      )
    end

    def run_init
      subcommand = @argv.shift

      case subcommand
      when nil, "--help", "-h", "help"
        puts init_usage
        return
      when "blueprint"
        identifier = @argv.shift
        return puts(init_usage) if identifier.nil? || help_flag?(identifier) || help_requested?
        output, options = parse_init_options!(@argv)
      else
        raise "Unsupported init target: #{subcommand}"
      end

      raise "Usage: opsd init blueprint <blueprint> [output.yaml] [--variant <variant>]" if identifier.nil?

      ensure_provider_supported_for_catalog!
      blueprint = template_store.blueprint(provider: effective_provider, id: identifier)
      raise "Unsupported blueprint: #{identifier}" if blueprint.nil?

      variant = select_blueprint_variant(blueprint, requested_variant_id: options.fetch("variant", nil))
      default_output = "#{identifier}-#{variant.fetch('id')}.environment.yaml"

      output_path = Pathname(output || default_output)
      confirm_overwrite_file!(output_path) if output_path.exist?

      output_path.dirname.mkpath
      manifest_data = materialize_v2_blueprint_manifest_data(blueprint, variant, resolution: catalog_resolution)
      manifest_data = run_blueprint_wizard(manifest_data, blueprint, variant) if options["wizard"]
      output_path.write(YAML.dump(manifest_data))

      puts "Created manifest: #{output_path}"
      puts
      puts "Next step:"
      puts "  opsd validate manifest #{output_path}"
    end

    def run_validate
      subject = @argv.shift

      case subject
      when nil, "--help", "-h", "help"
        puts validate_usage
        return
      when "manifest"
        manifest_path = @argv.shift
      when "module"
        return run_validate_module
      else
        manifest_path = subject
      end

      return puts(validate_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd validate manifest <manifest.yaml>" if manifest_path.nil?
      raise "Usage: opsd validate manifest <manifest.yaml>" unless @argv.empty?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      capability_validator.validate!(manifest)

      puts "Manifest is valid: #{manifest_path}"
      puts "Provider: #{manifest.provider}"
      puts "Family: #{manifest.family}" unless manifest.family.nil?
      puts "Workload kind: #{manifest.workload_kind}" unless manifest.workload_kind.nil?
      puts "Blueprint: #{manifest.composer_blueprint}" unless manifest.composer_blueprint.nil?
      puts "Variant: #{manifest.composer_variant}" unless manifest.composer_variant.nil?
      puts
      puts "Next step:"
      puts "  opsd render manifest #{manifest_path} --output <directory>"
    end

    def run_validate_module
      module_path = @argv.shift
      return puts(validate_usage) if module_path.nil? || help_flag?(module_path) || help_requested?
      raise "Usage: opsd validate module <module.yaml>" unless @argv.empty?

      metadata = KubernetesModule.load(module_path)
      metadata.validate!

      puts "Kubernetes module metadata is valid: #{module_path}"
      puts "Module: #{metadata.data.dig('metadata', 'id')}"
      puts "Layer: #{metadata.data.dig('spec', 'layer')}"
      puts "Ownership: #{metadata.data.dig('spec', 'ownership', 'type')}"
    end

    def run_verify
      subject = @argv.shift

      case subject
      when nil, "--help", "-h", "help"
        puts verify_usage
        return
      when "config"
        manifest_path = @argv.shift
        return run_verify_config(manifest_path)
      when "plan"
        plan_path = @argv.shift
        return run_verify_plan(plan_path)
      when "lifecycle"
        lifecycle_path = @argv.shift
        return run_verify_lifecycle(lifecycle_path)
      else
        raise "Unsupported verify target: #{subject}"
      end
    end

    def run_render
      subject = @argv.shift

      case subject
      when nil, "--help", "-h", "help"
        puts render_usage
        return
      when "manifest"
        manifest_path = @argv.shift
      else
        manifest_path = subject
      end

      return puts(render_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd render manifest <manifest.yaml> --output <directory>" if manifest_path.nil?

      output = parse_output_flag
      raise "Missing required flag: --output <directory>" if output.nil?
      raise "Usage: opsd render manifest <manifest.yaml> --output <directory>" unless @argv.empty?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      capability_validator.validate!(manifest)

      resolution = module_catalog.resolve(manifest.provider, lockfile_path: lock_path_for_manifest(manifest_path))
      module_lock = module_catalog.lock_data_for(resolution)
      scenario_id = Renderer.new(app_root: @app_root, workspace_root: resolution.fetch(:workspace_root)).render(
        manifest,
        output,
        module_lock: module_lock,
        module_source: resolution
      )
      module_catalog.write_lock(lock_path_for_manifest(manifest_path), resolution)

      puts "Rendered stack: #{output}"
      puts "Source scenario: #{scenario_id}"
      puts "Module release: #{resolution.fetch(:version)}"
      puts "Module commit: #{resolution.fetch(:commit)}"
      puts "Lock file: #{lock_path_for_manifest(manifest_path)}"
      puts
      puts "Next steps:"
      puts "  cd #{output}"
      puts "  tofu init -backend=false -input=false"
      puts "  tofu plan"
      puts "  tofu apply"
    end

    def run_export
      subject = @argv.shift

      case subject
      when nil, "--help", "-h", "help"
        puts export_usage
        return
      when "exit-pack"
        rendered_path = @argv.shift
        return puts(export_usage) if rendered_path.nil? || help_flag?(rendered_path) || help_requested?
        run_export_exit_pack(rendered_path)
      else
        raise "Unsupported export target: #{subject}"
      end
    end

    def run_add
      target = @argv.shift

      case target
      when nil, "--help", "-h", "help"
        puts add_usage
      when "compute-group"
        run_add_compute_group
      when "database"
        run_add_database
      when "cache"
        run_add_cache
      when "object-storage"
        run_add_object_storage
      when "cdn-endpoint"
        run_add_cdn_endpoint
      when "load-balancer"
        run_add_load_balancer
      when "node"
        run_add_node
      else
        raise "Unsupported add target: #{target}"
      end
    end

    def run_add_compute_group
      manifest_path = @argv.shift
      return puts(add_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd add compute-group <manifest.yaml> --id <compute-group-id> --role <role> --type <type> --profile <profile> [--replicas <count>] [--image <image>] [--port <port>] [--attach-to <load-balancer-id>] [--link <resource-id>]" if manifest_path.nil?

      options = {
        "replicas" => 1,
        "links" => [],
        "attach_to" => []
      }

      until @argv.empty?
        token = @argv.shift
        case token
        when "--id"
          options["id"] = @argv.shift
          raise "Missing value for --id" if options["id"].nil? || options["id"].empty?
        when "--role"
          options["role"] = @argv.shift
          raise "Missing value for --role" if options["role"].nil? || options["role"].empty?
        when "--type"
          options["type"] = @argv.shift
          raise "Missing value for --type" if options["type"].nil? || options["type"].empty?
        when "--profile"
          options["profile"] = @argv.shift
          raise "Missing value for --profile" if options["profile"].nil? || options["profile"].empty?
        when "--replicas"
          options["replicas"] = integer_option_value(token, @argv.shift)
        when "--image"
          options["image"] = @argv.shift
          raise "Missing value for --image" if options["image"].nil? || options["image"].empty?
        when "--port"
          options["port"] = integer_option_value(token, @argv.shift)
        when "--attach-to"
          load_balancer_id = @argv.shift
          raise "Missing value for --attach-to" if load_balancer_id.nil? || load_balancer_id.empty?

          options["attach_to"] << load_balancer_id unless options["attach_to"].include?(load_balancer_id)
        when "--link"
          resource_id = @argv.shift
          raise "Missing value for --link" if resource_id.nil? || resource_id.empty?

          options["links"] << resource_id unless options["links"].include?(resource_id)
        else
          raise "Unknown add compute-group option: #{token}"
        end
      end

      required = %w[id role type profile]
      raise "Usage: opsd add compute-group <manifest.yaml> --id <compute-group-id> --role <role> --type <type> --profile <profile> [--replicas <count>] [--image <image>] [--port <port>] [--attach-to <load-balancer-id>] [--link <resource-id>]" unless required.all? { |key| options.key?(key) }

      manifest = load_manifest(manifest_path)
      manifest.validate!

      if Array(manifest.spec["compute_groups"]).any? { |entry| entry.is_a?(Hash) && entry["id"] == options["id"] }
        raise "Compute group #{options['id']} already exists in #{manifest_path}"
      end

      options.delete("links") if options["links"].empty?
      options.delete("attach_to") if options["attach_to"].empty?

      manifest.spec["compute_groups"] << options

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Added compute group: #{options['id']} (#{options['role']})")
    end

    def run_add_database
      engine = @argv.shift
      return puts(add_usage) if engine.nil? || help_flag?(engine) || help_requested?
      raise "Usage: opsd add database <engine> <manifest.yaml> [--id <database-id>]" if engine.nil?

      manifest_path = @argv.shift
      return puts(add_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd add database <engine> <manifest.yaml> [--id <database-id>]" if manifest_path.nil?

      database_id = "db-main"
      until @argv.empty?
        token = @argv.shift
        case token
        when "--id"
          database_id = @argv.shift
          raise "Missing value for --id" if database_id.nil? || database_id.empty?
        else
          raise "Unknown add database option: #{token}"
        end
      end

      manifest = load_manifest(manifest_path)
      manifest.validate!
      ensure_provider_addon_supported!(manifest.provider, section_key: "databases", value: engine)

      if Array(manifest.spec["databases"]).any? { |entry| entry.is_a?(Hash) && entry["id"] == database_id }
        raise "Database #{database_id} already exists in #{manifest_path}"
      end

      manifest.spec["databases"] << {
        "id" => database_id,
        "engine" => engine,
        "profile" => "db-s-1vcpu-1gb"
      }

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Added database: #{database_id} (#{engine})")
    end

    def run_add_cache
      engine = @argv.shift
      return puts(add_usage) if engine.nil? || help_flag?(engine) || help_requested?
      raise "Usage: opsd add cache <engine> <manifest.yaml> [--id <cache-id>]" if engine.nil?

      manifest_path = @argv.shift
      return puts(add_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd add cache <engine> <manifest.yaml> [--id <cache-id>]" if manifest_path.nil?

      cache_id = "cache-main"
      until @argv.empty?
        token = @argv.shift
        case token
        when "--id"
          cache_id = @argv.shift
          raise "Missing value for --id" if cache_id.nil? || cache_id.empty?
        else
          raise "Unknown add cache option: #{token}"
        end
      end

      manifest = load_manifest(manifest_path)
      manifest.validate!
      ensure_provider_addon_supported!(manifest.provider, section_key: "caches", value: engine)

      if Array(manifest.spec["caches"]).any? { |entry| entry.is_a?(Hash) && entry["id"] == cache_id }
        raise "Cache #{cache_id} already exists in #{manifest_path}"
      end

      manifest.spec["caches"] << {
        "id" => cache_id,
        "engine" => engine,
        "profile" => "db-s-1vcpu-1gb"
      }

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Added cache: #{cache_id} (#{engine})")
    end

    def run_add_object_storage
      manifest_path = @argv.shift
      return puts(add_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd add object-storage <manifest.yaml> [--id <storage-id>] [--visibility <public|private>]" if manifest_path.nil?

      storage_id = "assets-main"
      visibility = "private"
      until @argv.empty?
        token = @argv.shift
        case token
        when "--id"
          storage_id = @argv.shift
          raise "Missing value for --id" if storage_id.nil? || storage_id.empty?
        when "--visibility"
          visibility = @argv.shift
          raise "Missing value for --visibility" if visibility.nil? || visibility.empty?
        else
          raise "Unknown add object-storage option: #{token}"
        end
      end

      manifest = load_manifest(manifest_path)
      manifest.validate!
      ensure_provider_addon_supported!(manifest.provider, section_key: "object_storage", value: "spaces")

      if Array(manifest.spec["object_storage"]).any? { |entry| entry.is_a?(Hash) && entry["id"] == storage_id }
        raise "Object storage #{storage_id} already exists in #{manifest_path}"
      end

      manifest.spec["object_storage"] << {
        "id" => storage_id,
        "profile" => "standard",
        "visibility" => visibility
      }

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Added object storage: #{storage_id} (#{visibility})")
    end

    def run_add_cdn_endpoint
      manifest_path = @argv.shift
      return puts(add_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd add cdn-endpoint <manifest.yaml> --origin <object-storage-id> [--id <cdn-endpoint-id>] [--visibility <public|private>] [--domain <domain>] [--record <record>]" if manifest_path.nil?

      options = {
        "id" => "assets-cdn",
        "visibility" => "public"
      }

      until @argv.empty?
        token = @argv.shift
        case token
        when "--id"
          options["id"] = @argv.shift
          raise "Missing value for --id" if options["id"].nil? || options["id"].empty?
        when "--origin"
          options["origin"] = @argv.shift
          raise "Missing value for --origin" if options["origin"].nil? || options["origin"].empty?
        when "--visibility"
          options["visibility"] = @argv.shift
          raise "Missing value for --visibility" if options["visibility"].nil? || options["visibility"].empty?
        when "--domain"
          options["domain"] = @argv.shift
          raise "Missing value for --domain" if options["domain"].nil? || options["domain"].empty?
        when "--record"
          options["record"] = @argv.shift
          raise "Missing value for --record" if options["record"].nil? || options["record"].empty?
        else
          raise "Unknown add cdn-endpoint option: #{token}"
        end
      end

      raise "Usage: opsd add cdn-endpoint <manifest.yaml> --origin <object-storage-id> [--id <cdn-endpoint-id>] [--visibility <public|private>] [--domain <domain>] [--record <record>]" unless options.key?("origin")
      raise "Cannot use --record without --domain" if options.key?("record") && !options.key?("domain")

      manifest = load_manifest(manifest_path)
      manifest.validate!
      ensure_provider_addon_supported!(manifest.provider, section_key: "cdn_endpoints", value: "cdn")

      if Array(manifest.spec["cdn_endpoints"]).any? { |entry| entry.is_a?(Hash) && entry["id"] == options["id"] }
        raise "CDN endpoint #{options['id']} already exists in #{manifest_path}"
      end

      unless Array(manifest.spec["object_storage"]).any? { |entry| entry.is_a?(Hash) && entry["id"] == options["origin"] }
        raise "Object storage #{options['origin']} does not exist in #{manifest_path}"
      end

      entry = {
        "id" => options["id"],
        "origin" => options["origin"],
        "visibility" => options["visibility"]
      }

      if options.key?("domain")
        entry["dns"] = {
          "enabled" => true,
          "domain" => options["domain"],
          "record" => options["record"] || "assets"
        }
      end

      manifest.spec["cdn_endpoints"] << entry

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Added CDN endpoint: #{options['id']} (#{options['visibility']})")
    end

    def run_add_load_balancer
      manifest_path = @argv.shift
      return puts(add_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd add load-balancer <manifest.yaml> --id <load-balancer-id> --visibility <public|private> --port <port> --target-port <port> [--protocol <protocol>]" if manifest_path.nil?

      options = {
        "protocol" => "http"
      }

      until @argv.empty?
        token = @argv.shift
        case token
        when "--id"
          options["id"] = @argv.shift
          raise "Missing value for --id" if options["id"].nil? || options["id"].empty?
        when "--visibility"
          options["visibility"] = @argv.shift
          raise "Missing value for --visibility" if options["visibility"].nil? || options["visibility"].empty?
        when "--protocol"
          options["protocol"] = @argv.shift
          raise "Missing value for --protocol" if options["protocol"].nil? || options["protocol"].empty?
        when "--port"
          options["port"] = integer_option_value(token, @argv.shift)
        when "--target-port"
          options["target_port"] = integer_option_value(token, @argv.shift)
        else
          raise "Unknown add load-balancer option: #{token}"
        end
      end

      required = %w[id visibility port target_port]
      raise "Usage: opsd add load-balancer <manifest.yaml> --id <load-balancer-id> --visibility <public|private> --port <port> --target-port <port> [--protocol <protocol>]" unless required.all? { |key| options.key?(key) }

      manifest = load_manifest(manifest_path)
      manifest.validate!
      ensure_provider_addon_supported!(manifest.provider, section_key: "load_balancers", value: options.fetch("visibility"))

      if Array(manifest.spec["load_balancers"]).any? { |entry| entry.is_a?(Hash) && entry["id"] == options["id"] }
        raise "Load balancer #{options['id']} already exists in #{manifest_path}"
      end

      manifest.spec["load_balancers"] << options

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Added load balancer: #{options['id']} (#{options['visibility']})")
    end

    def run_add_node
      type = @argv.shift
      return puts(add_usage) if type.nil? || help_flag?(type) || help_requested?
      raise "Usage: opsd add node <type> <manifest.yaml> --id <node-id> --role <role> --profile <profile> [--image <image>]" if type.nil?

      manifest_path = @argv.shift
      return puts(add_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd add node <type> <manifest.yaml> --id <node-id> --role <role> --profile <profile> [--image <image>]" if manifest_path.nil?

      options = {
        "type" => type,
        "image" => "ubuntu-24-04"
      }

      until @argv.empty?
        token = @argv.shift
        case token
        when "--id"
          options["id"] = @argv.shift
          raise "Missing value for --id" if options["id"].nil? || options["id"].empty?
        when "--role"
          options["role"] = @argv.shift
          raise "Missing value for --role" if options["role"].nil? || options["role"].empty?
        when "--profile"
          options["profile"] = @argv.shift
          raise "Missing value for --profile" if options["profile"].nil? || options["profile"].empty?
        when "--image"
          options["image"] = @argv.shift
          raise "Missing value for --image" if options["image"].nil? || options["image"].empty?
        else
          raise "Unknown add node option: #{token}"
        end
      end

      required = %w[id role profile]
      raise "Usage: opsd add node <type> <manifest.yaml> --id <node-id> --role <role> --profile <profile> [--image <image>]" unless required.all? { |key| options.key?(key) }

      manifest = load_manifest(manifest_path)
      manifest.validate!
      ensure_provider_addon_supported!(manifest.provider, section_key: "nodes", value: type)

      if Array(manifest.spec["nodes"]).any? { |entry| entry.is_a?(Hash) && entry["id"] == options["id"] }
        raise "Node #{options['id']} already exists in #{manifest_path}"
      end

      manifest.spec["nodes"] << options

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Added node: #{options['id']} (#{type})")
    end

    def run_resize
      target = @argv.shift

      case target
      when nil, "--help", "-h", "help"
        puts resize_usage
      when "compute-group"
        run_resize_compute_group
      when "cache"
        run_resize_cache
      when "database"
        run_resize_database
      else
        raise "Unsupported resize target: #{target}"
      end
    end

    def run_resize_compute_group
      manifest_path = @argv.shift
      compute_group_id = @argv.shift
      return puts(resize_usage) if manifest_path.nil? || compute_group_id.nil? || help_flag?(manifest_path) || help_flag?(compute_group_id) || help_requested?
      raise "Usage: opsd resize compute-group <manifest.yaml> <compute-group-id> --profile <profile>" if manifest_path.nil? || compute_group_id.nil?

      profile = nil
      until @argv.empty?
        token = @argv.shift
        case token
        when "--profile"
          profile = @argv.shift
          raise "Missing value for --profile" if profile.nil? || profile.empty?
        else
          raise "Unknown resize compute-group option: #{token}"
        end
      end

      raise "Usage: opsd resize compute-group <manifest.yaml> <compute-group-id> --profile <profile>" if profile.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!

      compute_group = Array(manifest.spec["compute_groups"]).find { |entry| entry.is_a?(Hash) && entry["id"] == compute_group_id }
      raise "Compute group #{compute_group_id} not found in #{manifest_path}" if compute_group.nil?

      compute_group["profile"] = profile

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      puts "Updated manifest: #{manifest_path}"
      puts "Resized compute group: #{compute_group_id} -> #{profile}"
      puts
      puts "Next steps:"
      puts "  opsd validate manifest #{manifest_path}"
      puts "  opsd render manifest #{manifest_path} --output <directory>"
    end

    def run_resize_database
      manifest_path = @argv.shift
      database_id = @argv.shift
      return puts(resize_usage) if manifest_path.nil? || database_id.nil? || help_flag?(manifest_path) || help_flag?(database_id) || help_requested?
      raise "Usage: opsd resize database <manifest.yaml> <database-id> --profile <profile>" if manifest_path.nil? || database_id.nil?

      profile = nil
      until @argv.empty?
        token = @argv.shift
        case token
        when "--profile"
          profile = @argv.shift
          raise "Missing value for --profile" if profile.nil? || profile.empty?
        else
          raise "Unknown resize database option: #{token}"
        end
      end

      raise "Usage: opsd resize database <manifest.yaml> <database-id> --profile <profile>" if profile.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!

      database = Array(manifest.spec["databases"]).find { |entry| entry.is_a?(Hash) && entry["id"] == database_id }
      raise "Database #{database_id} not found in #{manifest_path}" if database.nil?

      database["profile"] = profile

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      puts "Updated manifest: #{manifest_path}"
      puts "Resized database: #{database_id} -> #{profile}"
      puts
      puts "Next steps:"
      puts "  opsd validate manifest #{manifest_path}"
      puts "  opsd render manifest #{manifest_path} --output <directory>"
    end

    def run_resize_cache
      manifest_path = @argv.shift
      cache_id = @argv.shift
      return puts(resize_usage) if manifest_path.nil? || cache_id.nil? || help_flag?(manifest_path) || help_flag?(cache_id) || help_requested?
      raise "Usage: opsd resize cache <manifest.yaml> <cache-id> --profile <profile>" if manifest_path.nil? || cache_id.nil?

      profile = nil
      until @argv.empty?
        token = @argv.shift
        case token
        when "--profile"
          profile = @argv.shift
          raise "Missing value for --profile" if profile.nil? || profile.empty?
        else
          raise "Unknown resize cache option: #{token}"
        end
      end

      raise "Usage: opsd resize cache <manifest.yaml> <cache-id> --profile <profile>" if profile.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!

      cache = Array(manifest.spec["caches"]).find { |entry| entry.is_a?(Hash) && entry["id"] == cache_id }
      raise "Cache #{cache_id} not found in #{manifest_path}" if cache.nil?

      cache["profile"] = profile

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      puts "Updated manifest: #{manifest_path}"
      puts "Resized cache: #{cache_id} -> #{profile}"
      puts
      puts "Next steps:"
      puts "  opsd validate manifest #{manifest_path}"
      puts "  opsd render manifest #{manifest_path} --output <directory>"
    end

    def run_scale
      target = @argv.shift

      case target
      when nil, "--help", "-h", "help"
        puts scale_usage
      when "compute-group"
        run_scale_compute_group
      else
        raise "Unsupported scale target: #{target}"
      end
    end

    def run_scale_compute_group
      manifest_path = @argv.shift
      compute_group_id = @argv.shift
      return puts(scale_usage) if manifest_path.nil? || compute_group_id.nil? || help_flag?(manifest_path) || help_flag?(compute_group_id) || help_requested?
      raise "Usage: opsd scale compute-group <manifest.yaml> <compute-group-id> --replicas <count>" if manifest_path.nil? || compute_group_id.nil?

      replicas = nil
      until @argv.empty?
        token = @argv.shift
        case token
        when "--replicas"
          value = @argv.shift
          raise "Missing value for --replicas" if value.nil? || value.empty?

          begin
            replicas = Integer(value, 10)
          rescue ArgumentError
            raise "--replicas must be an integer"
          end
        else
          raise "Unknown scale compute-group option: #{token}"
        end
      end

      raise "Usage: opsd scale compute-group <manifest.yaml> <compute-group-id> --replicas <count>" if replicas.nil?
      raise "--replicas must be at least 1" if replicas < 1

      manifest = load_manifest(manifest_path)
      manifest.validate!

      compute_group = Array(manifest.spec["compute_groups"]).find { |entry| entry.is_a?(Hash) && entry["id"] == compute_group_id }
      raise "Compute group #{compute_group_id} not found in #{manifest_path}" if compute_group.nil?

      compute_group["replicas"] = replicas

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      puts "Updated manifest: #{manifest_path}"
      puts "Scaled compute group: #{compute_group_id} -> #{replicas} replicas"
      puts
      puts "Next steps:"
      puts "  opsd validate manifest #{manifest_path}"
      puts "  opsd render manifest #{manifest_path} --output <directory>"
    end

    def run_remove
      target = @argv.shift

      case target
      when nil, "--help", "-h", "help"
        puts remove_usage
      when "compute-group"
        run_remove_compute_group
      when "database"
        run_remove_database
      when "cache"
        run_remove_cache
      when "object-storage"
        run_remove_object_storage
      when "load-balancer"
        run_remove_load_balancer
      when "cdn-endpoint"
        run_remove_cdn_endpoint
      when "node"
        run_remove_node
      else
        raise "Unsupported remove target: #{target}"
      end
    end

    def run_export_exit_pack(rendered_path)
      output_path = nil
      until @argv.empty?
        token = @argv.shift
        case token
        when "--output"
          output_path = @argv.shift
          raise "Missing value for --output" if output_path.nil? || output_path.empty?
        else
          raise "Unknown export exit-pack option: #{token}"
        end
      end

      raise "Usage: opsd export exit-pack <rendered-directory> --output <archive.tar.gz>" if output_path.nil?

      metadata = exit_pack_exporter.export(rendered_path, output_path)

      puts "Exported exit pack: #{output_path}"
      puts "Source directory: #{rendered_path}"
      puts "OPSd version: #{metadata.fetch('opsd_version')}"
      puts "Artifacts: #{metadata.fetch('artifacts').map { |artifact| artifact.fetch('path') }.join(', ')}"
    end

    def run_remove_compute_group
      manifest_path = @argv.shift
      compute_group_id = @argv.shift
      return puts(remove_usage) if manifest_path.nil? || compute_group_id.nil? || help_flag?(manifest_path) || help_flag?(compute_group_id) || help_requested?
      raise "Usage: opsd remove compute-group <manifest.yaml> <compute-group-id>" if manifest_path.nil? || compute_group_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      remove_resource_by_id!(manifest, section_key: "compute_groups", resource_id: compute_group_id, label: "Compute group", manifest_path: manifest_path)
      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Removed compute group: #{compute_group_id}")
    end

    def run_remove_database
      manifest_path = @argv.shift
      database_id = @argv.shift
      return puts(remove_usage) if manifest_path.nil? || database_id.nil? || help_flag?(manifest_path) || help_flag?(database_id) || help_requested?
      raise "Usage: opsd remove database <manifest.yaml> <database-id>" if manifest_path.nil? || database_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      remove_resource_by_id!(manifest, section_key: "databases", resource_id: database_id, label: "Database", manifest_path: manifest_path)
      cleanup_references_for_removed_resource!(manifest, section_key: "databases", resource_id: database_id)
      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Removed database: #{database_id}")
    end

    def run_remove_cache
      manifest_path = @argv.shift
      cache_id = @argv.shift
      return puts(remove_usage) if manifest_path.nil? || cache_id.nil? || help_flag?(manifest_path) || help_flag?(cache_id) || help_requested?
      raise "Usage: opsd remove cache <manifest.yaml> <cache-id>" if manifest_path.nil? || cache_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      remove_resource_by_id!(manifest, section_key: "caches", resource_id: cache_id, label: "Cache", manifest_path: manifest_path)
      cleanup_references_for_removed_resource!(manifest, section_key: "caches", resource_id: cache_id)
      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Removed cache: #{cache_id}")
    end

    def run_remove_object_storage
      manifest_path = @argv.shift
      storage_id = @argv.shift
      return puts(remove_usage) if manifest_path.nil? || storage_id.nil? || help_flag?(manifest_path) || help_flag?(storage_id) || help_requested?
      raise "Usage: opsd remove object-storage <manifest.yaml> <storage-id>" if manifest_path.nil? || storage_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      remove_resource_by_id!(manifest, section_key: "object_storage", resource_id: storage_id, label: "Object storage", manifest_path: manifest_path)
      cleanup_references_for_removed_resource!(manifest, section_key: "object_storage", resource_id: storage_id)
      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Removed object storage: #{storage_id}")
    end

    def run_remove_load_balancer
      manifest_path = @argv.shift
      load_balancer_id = @argv.shift
      return puts(remove_usage) if manifest_path.nil? || load_balancer_id.nil? || help_flag?(manifest_path) || help_flag?(load_balancer_id) || help_requested?
      raise "Usage: opsd remove load-balancer <manifest.yaml> <load-balancer-id>" if manifest_path.nil? || load_balancer_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      remove_resource_by_id!(manifest, section_key: "load_balancers", resource_id: load_balancer_id, label: "Load balancer", manifest_path: manifest_path)
      cleanup_references_for_removed_resource!(manifest, section_key: "load_balancers", resource_id: load_balancer_id)
      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Removed load balancer: #{load_balancer_id}")
    end

    def run_remove_cdn_endpoint
      manifest_path = @argv.shift
      endpoint_id = @argv.shift
      return puts(remove_usage) if manifest_path.nil? || endpoint_id.nil? || help_flag?(manifest_path) || help_flag?(endpoint_id) || help_requested?
      raise "Usage: opsd remove cdn-endpoint <manifest.yaml> <cdn-endpoint-id>" if manifest_path.nil? || endpoint_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      remove_resource_by_id!(manifest, section_key: "cdn_endpoints", resource_id: endpoint_id, label: "CDN endpoint", manifest_path: manifest_path)
      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Removed CDN endpoint: #{endpoint_id}")
    end

    def run_remove_node
      manifest_path = @argv.shift
      node_id = @argv.shift
      return puts(remove_usage) if manifest_path.nil? || node_id.nil? || help_flag?(manifest_path) || help_flag?(node_id) || help_requested?
      raise "Usage: opsd remove node <manifest.yaml> <node-id>" if manifest_path.nil? || node_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!
      remove_resource_by_id!(manifest, section_key: "nodes", resource_id: node_id, label: "Node", manifest_path: manifest_path)
      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Removed node: #{node_id}")
    end

    def run_attach
      target = @argv.shift

      case target
      when nil, "--help", "-h", "help"
        puts attach_usage
      when "compute-group"
        run_attach_compute_group
      else
        raise "Unsupported attach target: #{target}"
      end
    end

    def run_attach_compute_group
      manifest_path = @argv.shift
      compute_group_id = @argv.shift
      return puts(attach_usage) if manifest_path.nil? || compute_group_id.nil? || help_flag?(manifest_path) || help_flag?(compute_group_id) || help_requested?
      raise "Usage: opsd attach compute-group <manifest.yaml> <compute-group-id> --to <load-balancer-id>" if manifest_path.nil? || compute_group_id.nil?

      load_balancer_id = nil
      until @argv.empty?
        token = @argv.shift
        case token
        when "--to"
          load_balancer_id = @argv.shift
          raise "Missing value for --to" if load_balancer_id.nil? || load_balancer_id.empty?
        else
          raise "Unknown attach compute-group option: #{token}"
        end
      end

      raise "Usage: opsd attach compute-group <manifest.yaml> <compute-group-id> --to <load-balancer-id>" if load_balancer_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!

      compute_group = Array(manifest.spec["compute_groups"]).find { |entry| entry.is_a?(Hash) && entry["id"] == compute_group_id }
      raise "Compute group #{compute_group_id} not found in #{manifest_path}" if compute_group.nil?

      load_balancer = Array(manifest.spec["load_balancers"]).find { |entry| entry.is_a?(Hash) && entry["id"] == load_balancer_id }
      raise "Load balancer #{load_balancer_id} not found in #{manifest_path}" if load_balancer.nil?

      compute_group["attach_to"] = Array(compute_group["attach_to"])
      compute_group["attach_to"] << load_balancer_id unless compute_group["attach_to"].include?(load_balancer_id)

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Attached compute group: #{compute_group_id} -> #{load_balancer_id}")
    end

    def run_detach
      target = @argv.shift

      case target
      when nil, "--help", "-h", "help"
        puts detach_usage
      when "compute-group"
        run_detach_compute_group
      else
        raise "Unsupported detach target: #{target}"
      end
    end

    def run_detach_compute_group
      manifest_path = @argv.shift
      compute_group_id = @argv.shift
      return puts(detach_usage) if manifest_path.nil? || compute_group_id.nil? || help_flag?(manifest_path) || help_flag?(compute_group_id) || help_requested?
      raise "Usage: opsd detach compute-group <manifest.yaml> <compute-group-id> --from <load-balancer-id>" if manifest_path.nil? || compute_group_id.nil?

      load_balancer_id = nil
      until @argv.empty?
        token = @argv.shift
        case token
        when "--from"
          load_balancer_id = @argv.shift
          raise "Missing value for --from" if load_balancer_id.nil? || load_balancer_id.empty?
        else
          raise "Unknown detach compute-group option: #{token}"
        end
      end

      raise "Usage: opsd detach compute-group <manifest.yaml> <compute-group-id> --from <load-balancer-id>" if load_balancer_id.nil?

      manifest = load_manifest(manifest_path)
      manifest.validate!

      compute_group = Array(manifest.spec["compute_groups"]).find { |entry| entry.is_a?(Hash) && entry["id"] == compute_group_id }
      raise "Compute group #{compute_group_id} not found in #{manifest_path}" if compute_group.nil?

      attachments = Array(compute_group["attach_to"])
      raise "Compute group #{compute_group_id} is not attached to load balancer #{load_balancer_id}" unless attachments.include?(load_balancer_id)

      compute_group["attach_to"] = attachments.reject { |entry| entry == load_balancer_id }
      compute_group.delete("attach_to") if compute_group["attach_to"].empty?

      capability_validator_for(manifest.provider).validate!(manifest)
      manifest.validate!
      write_manifest(manifest)

      print_manifest_update_next_steps(manifest_path, "Detached compute group: #{compute_group_id} -/-> #{load_balancer_id}")
    end

    def print_blueprints
      ensure_provider_supported_for_catalog!

      puts "Blueprint Catalog"
      puts "Provider: #{effective_provider}"
      puts
      entries = template_store.blueprint_entries(provider: effective_provider)

      entries.each_with_index do |blueprint, index|
        variant_ids = blueprint[:variants].map { |variant| variant.fetch("id") }
        puts "  #{blueprint[:id]}"
        puts "    title: #{blueprint[:title]}"
        puts "    description: #{blueprint[:description]}"
        puts "    variants: #{variant_ids.join(', ')}"
        puts unless index == entries.length - 1
      end

      puts
      puts "Next steps:"
      puts "  opsd describe blueprint <blueprint> [--variant <variant>]"
      puts "  opsd init blueprint <blueprint> [output.yaml] [--variant <variant>]"
    end

    def print_blueprint_details(blueprint, requested_variant_id:, profile_catalog:, addons_catalog:)
      puts "Blueprint: #{blueprint[:title]}"
      puts "ID: #{blueprint[:id]}"
      puts "Provider: #{blueprint[:provider]}"
      puts "Description: #{blueprint[:description]}" unless blueprint[:description].to_s.empty?
      usecases = Array(blueprint[:usecases])
      puts "Use cases: #{usecases.join(', ')}" unless usecases.empty?
      puts
      puts "Variants:"

      variants =
        if requested_variant_id
          selected = blueprint[:variants].find { |variant| variant.fetch("id") == requested_variant_id }
          raise "Unsupported variant #{requested_variant_id} for blueprint #{blueprint[:id]}" if selected.nil?

          [selected]
        else
          blueprint[:variants]
        end

      variants.each_with_index do |variant, index|
        puts "  #{variant.fetch('id')}"
        title = variant.fetch("title", "").to_s
        description = variant.fetch("description", "")
        merged_description = [title, description].reject(&:empty?).join(". ")
        puts "    description: #{merged_description}" unless merged_description.empty?
        components = Array(variant["components"])
        if requested_variant_id.nil?
          if components.empty?
            # no-op
          elsif components.length == 1
            puts "    component: #{components.first}"
          else
            puts "    components:"
            components.each { |component| puts "      - #{component}" }
          end
        else
          if components.empty?
            # no-op
          elsif components.length == 1
            puts "    component: #{components.first}"
          else
            puts "    components:"
            components.each { |component| puts "      - #{component}" }
          end

          changes = summarize_variant_in_place_changes(variant)
          unless changes.empty?
            puts "    allowed customizations:"
            changes.each { |line| puts "      - #{line}" }
          end

          addons = summarize_variant_optional_addons(variant, addons_catalog)
          unless addons.empty?
            puts "    optional add-ons:"
            addons.each { |line| puts "      - #{line}" }
          end
        end
        puts unless index == variants.length - 1
      end

      puts
      puts "Next step:"
      if requested_variant_id
        puts "  opsd init blueprint #{blueprint[:id]} [output.yaml] --variant #{requested_variant_id}"
      else
        puts "  opsd describe blueprint #{blueprint[:id]} [--variant <variant>]"
        puts "  opsd init blueprint #{blueprint[:id]} [output.yaml] [--variant <variant>]"
      end
    end

    def render_blueprint_manifest(blueprint, variant, resolution:)
      YAML.dump(materialize_v2_blueprint_manifest_data(blueprint, variant, resolution: resolution))
    end

    def materialize_v2_blueprint_manifest_data(blueprint, variant, resolution:)
      manifest = variant.fetch("manifest", nil)
      unless manifest.is_a?(Hash)
        raise "Blueprint #{blueprint[:id]} variant #{variant.fetch('id')} must define variant.manifest as a v2 bootstrap mapping"
      end

      data = materialize_v2_blueprint_manifest_hash(blueprint, variant, manifest, resolution)
      normalize_droplet_public_ingress_ports!(data)
      normalize_droplet_security_egress!(data)
    end

    def materialize_v2_blueprint_manifest_hash(blueprint, variant, manifest_fragment, resolution)
      metadata_name = "#{blueprint[:id]}-#{variant.fetch('id')}"
      spec_fragment = deep_clone(manifest_fragment)
      defaults = spec_fragment["defaults"].is_a?(Hash) ? spec_fragment["defaults"] : {}
      defaults["project"] ||= metadata_name
      defaults["network"] ||= "shared"
      defaults["dns_zone"] ||= manifest_dns_zone(spec_fragment)

      data = {
        "apiVersion" => "opsd.io/v2alpha1",
        "kind" => "Environment",
        "metadata" => {
          "name" => metadata_name,
          "environment" => "development",
          "region" => "fra1",
          "tags" => ["managed-by-opsd"],
          "labels" => {}
        },
        "spec" => {
          "provider" => effective_provider,
          "origin" => {
            "blueprint" => blueprint[:id],
            "variant" => variant.fetch("id"),
            "family" => variant.fetch("family"),
            "stack" => variant.fetch("stack"),
            "modules" => {
              "repo" => resolution.fetch(:repo),
              "version" => resolution.fetch(:version),
              "commit" => resolution.fetch(:commit)
            }
          },
          "defaults" => defaults,
          "compute_groups" => Array(spec_fragment["compute_groups"]),
          "nodes" => Array(spec_fragment["nodes"]),
          "databases" => Array(spec_fragment["databases"]),
          "caches" => Array(spec_fragment["caches"]),
          "load_balancers" => Array(spec_fragment["load_balancers"]),
          "object_storage" => Array(spec_fragment["object_storage"]),
          "cdn_endpoints" => Array(spec_fragment["cdn_endpoints"]),
          "layers" => deep_clone(spec_fragment["layers"].is_a?(Hash) ? spec_fragment["layers"] : {}),
          "policies" => default_v2_policies.merge(spec_fragment["policies"].is_a?(Hash) ? spec_fragment["policies"] : {})
        }
      }

      data
    end

    def normalize_droplet_public_ingress_ports!(manifest_data)
      return manifest_data unless manifest_data.is_a?(Hash)
      return manifest_data unless manifest_data.dig("spec", "origin", "family") == "droplet"

      Array(manifest_data.dig("spec", "compute_groups")).each do |entry|
        normalize_public_ingress_ports_for_entry!(entry)
      end

      Array(manifest_data.dig("spec", "nodes")).each do |entry|
        normalize_public_ingress_ports_for_entry!(entry)
      end

      manifest_data
    end

    def normalize_droplet_security_egress!(manifest_data)
      return manifest_data unless manifest_data.dig("spec", "origin", "family") == "droplet"

      %w[compute_groups nodes].each do |section_key|
        Array(manifest_data.dig("spec", section_key)).each do |entry|
          next unless entry.is_a?(Hash)

          security = entry["security"]
          next if security.is_a?(Hash) && security.dig("egress", "preset")

          public = entry.fetch("exposure", {}).fetch("public", true)
          entry["security"] = {
            "egress" => {
              "preset" => public ? "web" : "open"
            }
          }
        end
      end

      manifest_data
    end

    def normalize_public_ingress_ports_for_entry!(entry)
      return unless entry.is_a?(Hash)

      exposure = entry["exposure"]
      return unless exposure.is_a?(Hash)
      return unless exposure.fetch("public", true)
      return if exposure["ports"].is_a?(Array) && !exposure["ports"].empty?

      exposure["ports"] = default_public_ingress_ports_for_entry(entry)
    end

    def default_public_ingress_ports_for_entry(entry)
      port = entry["port"]
      return [port] if port.is_a?(Integer) && port.positive?

      role = entry["role"].to_s
      return [22] if role == "bastion"

      [80, 443]
    end

    def run_blueprint_wizard(manifest_data, blueprint, variant)
      wizard_fields = Array(variant["wizard"].is_a?(Hash) ? variant["wizard"]["fields"] : nil)
      return manifest_data if wizard_fields.empty?

      ensure_interactive_wizard!

      answers = {}
      wizard_fields.each do |field_id|
        definition = WizardCatalog.field(field_id)
        next unless wizard_field_visible?(definition, answers, manifest_data)

        current_value = wizard_field_current_value(manifest_data, definition)
        current_value = nil unless wizard_field_current_value_usable?(current_value, definition)
        current_value = definition[:default] if current_value.nil? && definition.key?(:default)
        value = prompt_wizard_field(definition, current_value)
        next if value == :skip

        apply_wizard_value!(manifest_data, definition, value)
        answers[field_id] = value
      end

      manifest_data
    end

    def ensure_interactive_wizard!
      return if $stdin.tty? && $stdout.tty?

      raise "Wizard mode requires an interactive terminal"
    end

    def wizard_field_visible?(definition, answers, manifest_data)
      conditions = definition[:when]
      return true unless conditions.is_a?(Hash)

      conditions.all? do |field_id, expected_value|
        current_value = answers.key?(field_id) ? answers[field_id] : wizard_field_current_value_by_id(manifest_data, field_id)
        current_value == expected_value
      end
    end

    def wizard_field_current_value(manifest_data, definition)
      targets = Array(definition[:targets])
      return nil if targets.empty?

      value_at_path(manifest_data, targets.first)
    end

    def wizard_field_current_value_by_id(manifest_data, field_id)
      definition = WizardCatalog.field(field_id)
      wizard_field_current_value(manifest_data, definition)
    end

    def wizard_field_current_value_usable?(value, definition)
      return false if value.nil?

      placeholders = Array(definition[:placeholder_values])
      return false if placeholders.include?(value)

      !(value.respond_to?(:empty?) && value.empty?)
    end

    def prompt_wizard_field(definition, current_value)
      label = definition.fetch(:label)
      description = definition[:description]
      type = definition.fetch(:type)

      case type
      when :enum
        prompt_enum_field(label, description, Array(definition[:choices]), current_value, definition)
      when :boolean
        prompt_boolean_field(label, description, current_value, definition)
      when :integer
        prompt_integer_field(label, description, current_value, definition)
      when :string, :secret
        prompt_string_field(label, description, current_value, definition)
      else
        raise "Unsupported wizard field type: #{type}"
      end
    end

    def prompt_enum_field(label, description, choices, current_value, definition)
      prompt_lines = [label]
      prompt_lines << description if description
      prompt_lines << "Options: #{choices.join(', ')}"
      prompt_lines << "Current: #{current_value}" if current_value

      value = prompt_with_text(prompt_lines.join("\n"), current_value, allow_blank: !definition.fetch(:required))
      return current_value if value.nil? && !definition.fetch(:required)
      validate_choice!(label, value, choices)
      value
    end

    def prompt_boolean_field(label, description, current_value, definition)
      prompt_lines = [label]
      prompt_lines << description if description
      prompt_lines << "Current: #{current_value ? 'yes' : 'no'}" unless current_value.nil?
      prompt_lines << "Answer y/n"

      value = prompt_with_text(prompt_lines.join("\n"), current_value, allow_blank: !definition.fetch(:required))
      return current_value if value.nil? && !definition.fetch(:required)
      return true if boolean_true?(value)
      return false if boolean_false?(value)

      raise "Invalid boolean for #{label}: #{value}"
    end

    def prompt_integer_field(label, description, current_value, definition)
      prompt_lines = [label]
      prompt_lines << description if description
      prompt_lines << "Current: #{current_value}" if current_value
      prompt_lines << "Min: #{definition[:min]}" if definition[:min]
      prompt_lines << "Max: #{definition[:max]}" if definition[:max]

      value = prompt_with_text(prompt_lines.join("\n"), current_value, allow_blank: !definition.fetch(:required))
      return current_value if value.nil? && !definition.fetch(:required)

      integer = Integer(value, 10)
      if definition[:min].is_a?(Integer) && integer < definition[:min]
        raise "Value for #{label} must be at least #{definition[:min]}"
      end
      if definition[:max].is_a?(Integer) && integer > definition[:max]
        raise "Value for #{label} must be at most #{definition[:max]}"
      end

      integer
    rescue ArgumentError
      raise "Invalid integer for #{label}: #{value}"
    end

    def prompt_string_field(label, description, current_value, definition)
      prompt_lines = [label]
      prompt_lines << description if description
      prompt_lines << "Current: #{current_value}" if current_value

      value = prompt_with_text(prompt_lines.join("\n"), current_value, allow_blank: !definition.fetch(:required))
      return current_value if value.nil? && !definition.fetch(:required)
      raise "Value for #{label} is required" if definition.fetch(:required) && (value.nil? || value.strip.empty?)

      value
    end

    def prompt_with_text(text, default, allow_blank:)
      print "#{text}\n> "
      response = $stdin.gets
      return default if response.nil?

      value = response.strip
      return default if value.empty? && !default.nil?
      return nil if value.empty? && allow_blank

      value
    end

    def validate_choice!(label, value, choices)
      return if choices.include?(value)

      raise "Invalid choice for #{label}: #{value}. Allowed values: #{choices.join(', ')}"
    end

    def boolean_true?(value)
      %w[y yes true 1].include?(value.to_s.downcase)
    end

    def boolean_false?(value)
      %w[n no false 0].include?(value.to_s.downcase)
    end

    def apply_wizard_value!(manifest_data, definition, value)
      Array(definition[:targets]).each do |path|
        set_value_at_path!(manifest_data, path, value)
      end
    end

    def value_at_path(data, path)
      keys = Array(path)
      return data if keys.empty?

      head, *tail = keys
      return nil unless data.is_a?(Hash) || data.is_a?(Array)

      next_value =
        if data.is_a?(Array)
          data[head.to_i]
        else
          data[head]
        end

      return next_value if tail.empty?

      value_at_path(next_value, tail)
    end

    def set_value_at_path!(data, path, value)
      keys = Array(path)
      raise "Cannot assign an empty path" if keys.empty?

      assign_path!(data, keys, value)
    end

    def assign_path!(container, keys, value)
      key = keys.shift

      if keys.empty?
        if container.is_a?(Array)
          container[key.to_i] = value
        else
          container[key] = value
        end
        return
      end

      next_key = keys.first

      if container.is_a?(Array)
        index = key.to_i
        container[index] ||= container_key_container(next_key)
        assign_path!(container[index], keys, value)
      else
        container[key] ||= container_key_container(next_key)
        assign_path!(container[key], keys, value)
      end
    end

    def container_key_container(next_key)
      next_key.to_s.match?(/\A\d+\z/) ? [] : {}
    end

    def default_v2_policies
      {
        "drift_detection" => "strict",
        "managed_output" => true
      }
    end

    def manifest_dns_zone(spec_fragment)
      exposure_sources = []
      exposure_sources.concat(Array(spec_fragment["compute_groups"]).filter_map { |entry| entry["exposure"] if entry.is_a?(Hash) })
      exposure_sources.concat(Array(spec_fragment["nodes"]).filter_map { |entry| entry["exposure"] if entry.is_a?(Hash) })
      exposure_sources.concat(Array(spec_fragment["load_balancers"]).filter_map { |entry| entry["dns"] if entry.is_a?(Hash) })
      exposure_sources.concat(Array(spec_fragment["cdn_endpoints"]).filter_map { |entry| entry["dns"] if entry.is_a?(Hash) })

      exposure_sources.each do |exposure|
        next unless exposure.is_a?(Hash)
        return exposure["domain"] unless exposure["domain"].nil? || exposure["domain"].to_s.empty?
      end

      nil
    end

    def deep_clone(value)
      Marshal.load(Marshal.dump(value))
    end

    def delivery_value(defaults, *keys)
      value = defaults.fetch("delivery", {})
      keys.each do |key|
        return nil unless value.is_a?(Hash)

        value = value[key]
      end
      value
    end

    def parse_output_flag
      flag = @argv.shift
      return nil unless flag == "--output"

      @argv.shift
    end

    def load_manifest(path)
      data = YAML.load_file(path)
      profile_catalog = manifest_profile_catalog(data.dig("spec", "provider"))
      Manifest.new(
        data,
        source_path: path,
        profile_catalog: profile_catalog,
        supported_providers: contract_store.active_provider_names
      )
    rescue Errno::ENOENT
      raise "Manifest file not found: #{path}"
    rescue Psych::SyntaxError => e
      raise "YAML syntax error in #{path}: #{e.message}"
    end

    def usage
      help_block(
        "Usage: opsd <command>",
        [
          [
            "Basics",
            [
              ["help", "Show help for commands"],
              ["version", "Print the CLI version"],
              ["completion", "Generate shell completion scripts or install a loader"],
              ["config", "Manage OPSd CLI context such as active provider"],
            ]
          ],
          [
            "Discovery",
            [
              ["list", "Browse blueprint catalog data discovered from workspace modules"],
              ["describe", "Show details for a specific blueprint"]
            ]
          ],
          [
            "Workflow",
            [
              ["init", "Create starter manifests from blueprints"],
              ["validate", "Validate a manifest or Kubernetes module metadata"],
              ["verify", "Verify config or plan against the OPSd contract"],
              ["render", "Render a manifest into a runnable OpenTofu stack"],
              ["export", "Package a rendered handoff into a portable exit pack"]
            ]
          ],
          [
            "Mutations",
            [
              ["add", "Add supported resources to an existing manifest"],
              ["resize", "Resize supported resources in an existing manifest"],
              ["scale", "Scale supported replicated resources"],
              ["attach", "Attach supported resources to each other"],
              ["detach", "Detach supported resources from each other"],
              ["remove", "Remove supported resources from an existing manifest"]
            ]
          ]
        ]
      )
    end

    def completion_usage
      help_block(
        "Usage: opsd completion <bash|zsh|fish>",
        [
          [
            "Commands",
            [
              ["install", "Install a completion loader or snapshot"]
            ]
          ],
          [
            "Shells",
            [
              ["bash", "Generate Bash completion"],
              ["zsh", "Generate Zsh completion"],
              ["fish", "Generate Fish completion"]
            ]
          ]
        ]
      )
    end

    def list_usage
      help_block(
        "Usage: opsd list blueprints",
        [
          [
            "Commands",
            [
              ["blueprints", "Browse blueprint catalog data discovered from workspace modules"]
            ]
          ]
        ]
      )
    end

    def bash_completion_script
      targets = completion_command_targets.join(" ")

      <<~BASH
        #{completion_blueprint_helpers(:bash)}
        _opsd_manifest_files() {
          local candidate
          local -a files=()

          shopt -s nullglob
          for candidate in *.yaml *.yml; do
            [[ -f "$candidate" ]] || continue
            files+=("$candidate")
          done
          shopt -u nullglob

          printf '%s\n' "${files[@]}"
        }

        _opsd_manifest_exact() {
          local current="${1:-}"
          local previous="${2:-}"
          local candidate
          local manifest
          local -a manifests=()

          while IFS= read -r manifest; do
            [[ -n "$manifest" ]] || continue
            manifests+=("$manifest")
          done < <(_opsd_manifest_files)
          for candidate in "$current" "$previous"; do
            [[ -n "$candidate" ]] || continue
            for manifest in "${manifests[@]}"; do
              [[ "$manifest" == "$candidate" ]] && return 0
            done
          done

          return 1
        }

        _opsd() {
          local cur prev words cword
          if declare -F _init_completion >/dev/null 2>&1; then
            _init_completion || return
          else
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"
            words=("${COMP_WORDS[@]}")
            cword="${COMP_CWORD}"
          fi

          local command_name="${words[1]-}"
          command_name="${command_name##*/}"
        local commands="#{completion_values(:commands)}"

          case "${command_name}" in
            completion)
              COMPREPLY=( $(compgen -W "#{completion_values(:completion)}" -- "$cur") )
              ;;
            config)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:config)}" -- "$cur") )
              elif [[ $cword -eq 4 && ${words[2]-} == profile && ${words[3]-} == create ]]; then
                if [[ -z "$cur" ]]; then
                  COMPREPLY=( $(compgen -W "profile-name" -- "$cur") )
                fi
              elif [[ $cword -eq 4 && ${words[2]-} == profile && ${words[3]-} =~ ^(show|edit|use)$ ]]; then
                COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_profiles))" -- "$cur") )
              elif [[ $cword -eq 3 && ${words[2]-} == profile ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:config_profile)}" -- "$cur") )
              fi
              ;;
            validate|render)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "manifest" -- "$cur") )
              elif [[ ${words[2]-} == manifest && $cword -ge 3 ]]; then
                if _opsd_manifest_exact "$cur" "${words[cword-1]-}"; then
                  COMPREPLY=()
                else
                  COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_manifest_files))" -- "$cur") )
                fi
              fi
              ;;
            verify)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:verify)}" -- "$cur") )
              elif [[ ${words[2]-} == config && $cword -ge 3 ]]; then
                if _opsd_manifest_exact "$cur" "${words[cword-1]-}"; then
                  COMPREPLY=()
                else
                  COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_manifest_files))" -- "$cur") )
                fi
              elif [[ ${words[2]-} == plan && $cword -ge 3 ]]; then
                if _opsd_manifest_exact "$cur" "${words[cword-1]-}"; then
                  COMPREPLY=()
                else
                  COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_manifest_files))" -- "$cur") )
                fi
              elif [[ ${words[2]-} == lifecycle && $cword -ge 3 ]]; then
                if _opsd_manifest_exact "$cur" "${words[cword-1]-}"; then
                  COMPREPLY=()
                else
                  COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_manifest_files))" -- "$cur") )
                fi
              fi
              ;;
            add)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:add)}" -- "$cur") )
              elif [[ ${words[2]-} == database && $cword -eq 3 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:add_database)}" -- "$cur") )
              elif [[ ${words[2]-} == cache && $cword -eq 3 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:add_cache)}" -- "$cur") )
              elif [[ ${words[2]-} == node && $cword -eq 3 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:add_node)}" -- "$cur") )
              fi
              ;;
            resize)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:resize)}" -- "$cur") )
              else
                COMPREPLY=( $(compgen -W "#{completion_values(:resize_options)}" -- "$cur") )
              fi
              ;;
            scale)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:scale)}" -- "$cur") )
              else
                COMPREPLY=( $(compgen -W "#{completion_values(:scale_options)}" -- "$cur") )
              fi
              ;;
            attach)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:attach)}" -- "$cur") )
              else
                COMPREPLY=( $(compgen -W "#{completion_values(:attach_options)}" -- "$cur") )
              fi
              ;;
            detach)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:detach)}" -- "$cur") )
              else
                COMPREPLY=( $(compgen -W "#{completion_values(:detach_options)}" -- "$cur") )
              fi
              ;;
            remove)
              if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{completion_values(:remove)}" -- "$cur") )
              fi
              ;;
            #{completion_blueprint_case_blocks(:bash)}
            *)
              COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
              ;;
          esac
        }

        complete -F _opsd #{targets}
      BASH
    end

    def zsh_completion_script
      targets = completion_command_targets.join(" ")

      <<~ZSH
        #compdef opsd

        #{completion_blueprint_helpers(:zsh)}
        _opsd_manifest_files() {
          local candidate
          local -a files=()

          setopt local_options null_glob
          for candidate in *.yaml *.yml; do
            [[ -f "$candidate" ]] || continue
            files+=("$candidate")
          done

          printf '%s\n' "${files[@]}"
        }

        _opsd_manifest_exact() {
          local current="$1"
          local previous="$2"
          local candidate
          local -a manifests

          manifests=("${(@f)$(_opsd_manifest_files)}")
          for candidate in "$current" "$previous"; do
            [[ -n "$candidate" ]] || continue
            for manifest in "${manifests[@]}"; do
              [[ "$manifest" == "$candidate" ]] && return 0
            done
          done

          return 1
        }

        _opsd() {
          local context state line
          typeset -A opt_args

          _arguments -C \
          '1:command:(#{completion_values(:commands)})' \
            '2:subcommand:->subcommand' \
            '3:argument:->argument' \
            '*::args:->args'

          local command_name="${line[1]##*/}"

          case $state in
            subcommand)
              case $command_name in
                completion) _values 'completion command' #{completion_values(:completion)} ;;
                config) _values 'config command' #{completion_values(:config)} ;;
                list) _values 'list topic' blueprints ;;
                describe) _values 'describe subject' blueprint ;;
                init) _values 'init subject' blueprint ;;
                validate|render) _values 'subject' #{completion_values(:validate_render)} ;;
                verify) _values 'verify target' #{completion_values(:verify)} ;;
                export) _values 'export target' #{completion_values(:export)} ;;
                add) _values 'add target' #{completion_values(:add)} ;;
                resize) _values 'resize target' #{completion_values(:resize)} ;;
                scale) _values 'scale target' #{completion_values(:scale)} ;;
                attach|detach) _values 'attach target' #{completion_values(:attach_detach)} ;;
                remove) _values 'remove target' #{completion_values(:remove)} ;;
              esac
              ;;
            argument|args)
              case "$line[1] $line[2]" in
                "config profile")
                  if [[ "$line[3]" == "create" ]]; then
                    if [[ -z "$line[4]" ]]; then
                      compadd -d 'Type a new profile name; replace profile-name with your own value.' -- profile-name
                    fi
                  elif [[ -n "$line[3]" && "$line[3]" =~ ^(show|edit|use)$ ]]; then
                    _message 'Type an existing profile name.'
                    compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_profiles))
                  elif (( CURRENT == 4 )); then
                    _values 'profile command' #{completion_values(:config_profile)}
                  fi
                  ;;
                "config profile use"|"config profile edit"|"config profile show")
                  if (( CURRENT == 4 )); then
                    compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_profiles))
                  fi
                  ;;
                "validate manifest"|"validate module"|"render manifest")
                  if (( CURRENT >= 4 )) && ! _opsd_manifest_exact "$line[CURRENT]" "$line[CURRENT-1]"; then
                    compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_manifest_files))
                  fi
                  ;;
                "verify config")
                  if (( CURRENT >= 4 )) && ! _opsd_manifest_exact "$line[CURRENT]" "$line[CURRENT-1]"; then
                    compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_manifest_files))
                  fi
                  ;;
                "verify plan")
                  if (( CURRENT >= 4 )) && ! _opsd_manifest_exact "$line[CURRENT]" "$line[CURRENT-1]"; then
                    compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_manifest_files))
                  fi
                  ;;
                "verify lifecycle")
                  if (( CURRENT >= 4 )) && ! _opsd_manifest_exact "$line[CURRENT]" "$line[CURRENT-1]"; then
                    compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_manifest_files))
                  fi
                  ;;
                "add database")
                  if (( CURRENT == 4 )); then
                    _values 'engine' #{completion_values(:add_database)}
                  fi
                  ;;
                "add cache")
                  if (( CURRENT == 4 )); then
                    _values 'engine' #{completion_values(:add_cache)}
                  fi
                  ;;
                "add node")
                  if (( CURRENT == 4 )); then
                    _values 'type' #{completion_values(:add_node)}
                  fi
                  ;;
                "resize compute-group"|"resize cache"|"resize database")
                  _values 'option' #{completion_values(:resize_options)}
                  ;;
                "scale compute-group")
                  _values 'option' #{completion_values(:scale_options)}
                  ;;
                "attach compute-group")
                  _values 'option' #{completion_values(:attach_options)}
                  ;;
                "detach compute-group")
                  _values 'option' #{completion_values(:detach_options)}
                  ;;
                #{completion_blueprint_case_blocks(:zsh)}
              esac
              ;;
          esac
        }

        compdef _opsd #{targets}
      ZSH
    end

    def fish_completion_script
      targets = completion_command_targets

      <<~FISH
        #{targets.map { |command| fish_completion_block(command) }.join("\n\n")}
      FISH
    end

    def fish_completion_block(command)
      <<~FISH.chomp
        function _opsd_manifest_files
            set -l candidate
            set -l files

            for candidate in *.yaml *.yml
                test -f "$candidate"; or continue
                set files $files $candidate
            end

            printf '%s\n' $files
        end

        function _opsd_manifest_exact
            set -l current (commandline -ct)
            set -l previous
            set -l tokens (commandline -opc)
            set -l files (_opsd_manifest_files)

            if test (count $tokens) -gt 0
                set previous $tokens[-1]
            end

            for candidate in $current $previous
                if test -n "$candidate"
                    for manifest in $files
                        if test "$manifest" = "$candidate"
                            return 0
                        end
                    end
                end
            end

            return 1
        end

        function _opsd_manifest_suggestions
            set -l current (commandline -ct)
            set -l files (_opsd_manifest_files)
            set -l previous
            set -l tokens (commandline -opc)

            if test (count $tokens) -gt 0
                set previous $tokens[-1]
            end

            if _opsd_manifest_exact
                return 0
            end

            for candidate in $files
                if test "$candidate" != "$current" -a "$candidate" != "$previous"
                    printf '%s\n' "$candidate"
                end
            end
        end

        function _opsd_profiles
            set -l current (commandline -ct)
            set -l cache_root "$XDG_CACHE_HOME"
            if test -z "$cache_root"
                set cache_root "$HOME/.cache"
            end

            set -l cache_file "$cache_root/opsd/profiles.txt"
            if set -q __opsd_profiles_cache[1]
                for profile in $__opsd_profiles_cache
                    if test "$profile" != "$current"
                        printf '%s\n' "$profile"
                    end
                end
                return
            end

            if test -s "$cache_file"
                set -g __opsd_profiles_cache (cat "$cache_file")
                for profile in $__opsd_profiles_cache
                    if test "$profile" != "$current"
                        printf '%s\n' "$profile"
                    end
                end
                return
            end

            return 1
        end

        function _opsd_blueprints
            set -l workspace_root $OPSD_WORKSPACE_ROOT
            if test -z "$workspace_root"
                set workspace_root (pwd)
            end

            for blueprint_file in $workspace_root/modules/*/blueprints/*.yaml $workspace_root/.opsd/cache/releases/*/*/modules/*/blueprints/*.yaml
                test -f "$blueprint_file"; or continue

                set -l blueprint_id (awk -F': *' '/^id:/{print $2; exit}' "$blueprint_file")
                if test -z "$blueprint_id"
                    set blueprint_id (basename "$blueprint_file" .yaml)
                end

                printf '%s\n' $blueprint_id
            end
        end

        function _opsd_variants
            set -l blueprint $argv[1]
            test -n "$blueprint"; or return 1

            set -l workspace_root $OPSD_WORKSPACE_ROOT
            if test -z "$workspace_root"
                set workspace_root (pwd)
            end

            for blueprint_file in $workspace_root/modules/*/blueprints/$blueprint.yaml $workspace_root/.opsd/cache/releases/*/*/modules/*/blueprints/$blueprint.yaml
                test -f "$blueprint_file"; or continue

                awk '
                    /^variants:/ { in_variants = 1; next }
                    in_variants && /^[^[:space:]]/ { exit }
                    in_variants && /^  - id:/ { print $3 }
                ' "$blueprint_file"
                return 0
            end

            return 1
        end

        function _opsd_variant_exact
            set -l blueprint $argv[1]
            if test -z "$blueprint"
                set -l tokens (commandline -opc)
                if test (count $tokens) -ge 3
                    set blueprint $tokens[3]
                end
            end

            set -l current (commandline -ct)
            set -l previous
            set -l tokens (commandline -opc)
            set -l variants (_opsd_variants $blueprint)

            if test (count $tokens) -gt 0
                set previous $tokens[-1]
            end

            for candidate in $current $previous
                test -n "$candidate"; or continue
                for variant in $variants
                    if test "$variant" = "$candidate"
                        return 0
                    end
                end
            end

            return 1
        end

        function _opsd_blueprint_exact
            set -l current (commandline -ct)
            set -l previous
            set -l tokens (commandline -opc)
            set -l blueprints (_opsd_blueprints)

            if test (count $tokens) -gt 0
                set previous $tokens[-1]
            end

            for candidate in $current $previous
                test -n "$candidate"; or continue
                for blueprint in $blueprints
                    if test "$blueprint" = "$candidate"
                        return 0
                    end
                end
            end

            return 1
        end

        function _opsd_variant_requested
            for token in (commandline -opc)
                if test "$token" = "--variant"
                    return 0
                end
            end

            return 1
        end

        #{completion_blueprint_fish_lines(command)}

        complete -c #{command} -f
        complete -c #{command} -n '__fish_use_subcommand' -a '#{completion_values(:commands)}'

        complete -c #{command} -n '__fish_seen_subcommand_from completion' -a '#{completion_values(:completion)}'
        complete -c #{command} -n '__fish_seen_subcommand_from config' -a '#{completion_values(:config)}'
        complete -c #{command} -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from profile; and not __fish_seen_subcommand_from list show create edit use current' -a '#{completion_values(:config_profile)}'
        complete -c #{command} -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from profile; and __fish_seen_subcommand_from create' -a 'profile-name' -d 'Type a new profile name; replace profile-name with your own value.'
        complete -c #{command} -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from profile; and __fish_seen_subcommand_from use' -a '(_opsd_profiles)' -d 'Type an existing profile name to activate it.'
        complete -c #{command} -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from profile; and __fish_seen_subcommand_from edit' -a '(_opsd_profiles)' -d 'Type an existing profile name to edit it.'
        complete -c #{command} -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from profile; and __fish_seen_subcommand_from show' -a '(_opsd_profiles)' -d 'Type an existing profile name to inspect it.'
        #{completion_blueprint_fish_lines(command)}
        complete -c #{command} -n '__fish_seen_subcommand_from validate render' -a '#{completion_values(:validate_render)}'
        complete -c #{command} -n '__fish_seen_subcommand_from verify' -a '#{completion_values(:verify)}'
        complete -c #{command} -n '__fish_seen_subcommand_from export' -a '#{completion_values(:export)}'
        complete -c #{command} -n '__fish_seen_subcommand_from validate; and __fish_seen_subcommand_from manifest' -a '(_opsd_manifest_suggestions)'
        complete -c #{command} -n '__fish_seen_subcommand_from verify; and __fish_seen_subcommand_from config' -a '(_opsd_manifest_suggestions)'
        complete -c #{command} -n '__fish_seen_subcommand_from verify; and __fish_seen_subcommand_from plan' -a '(_opsd_manifest_suggestions)'
        complete -c #{command} -n '__fish_seen_subcommand_from verify; and __fish_seen_subcommand_from lifecycle' -a '(_opsd_manifest_suggestions)'
        complete -c #{command} -n '__fish_seen_subcommand_from render; and __fish_seen_subcommand_from manifest' -a '(_opsd_manifest_suggestions)'
        complete -c #{command} -n '__fish_seen_subcommand_from add' -a '#{completion_values(:add)}'
        complete -c #{command} -n '__fish_seen_subcommand_from resize' -a '#{completion_values(:resize)}'
        complete -c #{command} -n '__fish_seen_subcommand_from scale' -a '#{completion_values(:scale)}'
        complete -c #{command} -n '__fish_seen_subcommand_from attach detach' -a '#{completion_values(:attach_detach)}'
        complete -c #{command} -n '__fish_seen_subcommand_from remove' -a '#{completion_values(:remove)}'

        complete -c #{command} -n '__fish_seen_subcommand_from add database' -a '#{completion_values(:add_database)}'
        complete -c #{command} -n '__fish_seen_subcommand_from add cache' -a '#{completion_values(:add_cache)}'
        complete -c #{command} -n '__fish_seen_subcommand_from add node' -a '#{completion_values(:add_node)}'
        complete -c #{command} -n '__fish_seen_subcommand_from config profile; and __fish_seen_subcommand_from show edit use' -a '(_opsd_profiles)' -d 'Type an existing profile name.'
        complete -c #{command} -n '__fish_seen_subcommand_from resize compute-group resize cache resize database' -l #{completion_values(:resize_options).delete_prefix("--")}
        complete -c #{command} -n '__fish_seen_subcommand_from scale compute-group' -l #{completion_values(:scale_options).delete_prefix("--")}
        complete -c #{command} -n '__fish_seen_subcommand_from attach compute-group' -l #{completion_values(:attach_options).delete_prefix("--")}
        complete -c #{command} -n '__fish_seen_subcommand_from detach compute-group' -l #{completion_values(:detach_options).delete_prefix("--")}
      FISH
    end

    def describe_usage
      help_block(
        "Usage: opsd describe blueprint <blueprint> [--variant <variant>]",
        [
          [
            "Options",
            [
              ["--variant <variant>", "Select a blueprint variant"]
            ]
          ]
        ]
      )
    end

    def config_usage
      help_block(
        "Usage: opsd config <command>",
        [
          [
            "Commands",
            [
              ["profile", "Manage named profiles and profile configuration"]
            ]
          ]
        ]
      )
    end

    def config_profile_usage
      help_block(
        "Usage: opsd config profile <command>",
        [
          [
            "Commands",
            [
              ["list", "List configured profiles"],
              ["show", "Show profile details and status"],
              ["create", "Create a new profile"],
              ["edit", "Edit an existing profile"],
              ["use", "Select the current profile"],
              ["current", "Show the current profile"]
            ]
          ]
        ]
      )
    end

    def profile_creation_hint
      "Type a new profile name; replace profile-name with your own value."
    end

    def profile_edit_hint
      "Type an existing profile name to edit it."
    end

    def profile_show_hint
      "Type an existing profile name to inspect it."
    end

    def profile_use_hint
      "Type an existing profile name to activate it."
    end

    def placeholder_profile_name?(value)
      %w[name profile-name].include?(value)
    end

    def config_profile_use_usage
      help_block(
        "Usage: opsd config profile use <profile>",
        [
          [
            "Profiles",
            config_store.profile_names.map do |profile|
              [profile, "Select this profile as current"]
            end
          ]
        ]
      )
    end

    def config_profile_current_usage
      help_block("Usage: opsd config profile current")
    end

    def init_usage
      help_block(
        "Usage: opsd init blueprint <blueprint> [output.yaml] [--variant <variant>] [--wizard]",
        [
          [
            "Options",
            [
              ["--variant <variant>", "Choose the blueprint variant to seed"],
              ["--wizard", "Guide the user through the manifest inputs interactively"]
            ]
          ]
        ]
      )
    end

    def validate_usage
      help_block(
        "Usage: opsd validate <manifest <manifest.yaml>|module <module.yaml>>",
        [
          [
            "Before render",
            [
              ["check", "Check a manifest or Kubernetes module metadata before use"]
            ]
          ]
        ]
      )
    end

    def verify_usage
      help_block(
        "Usage: opsd verify <config|plan|lifecycle> <file>",
        [
          [
            "Commands",
            [
              ["config", "Verify a manifest against the OPSd contract"],
              ["plan", "Verify an OpenTofu plan against the OPSd contract"],
              ["lifecycle", "Verify a version set against lifecycle compatibility data"]
            ]
          ]
        ]
      )
    end

    def render_usage
      help_block(
        "Usage: opsd render manifest <manifest.yaml> --output <directory>",
        [
          [
            "Options",
            [
              ["--output <directory>", "Write the runnable OpenTofu stack to this directory"]
            ]
          ]
        ]
      )
    end

    def export_usage
      help_block(
        "Usage: opsd export exit-pack <rendered-directory> --output <archive.tar.gz>",
        [
          [
            "Commands",
            [
              ["exit-pack", "Bundle the rendered stack, manifest, lock file, and handoff notes"]
            ]
          ],
          [
            "Options",
            [
              ["--output <archive.tar.gz>", "Write the exit pack archive to this file"]
            ]
          ]
        ]
      )
    end

    def add_usage
      help_block(
        "Usage: opsd add <resource> <manifest.yaml> [options...]",
        [
          [
            "Resources",
            [
              ["compute-group", "Add a compute group to a manifest"],
              ["database", "Add a database to a manifest"],
              ["cache", "Add a cache to a manifest"],
              ["object-storage", "Add object storage to a manifest"],
              ["cdn-endpoint", "Add a CDN endpoint to a manifest"],
              ["load-balancer", "Add a load balancer to a manifest"],
              ["node", "Add a node to a manifest"]
            ]
          ]
        ]
      )
    end

    def resize_usage
      help_block(
        "Usage: opsd resize <resource> <manifest.yaml> <resource-id> --profile <profile>",
        [
          [
            "Resources",
            [
              ["compute-group", "Resize a compute group"],
              ["cache", "Resize a cache"],
              ["database", "Resize a database"]
            ]
          ]
        ]
      )
    end

    def scale_usage
      help_block(
        "Usage: opsd scale compute-group <manifest.yaml> <compute-group-id> --replicas <count>",
        [
          [
            "Options",
            [
              ["--replicas <count>", "Desired replica count"]
            ]
          ]
        ]
      )
    end

    def attach_usage
      help_block(
        "Usage: opsd attach compute-group <manifest.yaml> <compute-group-id> --to <load-balancer-id>",
        [
          [
            "Options",
            [
              ["--to <load-balancer-id>", "Attach to a load balancer"]
            ]
          ]
        ]
      )
    end

    def detach_usage
      help_block(
        "Usage: opsd detach compute-group <manifest.yaml> <compute-group-id> --from <load-balancer-id>",
        [
          [
            "Options",
            [
              ["--from <load-balancer-id>", "Detach from a load balancer"]
            ]
          ]
        ]
      )
    end

    def remove_usage
      help_block(
        "Usage: opsd remove <resource> <manifest.yaml> <resource-id>",
        [
          [
            "Resources",
            [
              ["compute-group", "Remove a compute group from a manifest"],
              ["database", "Remove a database from a manifest"],
              ["cache", "Remove a cache from a manifest"],
              ["object-storage", "Remove object storage from a manifest"],
              ["load-balancer", "Remove a load balancer from a manifest"],
              ["cdn-endpoint", "Remove a CDN endpoint from a manifest"],
              ["node", "Remove a node from a manifest"]
            ]
          ]
        ]
      )
    end

    def help_block(usage_line, groups = [])
      lines = [usage_line]

      groups.each do |heading, rows|
        lines << ""
        lines << "#{heading}:"
        lines << help_table(rows)
      end

      lines.join("\n")
    end

    def help_flag?(value)
      value == "--help" || value == "-h"
    end

    def help_requested?(*values)
      Array(values).flatten.compact.any? { |value| help_flag?(value) } || @argv.any? { |value| help_flag?(value) }
    end

    def help_table(rows)
      width = rows.map { |label, _description| label.length }.max || 0
      rows.map { |label, description| format("  %-#{width}s  %s", label, description) }.join("\n")
    end

    def completion_install_usage
      help_block(
        "Usage: opsd completion install [--snapshot] <bash|zsh|fish>",
        [
          [
            "Options",
            [
              ["--snapshot", "Write a one-time completion snapshot"]
            ]
          ],
          [
            "Shells",
            [
              ["bash", "Install Bash completion"],
              ["zsh", "Install Zsh completion"],
              ["fish", "Install Fish completion"]
            ]
          ]
        ]
      )
    end

    def prompt_profile_field(label, default:, hint:)
      puts hint if hint
      prompt = default.nil? ? "#{label}: " : "#{label} [#{default}]: "
      print prompt
      response = $stdin.gets
      return default if response.nil?

      value = response.strip
      return default if value.empty? && !default.nil?

      value
    end

    def show_available_profiles
      profiles = config_store.profile_names
      if profiles.empty?
        puts "No profiles configured"
        return
      end

      puts "Available profiles:"
      profiles.each do |profile|
        puts "  #{profile}"
      end
    end

    def completion_install_payload(shell, snapshot:)
      home = Pathname(ENV.fetch("HOME"))
      launcher = Shellwords.escape(completion_launcher_path.to_s)

      case shell
      when "bash"
        script = snapshot ? bash_completion_script : <<~BASH
          eval "$(#{launcher} completion bash)"
        BASH
        [script, home.join(".local/share/bash-completion/completions/opsd")]
      when "zsh"
        script = snapshot ? zsh_completion_script : <<~ZSH
          eval "$(#{launcher} completion zsh)"
        ZSH
        [script, home.join(".zsh/completions/_opsd")]
      when "fish"
        script = snapshot ? fish_completion_script : <<~FISH
          #{launcher} completion fish | source
        FISH
        [script, home.join(".config/fish/completions/opsd.fish")]
      else
        raise "Unsupported completion shell: #{shell}"
      end
    end

    def completion_launcher_path
      app_root.join("bin/opsd")
    end

    def warm_completion_cache
      cache_root = Pathname(ENV.fetch("XDG_CACHE_HOME", File.join(ENV.fetch("HOME"), ".cache")))
      cache_dir = cache_root.join("opsd")
      cache_dir.mkpath

      write_cache_file(cache_dir.join("profiles.txt"), completion_profile_names)
    rescue StandardError => e
      warn "Completion cache warmup failed: #{e.message}"
    end

    def completion_profile_names
      stdout, status = Open3.capture2e(completion_launcher_path.to_s, "config", "profile", "list")
      return [] unless status.success?

      stdout.each_line.filter_map do |line|
        match = line.match(/^\s{2}([^\s]+)/)
        match&.[](1)
      end
    rescue StandardError
      []
    end

    def write_cache_file(path, entries)
      path.dirname.mkpath
      path.write(Array(entries).join("\n").concat(entries.empty? ? "" : "\n"))
    end

    def completion_hook_path(shell)
      home = Pathname(ENV.fetch("HOME"))

      case shell
      when "bash"
        home.join(".bashrc")
      when "zsh"
        home.join(".zshrc")
      when "fish"
        home.join(".config/fish/conf.d/opsd.fish")
      else
        raise "Unsupported completion shell: #{shell}"
      end
    end

    def completion_install_hook(shell, destination)
      case shell
      when "bash"
        <<~BASH
          # OPSd completion
          if [ -r #{destination.to_s.inspect} ]; then
            . #{destination.to_s.inspect}
          fi
          # OPSd completion end
        BASH
      when "zsh"
        <<~ZSH
          # OPSd completion
          if ! whence compdef >/dev/null 2>&1; then
            autoload -Uz compinit
            compinit
          fi
          if [ -r #{destination.to_s.inspect} ]; then
            . #{destination.to_s.inspect}
            compdef _opsd opsd
          fi
          # OPSd completion end
        ZSH
      when "fish"
        <<~FISH
          # OPSd completion
          if test -r #{destination.to_s.inspect}
              source #{destination.to_s.inspect}
          end
          # OPSd completion end
        FISH
      else
        raise "Unsupported completion shell: #{shell}"
      end
    end

    def completion_command_targets
      ["opsd", "bin/opsd"]
    end

    def completion_values(key)
      values = case key
               when :commands then COMPLETION_COMMANDS
               when :completion then COMPLETION_SUBCOMMANDS.fetch(:completion)
               when :config then COMPLETION_SUBCOMMANDS.fetch(:config)
               when :config_profile then COMPLETION_SUBCOMMANDS.fetch(:config_profile)
               when :list then COMPLETION_SUBCOMMANDS.fetch(:list)
               when :describe then COMPLETION_SUBCOMMANDS.fetch(:describe)
               when :init then COMPLETION_SUBCOMMANDS.fetch(:init)
               when :validate_render then COMPLETION_SUBCOMMANDS.fetch(:validate_render)
               when :verify then COMPLETION_SUBCOMMANDS.fetch(:verify)
               when :export then COMPLETION_SUBCOMMANDS.fetch(:export)
               when :add then COMPLETION_SUBCOMMANDS.fetch(:add)
               when :resize then COMPLETION_SUBCOMMANDS.fetch(:resize)
               when :scale then COMPLETION_SUBCOMMANDS.fetch(:scale)
               when :attach, :detach then COMPLETION_SUBCOMMANDS.fetch(:attach_detach)
               when :attach_detach then COMPLETION_SUBCOMMANDS.fetch(:attach_detach)
               when :remove then COMPLETION_SUBCOMMANDS.fetch(:remove)
               when :add_database then COMPLETION_SUBCOMMANDS.fetch(:add_database)
               when :add_cache then COMPLETION_SUBCOMMANDS.fetch(:add_cache)
               when :add_node then COMPLETION_SUBCOMMANDS.fetch(:add_node)
               when :resize_options then COMPLETION_OPTIONS.fetch(:resize)
               when :scale_options then COMPLETION_OPTIONS.fetch(:scale)
               when :attach_options then COMPLETION_OPTIONS.fetch(:attach)
               when :detach_options then COMPLETION_OPTIONS.fetch(:detach)
               else
                 raise "Unsupported completion metadata key: #{key}"
               end

      values.join(" ")
    end

    def exit_pack_exporter
      @exit_pack_exporter ||= ExitPackExporter.new
    end

    def completion_blueprint_helpers(shell)
      case shell
      when :bash
        <<~BASH
          _opsd_blueprints() {
            local workspace_root="${OPSD_WORKSPACE_ROOT:-$PWD}"
            local blueprint_file
            local blueprint_id

            shopt -s nullglob
            for blueprint_file in \
              "$workspace_root"/modules/*/blueprints/*.yaml \
              "$workspace_root"/.opsd/cache/releases/*/*/modules/*/blueprints/*.yaml; do
              blueprint_id="$(awk -F': *' '/^id:/{print $2; exit}' "$blueprint_file")"
              [[ -n "$blueprint_id" ]] || blueprint_id="${blueprint_file##*/}"
              printf '%s\n' "${blueprint_id%.yaml}"
            done
            shopt -u nullglob
          }

          _opsd_blueprint_exact() {
            local current="${1:-}"
            local previous="${2:-}"
            local candidate
            local blueprint
            local -a blueprints=()

            while IFS= read -r blueprint; do
              [[ -n "$blueprint" ]] || continue
              blueprints+=("$blueprint")
            done < <(_opsd_blueprints)
            for candidate in "$current" "$previous"; do
              [[ -n "$candidate" ]] || continue
              for blueprint in "${blueprints[@]}"; do
                [[ "$blueprint" == "$candidate" ]] && return 0
              done
            done

            return 1
          }

          _opsd_without_current() {
            local current="${1:-}"
            shift || true
            local candidate
            for candidate in "$@"; do
              [[ -n "$candidate" ]] || continue
              [[ "$candidate" == "$current" ]] && continue
              printf '%s\n' "$candidate"
            done
          }

          _opsd_variant_exact() {
            local blueprint="${1:-}"
            local current="${2:-}"
            local previous="${3:-}"
            local candidate
            local variant
            local -a variants=()

            while IFS= read -r variant; do
              [[ -n "$variant" ]] || continue
              variants+=("$variant")
            done < <(_opsd_variants "$blueprint")

            for candidate in "$current" "$previous"; do
              [[ -n "$candidate" ]] || continue
              for variant in "${variants[@]}"; do
                [[ "$variant" == "$candidate" ]] && return 0
              done
            done

            return 1
          }

          _opsd_variant_requested() {
            local token
            for token in "${words[@]}"; do
              [[ "$token" == "--variant" || "$token" == "--wizard" ]] && return 0
            done

            return 1
          }

          _opsd_profiles() {
            local cache_file
            cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/opsd/profiles.txt"
            local profile

            if declare -p _OPSD_PROFILES_CACHE >/dev/null 2>&1 && (( ${#_OPSD_PROFILES_CACHE[@]} )); then
              printf '%s\n' "${_OPSD_PROFILES_CACHE[@]}"
              return
            fi

            if [[ -s "$cache_file" ]]; then
              _OPSD_PROFILES_CACHE=()
              while IFS= read -r profile; do
                [[ -n "$profile" ]] || continue
                _OPSD_PROFILES_CACHE+=("$profile")
              done < "$cache_file"
              printf '%s\n' "${_OPSD_PROFILES_CACHE[@]}"
              return
            fi

            return 1
          }

          _opsd_variants() {
            local blueprint="${1:-}"
            local workspace_root="${OPSD_WORKSPACE_ROOT:-$PWD}"
            local blueprint_file

            [[ -n "$blueprint" ]] || return 1

            shopt -s nullglob
            for blueprint_file in \
              "$workspace_root"/modules/*/blueprints/"$blueprint".yaml \
              "$workspace_root"/.opsd/cache/releases/*/*/modules/*/blueprints/"$blueprint".yaml; do
              awk '
                /^variants:/ { in_variants = 1; next }
                in_variants && /^[^[:space:]]/ { exit }
                in_variants && /^  - id:/ { print $3 }
              ' "$blueprint_file"
              shopt -u nullglob
              return 0
            done
            shopt -u nullglob

            return 1
          }
        BASH
      when :zsh
        <<~ZSH
          _opsd_blueprints() {
            local workspace_root="${OPSD_WORKSPACE_ROOT:-$PWD}"
            local blueprint_file
            local blueprint_id

            setopt local_options null_glob
            for blueprint_file in "$workspace_root"/modules/*/blueprints/*.yaml "$workspace_root"/.opsd/cache/releases/*/*/modules/*/blueprints/*.yaml; do
              blueprint_id="$(awk -F': *' '/^id:/{print $2; exit}' "$blueprint_file")"
              [[ -n "$blueprint_id" ]] || blueprint_id="${blueprint_file:t:r}"
              print -r -- "${blueprint_id%.yaml}"
            done
          }

          _opsd_blueprint_exact() {
            local current="$1"
            local previous="$2"
            local candidate
            local -a blueprints

            blueprints=("${(@f)$(_opsd_blueprints)}")
            for candidate in "$current" "$previous"; do
              [[ -n "$candidate" ]] || continue
              for blueprint in "${blueprints[@]}"; do
                [[ "$blueprint" == "$candidate" ]] && return 0
              done
            done

            return 1
          }

          _opsd_without_current() {
            local current="$1"
            shift || true
            local candidate
            local -a filtered=()

            for candidate in "$@"; do
              [[ -n "$candidate" ]] || continue
              [[ "$candidate" == "$current" ]] && continue
              filtered+=("$candidate")
            done

            printf '%s\n' "${filtered[@]}"
          }

          _opsd_variant_exact() {
            local blueprint="$1"
            local current="$2"
            local previous="$3"
            local candidate
            local variant
            local -a variants
            variants=("${(@f)$(_opsd_variants "$blueprint")}")

            for candidate in "$current" "$previous"; do
              [[ -n "$candidate" ]] || continue
              for variant in "${variants[@]}"; do
                [[ "$variant" == "$candidate" ]] && return 0
              done
            done

            return 1
          }

          _opsd_variant_requested() {
            local token
            for token in "${line[@]}"; do
              [[ "$token" == --variant || "$token" == --wizard ]] && return 0
            done

            return 1
          }

          _opsd_profiles() {
            local cache_file
            cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/opsd/profiles.txt"

            if [[ -n "${_OPSD_PROFILES_CACHE+set}" && ${#_OPSD_PROFILES_CACHE[@]} -gt 0 ]]; then
              printf '%s\n' "${_OPSD_PROFILES_CACHE[@]}"
              return
            fi

            if [[ -s "$cache_file" ]]; then
              typeset -ga _OPSD_PROFILES_CACHE
              _OPSD_PROFILES_CACHE=("${(@f)$(cat "$cache_file")}")
              printf '%s\n' "${_OPSD_PROFILES_CACHE[@]}"
              return
            fi

            return 1
          }

          _opsd_variants() {
            local blueprint="$1"
            local workspace_root="${OPSD_WORKSPACE_ROOT:-$PWD}"
            local blueprint_file

            [[ -n "$blueprint" ]] || return 1

            setopt local_options null_glob
            for blueprint_file in "$workspace_root"/modules/*/blueprints/"$blueprint".yaml "$workspace_root"/.opsd/cache/releases/*/*/modules/*/blueprints/"$blueprint".yaml; do
              awk '
                /^variants:/ { in_variants = 1; next }
                in_variants && /^[^[:space:]]/ { exit }
                in_variants && /^  - id:/ { print $3 }
              ' "$blueprint_file"
              return 0
            done

            return 1
          }
        ZSH
      else
        raise "Unsupported completion shell: #{shell}"
      end
    end

    def completion_blueprint_subject_branch(shell, command_name)
      case shell
      when :bash
        <<~BASH
          #{command_name})
            if [[ $cword -eq 2 ]]; then
              COMPREPLY=( $(compgen -W "blueprint" -- "$cur") )
            elif [[ ${words[2]-} == blueprint && $cword -ge 3 ]]; then
              if _opsd_variant_requested; then
                if _opsd_variant_exact "${words[3]-}" "$cur" "${words[cword-1]-}"; then
                  COMPREPLY=()
                else
                  COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_variants "${words[3]-}"))" -- "$cur") )
                fi
              elif _opsd_blueprint_exact "$cur" "${words[cword-1]-}"; then
                COMPREPLY=( $(compgen -W "--variant --wizard" -- "$cur") )
              else
                COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_blueprints))" -- "$cur") )
              fi
            elif [[ ${prev} == --variant ]]; then
              if _opsd_variant_exact "${words[3]-}" "$cur" "${words[cword-1]-}"; then
                COMPREPLY=()
              else
                COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_variants "${words[3]-}"))" -- "$cur") )
              fi
            else
              COMPREPLY=( $(compgen -W "--variant --wizard" -- "$cur") )
            fi
            ;;
        BASH
      when :zsh
        <<~ZSH
          "#{command_name} blueprint")
            if _opsd_variant_requested; then
              if _opsd_variant_exact "$line[3]" "$line[CURRENT]" "$line[CURRENT-1]"; then
                return 0
              fi
              compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_variants "$line[3]"))
            elif (( CURRENT >= 4 )) && _opsd_blueprint_exact "$line[3]" "$line[4]"; then
              _values 'option' --variant --wizard
            elif (( CURRENT >= 4 )); then
              compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_blueprints))
            elif [[ "$words[CURRENT-1]" == "--variant" ]]; then
              if _opsd_variant_exact "$line[3]" "$line[CURRENT]" "$line[CURRENT-1]"; then
                return 0
              fi
              compadd -- $(_opsd_without_current "$line[CURRENT]" $(_opsd_variants "$line[3]"))
            else
              _values 'option' --variant --wizard
            fi
            ;;
        ZSH
      else
        raise "Unsupported completion shell: #{shell}"
      end
    end

    def completion_blueprint_case_blocks(shell)
      completion_blueprint_completion_rules.map do |entry|
        case entry.fetch(:type)
        when :list
          completion_blueprint_list_branch(shell)
        when :subject
          completion_blueprint_subject_branch(shell, entry.fetch(:command))
        else
          raise "Unsupported blueprint completion type: #{entry.inspect}"
        end
      end.join("\n")
    end

    def completion_blueprint_fish_lines(command)
      completion_blueprint_completion_rules.flat_map do |entry|
        case entry.fetch(:type)
        when :list
          [
            "complete -c #{command} -n '__fish_seen_subcommand_from list' -a 'blueprints'",
            "complete -c #{command} -n '__fish_seen_subcommand_from list; and __fish_seen_subcommand_from blueprints; and test (count (commandline -opc)) -eq 3' -a '(_opsd_blueprints)'"
          ]
        when :subject
          subject = entry.fetch(:subject)
          [
            "complete -c #{command} -n '__fish_seen_subcommand_from #{entry.fetch(:command)}' -a '#{subject}'",
            "complete -c #{command} -n '__fish_seen_subcommand_from #{entry.fetch(:command)}; and __fish_seen_subcommand_from #{subject}; and not _opsd_variant_requested; and not _opsd_blueprint_exact' -a '(_opsd_blueprints)'",
            "complete -c #{command} -n '__fish_seen_subcommand_from #{entry.fetch(:command)}; and __fish_seen_subcommand_from #{subject}; and not _opsd_variant_requested; and _opsd_blueprint_exact; and not _opsd_variant_exact' -a '--variant --wizard'",
            "complete -c #{command} -n '__fish_seen_subcommand_from #{entry.fetch(:command)}; and __fish_seen_subcommand_from #{subject}; and _opsd_variant_requested; and not _opsd_variant_exact' -a '(_opsd_variants)'"
          ]
        else
          raise "Unsupported blueprint completion type: #{entry.inspect}"
        end
      end.join("\n")
    end

    def completion_blueprint_completion_rules
      [
        { type: :list, command: "list", subject: "blueprints" },
        { type: :subject, command: "describe", subject: "blueprint" },
        { type: :subject, command: "init", subject: "blueprint" }
      ]
    end

    def completion_blueprint_list_branch(shell)
      case shell
      when :bash
        <<~BASH
          list)
            if [[ $cword -eq 2 ]]; then
              COMPREPLY=( $(compgen -W "blueprints" -- "$cur") )
            elif [[ ${words[2]-} == blueprints && $cword -eq 3 ]]; then
              for candidate in "${words[@]:3}"; do
                [[ -n "$candidate" ]] || continue
                if _opsd_blueprint_exact "$candidate" ""; then
                  COMPREPLY=()
                  return
                fi
              done
              COMPREPLY=( $(compgen -W "$(_opsd_without_current "$cur" $(_opsd_blueprints))" -- "$cur") )
            fi
            ;;
        BASH
      when :zsh
        <<~ZSH
          "list blueprints")
            if _opsd_blueprint_exact "$words[CURRENT]" "$words[CURRENT-1]"; then
              return 0
            fi

            if (( CURRENT >= 4 )); then
              compadd -- $(_opsd_without_current "$words[CURRENT]" $(_opsd_blueprints))
            fi
            return 0
            ;;
        ZSH
      else
        raise "Unsupported completion shell: #{shell}"
      end
    end

    def display_path(path)
      path = Pathname(path).expand_path
      home = Pathname(ENV.fetch("HOME")).expand_path

      relative = path.relative_path_from(home)
      return "~" if relative.to_s == "."

      File.join("~", relative.to_s)
    rescue ArgumentError
      path.to_s
    end

    def append_block(path:, text:)
      existing = path.exist? ? path.read : ""
      return if existing.include?(text)

      path.dirname.mkpath
      File.open(path, "a") do |file|
        file.write("\n") if !existing.empty? && !existing.end_with?("\n")
        file.write(text)
        file.write("\n") unless text.end_with?("\n")
      end
    end

    def version_usage
      <<~TEXT
        Usage: opsd version

        Print the CLI version.
      TEXT
    end

    def template_store
      @template_store ||= TemplateStore.new(
        app_root: @app_root,
        workspace_root: catalog_workspace_root,
        contract_store: contract_store
      )
    end

    def config_verifier
      @config_verifier ||= ConfigVerifier.new(
        contract_store: contract_store,
        template_store: template_store
      )
    end

    def capability_validator
      @capability_validator ||= ManifestCapabilitiesValidator.new(template_store: template_store, provider: effective_provider)
    end

    def capability_validator_for(provider)
      ManifestCapabilitiesValidator.new(template_store: template_store, provider: provider)
    end

    def config_store
      @config_store ||= ConfigStore.new(
        workspace_root: @workspace,
        supported_providers: contract_store.active_provider_names
      )
    end

    def module_catalog
      @module_catalog ||= ModuleCatalog.new(
        workspace_root: @workspace,
        contract_store: contract_store
      )
    end

    def provider_catalog_store
      @provider_catalog_store ||= ProviderCatalogStore.new(workspace_root: catalog_workspace_root)
    end

    def contract_store
      @contract_store ||= ContractStore.new(app_root: @app_root)
    end

    def config_verifier
      @config_verifier ||= ConfigVerifier.new(
        contract_store: contract_store,
        template_store: template_store
      )
    end

    def plan_verifier
      @plan_verifier ||= PlanVerifier.new(contract_store: contract_store)
    end

    def print_verification_findings(findings)
      warnings = findings.select { |finding| finding.severity == "warning" }
      blocking = findings.select { |finding| finding.severity == "blocking" }

      puts "Blocking findings:" if blocking.any?
      blocking.each do |finding|
        puts "  - [#{finding.code}] #{finding.message}"
      end

      puts "Warnings:" if warnings.any?
      warnings.each do |finding|
        puts "  - [#{finding.code}] #{finding.message}"
      end
    end

    def print_verification_success(manifest_path, manifest, findings)
      puts "Config is valid: #{manifest_path}"
      puts "Provider: #{manifest.provider}"
      puts "Family: #{manifest.family}" unless manifest.family.nil?
      puts "Blueprint: #{manifest.composer_blueprint}" unless manifest.composer_blueprint.nil?
      puts "Variant: #{manifest.composer_variant}" unless manifest.composer_variant.nil?
      print_verification_findings(findings)
      puts
      puts "Next step:"
      puts "  opsd render manifest #{manifest_path} --output <directory>"
    end

    def print_plan_verification_findings(findings)
      warnings = findings.select { |finding| finding.severity == "warning" }
      blocking = findings.select { |finding| finding.severity == "blocking" }

      puts "Blocking findings:" if blocking.any?
      blocking.each do |finding|
        suffix = finding.address.nil? || finding.address.empty? ? "" : " (#{finding.address})"
        puts "  - [#{finding.code}] #{finding.message}#{suffix}"
      end

      puts "Warnings:" if warnings.any?
      warnings.each do |finding|
        suffix = finding.address.nil? || finding.address.empty? ? "" : " (#{finding.address})"
        puts "  - [#{finding.code}] #{finding.message}#{suffix}"
      end
    end

    def print_plan_verification_success(plan_path, plan, findings)
      summary = plan_verifier.change_summary(plan)
      puts "Plan is supported: #{plan_path}"
      puts "Additive changes: #{summary.fetch("additive")}"
      puts "Updates: #{summary.fetch("updates")}"
      puts "Destructive changes: #{summary.fetch("destructive")}"
      puts "Replacements: #{summary.fetch("replacements")}"
      puts "No-op changes: #{summary.fetch("noop")}"
      puts "Unknown changes: #{summary.fetch("unknown")}"
      print_plan_verification_findings(findings)
    end

    def print_lifecycle_verification_findings(findings)
      warnings = findings.select { |finding| finding.severity == "warning" }
      blocking = findings.select { |finding| finding.severity == "blocking" }

      puts "Blocking findings:" if blocking.any?
      blocking.each do |finding|
        puts "  - [#{finding.code}] #{finding.message}"
      end

      puts "Warnings:" if warnings.any?
      warnings.each do |finding|
        puts "  - [#{finding.code}] #{finding.message}"
      end
    end

    def print_lifecycle_verification_success(lifecycle_path, snapshot, findings)
      summary = lifecycle_verifier.summary(snapshot)

      puts "Lifecycle is compatible: #{lifecycle_path}"
      summary.each do |component|
        puts "#{component['label']}: #{format_lifecycle_component_summary(component)}"
      end
      print_lifecycle_verification_findings(findings)
    end

    def run_verify_config(manifest_path)
      return puts(verify_usage) if manifest_path.nil? || help_flag?(manifest_path) || help_requested?
      raise "Usage: opsd verify config <manifest.yaml>" if manifest_path.nil?
      raise "Usage: opsd verify config <manifest.yaml>" unless @argv.empty?

      manifest = load_manifest(manifest_path)
      findings = config_verifier.verify(manifest)
      blocking = findings.select(&:blocking?)

      if blocking.any?
        raise OPSd::ConfigVerifier::VerificationError.new(findings, manifest_path: manifest_path)
      end

      print_verification_success(manifest_path, manifest, findings)
    end

    def run_verify_plan(plan_path)
      return puts(verify_usage) if plan_path.nil? || help_flag?(plan_path) || help_requested?
      raise "Usage: opsd verify plan <plan-json>" if plan_path.nil?
      raise "Usage: opsd verify plan <plan-json>" unless @argv.empty?

      plan = load_plan_json(plan_path)
      findings = plan_verifier.verify(plan)
      blocking = findings.select(&:blocking?)

      if blocking.any?
        raise OPSd::PlanVerifier::VerificationError.new(findings, plan_path: plan_path)
      end

      print_plan_verification_success(plan_path, plan, findings)
    end

    def run_verify_lifecycle(lifecycle_path)
      return puts(verify_usage) if lifecycle_path.nil? || help_flag?(lifecycle_path) || help_requested?
      raise "Usage: opsd verify lifecycle <snapshot-json>" if lifecycle_path.nil?
      raise "Usage: opsd verify lifecycle <snapshot-json>" unless @argv.empty?

      snapshot = load_json_file(lifecycle_path)
      findings = lifecycle_verifier.verify(snapshot)
      blocking = findings.select(&:blocking?)

      if blocking.any?
        raise OPSd::LifecycleVerifier::VerificationError.new(findings, lifecycle_path: lifecycle_path)
      end

      print_lifecycle_verification_success(lifecycle_path, snapshot, findings)
    end

    def lifecycle_verifier
      @lifecycle_verifier ||= LifecycleVerifier.new(contract_store: contract_store)
    end

    def format_lifecycle_component_summary(component)
      status = component.fetch("status", "unknown")
      version = component["version"]
      upgrade_path = component["upgrade_path"]

      case status
      when "supported"
        "supported (#{version})"
      when "deprecated"
        format_lifecycle_version_status("deprecated", version, upgrade_path)
      when "unsupported-with-upgrade"
        format_lifecycle_version_status("unsupported", version, upgrade_path)
      when "unsupported"
        format_lifecycle_version_status("unsupported", version, nil)
      when "missing"
        "missing"
      when "unavailable"
        "compatibility data unavailable"
      else
        status.to_s
      end
    end

    def format_lifecycle_version_status(label, version, upgrade_path)
      text = "#{label} (#{version})"
      text += " -> #{upgrade_path}" if upgrade_path && !upgrade_path.to_s.empty?
      text
    end

    def load_plan_json(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise "Plan file not found: #{path}"
    rescue JSON::ParserError => e
      raise "JSON syntax error in #{path}: #{e.message}"
    end

    def load_json_file(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise "JSON file not found: #{path}"
    rescue JSON::ParserError => e
      raise "JSON syntax error in #{path}: #{e.message}"
    end

    def manifest_profile_catalog(provider)
      workspace_store = ProviderCatalogStore.new(workspace_root: @workspace)
      workspace_store.profile_catalog(provider)
    rescue RuntimeError => e
      raise unless e.message.start_with?("Provider metadata not found for #{provider}:")

      provider_catalog_store.profile_catalog(provider)
    end

    attr_reader :app_root

    def active_provider
      selected_profile_provider
    end

    def effective_provider
      active_provider || raise("No profile selected. Use `opsd config profile use <profile>` or set OPSD_PROFILE to a profile with a provider configured.")
    end

    def catalog_workspace_root
      @catalog_workspace_root ||= catalog_resolution.fetch(:workspace_root)
    end

    def catalog_resolution
      @catalog_resolution ||= module_catalog.resolve(effective_provider)
    end

    def lock_path_for_manifest(manifest_path)
      Pathname(manifest_path).expand_path.dirname.join("opsd.lock.yaml")
    end

    def ensure_provider_supported_for_catalog!
      provider = effective_provider
      return if template_store.provider_supported?(provider) && !template_store.blueprint_entries(provider: provider).empty?

      available = template_store.providers
      if available.empty?
        raise "Provider #{provider} is not supported yet."
      end

      if available.length == 1
        raise "Provider #{provider} is not supported yet. Currently supported provider: #{available.first}."
      end

      raise "Provider #{provider} is not supported yet. Currently supported providers: #{available.join(', ')}."
    end

    def selected_profile_name
      value = ENV["OPSD_PROFILE"]
      return value.strip unless value.nil? || value.strip.empty?

      config_store.current_profile_name
    end

    def selected_profile_provider
      profile_name = selected_profile_name
      return nil if profile_name.nil?

      config_store.profile_value(profile_name, "provider")
    end

    def parse_init_options!(args)
      options = {}
      output = nil

      until args.empty?
        token = args.shift

        case token
        when "--variant"
          variant_id = args.shift
          raise "Missing value for --variant" if variant_id.nil? || variant_id.empty?

          options["variant"] = variant_id
        when "--wizard"
          options["wizard"] = true
        when /\A--/
          raise "Unknown init option: #{token}"
        else
          raise "Unexpected extra argument: #{token}" unless output.nil?

          output = token
        end
      end

      [output, options]
    end

    def confirm_overwrite_file!(path)
      unless $stdin.tty? && $stdout.tty?
        raise "Refusing to overwrite existing file: #{path}"
      end

      print "File #{path} already exists. Overwrite? [y/N] "
      answer = $stdin.gets.to_s.strip.downcase
      puts
      raise "Refusing to overwrite existing file: #{path}" unless %w[y yes].include?(answer)
    end

    def select_blueprint_variant(blueprint, requested_variant_id: nil)
      variants = blueprint[:variants]
      raise "Blueprint #{blueprint[:id]} has no variants" if variants.empty?

      if requested_variant_id
        variant = variants.find { |entry| entry.fetch("id") == requested_variant_id }
        raise "Unsupported variant #{requested_variant_id} for blueprint #{blueprint[:id]}" if variant.nil?

        return variant
      end

      return variants.first if variants.length == 1

      available = variants.map { |variant| variant.fetch("id") }.join(", ")
      raise "Blueprint #{blueprint[:id]} requires --variant. Available variants: #{available}"
    end

    def summarize_variant_in_place_changes(variant)
      capabilities = variant["capabilities"]
      return [] unless capabilities.is_a?(Hash)

      editable = capabilities["editable"]
      return [] unless editable.is_a?(Hash)

      summary = []
      summary << "resize compute size" if editable.dig("compute_groups", "allowed_profiles").is_a?(Array)
      summary << "scale primary workload replicas" if editable.dig("compute_groups", "scale") == true
      summary << "resize database size" if editable.dig("databases", "allowed_profiles").is_a?(Array)
      summary << "resize cache size" if editable.dig("caches", "allowed_profiles").is_a?(Array)
      summary << "remove cache" if editable.dig("caches", "remove") == true
      summary << "remove load balancer" if editable.dig("load_balancers", "remove") == true
      summary.uniq
    end

    def summarize_variant_optional_addons(variant, addons_catalog)
      return [] unless addons_catalog.is_a?(Hash)

      editable = variant.dig("capabilities", "editable")
      return [] unless editable.is_a?(Hash)

      lines = []
      lines.concat(describe_engine_addons(editable["databases"], "database")) if editable["databases"].is_a?(Hash) && editable["databases"]["add"] == true
      lines.concat(describe_engine_addons(editable["caches"], "cache")) if editable["caches"].is_a?(Hash) && editable["caches"]["add"] == true
      if editable.dig("object_storage", "add") == true && Array(addons_catalog["object_storage"]).include?("spaces")
        lines << "add object storage"
      end
      if editable.dig("cdn_endpoints", "add") == true && Array(addons_catalog["cdn_endpoints"]).include?("cdn")
        lines << "add CDN endpoint"
      end
      if editable.dig("load_balancers", "add") == true
        visibility = Array(addons_catalog["load_balancers"])
        lines << "add #{visibility.join(' or ')} load balancer" unless visibility.empty?
      end
      if editable.dig("nodes", "add") == true
        lines << "add singleton VM node"
      end
      lines.uniq
    end

    def describe_engine_addons(rules, label)
      return [] unless rules.is_a?(Hash)

      Array(rules["allowed_engines"]).map do |engine|
        "add #{engine} #{label}"
      end
    end

    def variant_compute_profiles(variant, profile_catalog, mode:)
      compute = profile_catalog["compute"]
      return [] unless compute.is_a?(Hash)

      allowed_profiles = Array(variant.dig("capabilities", "editable", "compute_groups", "allowed_profiles"))
      allowed_profiles = Array(variant.dig("capabilities", "editable", "nodes", "allowed_profiles")) if allowed_profiles.empty?

      family_key = case variant["family"]
                   when "droplet" then "droplet"
                   when "kubernetes" then "kubernetes"
                   else
                     infer_compute_family_key(variant)
                   end

      candidate_profiles =
        if family_key.nil?
          compute.values.flat_map { |profiles| Array(profiles) }.uniq
        else
          Array(compute[family_key])
        end

      mode == :variant_allowed ? filter_profiles(candidate_profiles, allowed_profiles) : candidate_profiles
    end

    def variant_service_profiles(variant, profile_catalog, section_key:, mode:)
      section = profile_catalog[section_key]
      return {} unless section.is_a?(Hash)

      rules = variant.dig("capabilities", "editable", section_key)
      return {} if mode == :variant_allowed && !rules.is_a?(Hash)

      allowed_profiles = rules.is_a?(Hash) ? Array(rules["allowed_profiles"]) : []
      engines = rules.is_a?(Hash) ? Array(rules["allowed_engines"]) : []
      engines = section.keys if engines.empty?

      engines.each_with_object({}) do |engine, result|
        candidate_profiles = Array(section[engine.to_s])
        profiles = mode == :variant_allowed ? filter_profiles(candidate_profiles, allowed_profiles) : candidate_profiles
        result[engine.to_s] = profiles unless profiles.empty?
      end
    end

    def variant_object_storage_profiles(variant, profile_catalog, mode:)
      section = profile_catalog["object_storage"]
      return [] unless section.is_a?(Hash)

      rules = variant.dig("capabilities", "editable", "object_storage")
      return [] if mode == :variant_allowed && !rules.is_a?(Hash)

      candidate_profiles = Array(section["spaces"])
      allowed_profiles = rules.is_a?(Hash) ? Array(rules["allowed_profiles"]) : []
      mode == :variant_allowed ? filter_profiles(candidate_profiles, allowed_profiles) : candidate_profiles
    end

    def filter_profiles(candidate_profiles, allowed_profiles)
      return candidate_profiles if allowed_profiles.empty?

      candidate_profiles.select { |profile| allowed_profiles.include?(profile) }
    end

    def integer_option_value(flag, value)
      raise "Missing value for #{flag}" if value.nil? || value.empty?

      Integer(value, 10)
    rescue ArgumentError
      raise "Invalid integer for #{flag}: #{value}"
    end

    def ensure_provider_addon_supported!(provider, section_key:, value:)
      supported_values = Array(provider_catalog_store.addons_catalog(provider)[section_key])
      return if supported_values.include?(value)

      supported_display = supported_values.empty? ? "none" : supported_values.join(', ')
      raise "Provider #{provider} does not support #{section_key}=#{value}. Supported values: #{supported_display}"
    end

    def remove_resource_by_id!(manifest, section_key:, resource_id:, label:, manifest_path:)
      entries = Array(manifest.spec[section_key])
      index = entries.index { |entry| entry.is_a?(Hash) && entry["id"] == resource_id }
      raise "#{label} #{resource_id} not found in #{manifest_path}" if index.nil?

      entries.delete_at(index)
      manifest.spec[section_key] = entries
    end

    def cleanup_references_for_removed_resource!(manifest, section_key:, resource_id:)
      case section_key
      when "databases", "caches"
        remove_links_reference!(manifest, resource_id)
      when "load_balancers"
        remove_attach_to_reference!(manifest, resource_id)
      when "object_storage"
        remove_links_reference!(manifest, resource_id)
        remove_cdn_origin_reference!(manifest, resource_id)
      end
    end

    def remove_links_reference!(manifest, resource_id)
      %w[compute_groups nodes].each do |section_key|
        Array(manifest.spec[section_key]).each do |entry|
          next unless entry.is_a?(Hash)

          links = Array(entry["links"]).reject { |value| value == resource_id }
          if links.empty?
            entry.delete("links")
          else
            entry["links"] = links
          end
        end
      end
    end

    def remove_attach_to_reference!(manifest, resource_id)
      Array(manifest.spec["compute_groups"]).each do |entry|
        next unless entry.is_a?(Hash)

        attach_to = Array(entry["attach_to"]).reject { |value| value == resource_id }
        if attach_to.empty?
          entry.delete("attach_to")
        else
          entry["attach_to"] = attach_to
        end
      end
    end

    def remove_cdn_origin_reference!(manifest, resource_id)
      endpoints = Array(manifest.spec["cdn_endpoints"])
      endpoints.reject! { |entry| entry.is_a?(Hash) && entry["origin"] == resource_id }
      manifest.spec["cdn_endpoints"] = endpoints
    end

    def print_manifest_update_next_steps(manifest_path, summary)
      puts "Updated manifest: #{manifest_path}"
      puts summary
      puts
      puts "Next steps:"
      puts "  opsd validate manifest #{manifest_path}"
      puts "  opsd render manifest #{manifest_path} --output <directory>"
    end

    def infer_compute_family_key(variant)
      components = Array(variant["components"])
      return "droplet" if components.include?("droplet")
      return "kubernetes" if components.include?("kubernetes")

      nil
    end

    def write_manifest(manifest)
      path = manifest.source_path
      raise "Manifest source path is not available" if path.nil? || path.to_s.empty?

      Pathname(path).write(YAML.dump(manifest.data))
    end
  end
end
