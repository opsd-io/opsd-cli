# frozen_string_literal: true

require "pathname"

require_relative "contract_store"
require_relative "template_store"

module OPSd
  class McpToolCatalog
    Tool = Struct.new(:name, :description, :arguments, :cli, :requires_confirmation, keyword_init: true)

    def initialize(app_root:, workspace_root:, contract_store: nil, template_store: nil)
      @app_root = Pathname(app_root).expand_path
      @workspace_root = Pathname(workspace_root).expand_path
      @contract_store = contract_store || ContractStore.new(app_root: @app_root)
      @template_store = template_store || TemplateStore.new(
        app_root: @app_root,
        workspace_root: @workspace_root,
        contract_store: @contract_store
      )
    end

    def tools
      tool_definitions.map { |entry| tool_payload(entry) }
    end

    def tool(name)
      tool_definitions.find { |entry| entry.name == name.to_s }
    end

    def list
      tools
    end

    def dispatch(name, parameters = {}, confirmed: false)
      entry = tool(name)
      raise "Unsupported MCP tool: #{name}" if entry.nil?

      if entry.requires_confirmation && !confirmed
        raise "Tool #{name} requires explicit confirmation"
      end

      case entry.name
      when "list-blueprints"
        render_list_blueprints(parameters)
      when "describe-blueprint"
        render_describe_blueprint(parameters)
      when "validate-manifest"
        render_cli("validate", "manifest", parameters.fetch("manifest_path"))
      when "verify-config"
        render_cli("verify", "config", parameters.fetch("manifest_path"))
      when "verify-plan"
        render_cli("verify", "plan", parameters.fetch("plan_path"))
      when "verify-lifecycle"
        render_cli("verify", "lifecycle", parameters.fetch("snapshot_path"))
      when "render-manifest"
        render_cli("render", "manifest", parameters.fetch("manifest_path"), "--output", parameters.fetch("output_dir"))
      when "export-exit-pack"
        render_cli("export", "exit-pack", parameters.fetch("rendered_dir"), "--output", parameters.fetch("output_path"))
      when "add-compute-group"
        render_add_compute_group(parameters)
      when "resize-compute-group"
        render_resize_compute_group(parameters)
      when "scale-compute-group"
        render_scale_compute_group(parameters)
      when "attach-compute-group"
        render_attach_compute_group(parameters)
      when "detach-compute-group"
        render_detach_compute_group(parameters)
      when "remove-resource"
        render_remove_resource(parameters)
      else
        raise "Unsupported MCP tool: #{name}"
      end
    end

    private

    def tool_definitions
      [
        Tool.new(
          name: "list-blueprints",
          description: "List the supported OPSd blueprint catalog for the active provider.",
          arguments: [],
          cli: ["list", "blueprints"],
          requires_confirmation: false
        ),
        Tool.new(
          name: "describe-blueprint",
          description: "Show the selected OPSd blueprint and variant details.",
          arguments: [
            { "name" => "blueprint", "required" => true, "description" => "Blueprint id to inspect" },
            { "name" => "variant", "required" => false, "description" => "Optional blueprint variant" }
          ],
          cli: ["describe", "blueprint"],
          requires_confirmation: false
        ),
        Tool.new(
          name: "validate-manifest",
          description: "Validate a manifest against the OPSd contract and capability rules.",
          arguments: [
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" }
          ],
          cli: ["validate", "manifest"],
          requires_confirmation: false
        ),
        Tool.new(
          name: "verify-config",
          description: "Verify a manifest against OPSd contract, supported-path, capability, and policy rules.",
          arguments: [
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" }
          ],
          cli: ["verify", "config"],
          requires_confirmation: false
        ),
        Tool.new(
          name: "verify-plan",
          description: "Verify an OpenTofu plan for reversibility and exit-first safety.",
          arguments: [
            { "name" => "plan_path", "required" => true, "description" => "Path to a plan JSON file" }
          ],
          cli: ["verify", "plan"],
          requires_confirmation: false
        ),
        Tool.new(
          name: "verify-lifecycle",
          description: "Verify lifecycle compatibility data against the OPSd lifecycle contract.",
          arguments: [
            { "name" => "snapshot_path", "required" => true, "description" => "Path to a lifecycle snapshot JSON file" }
          ],
          cli: ["verify", "lifecycle"],
          requires_confirmation: false
        ),
        Tool.new(
          name: "render-manifest",
          description: "Render a validated manifest into a runnable OpenTofu stack.",
          arguments: [
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
            { "name" => "output_dir", "required" => true, "description" => "Directory for rendered output" }
          ],
          cli: ["render", "manifest"],
          requires_confirmation: false
        ),
        Tool.new(
          name: "export-exit-pack",
          description: "Bundle rendered OPSd output into a portable exit pack.",
          arguments: [
            { "name" => "rendered_dir", "required" => true, "description" => "Rendered output directory" },
            { "name" => "output_path", "required" => true, "description" => "Exit-pack archive path" }
          ],
          cli: ["export", "exit-pack"],
          requires_confirmation: false
        ),
        Tool.new(
          name: "add-compute-group",
          description: "Add a compute group to a manifest.",
          arguments: [
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
            { "name" => "id", "required" => true, "description" => "Compute group id" },
            { "name" => "role", "required" => true, "description" => "Compute group role" },
            { "name" => "type", "required" => true, "description" => "Compute type" },
            { "name" => "profile", "required" => true, "description" => "Provider profile slug" }
          ],
          cli: ["add", "compute-group"],
          requires_confirmation: true
        ),
        Tool.new(
          name: "resize-compute-group",
          description: "Resize a compute group in a manifest.",
          arguments: [
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
            { "name" => "resource_id", "required" => true, "description" => "Compute group id" },
            { "name" => "profile", "required" => true, "description" => "Provider profile slug" }
          ],
          cli: ["resize", "compute-group"],
          requires_confirmation: true
        ),
        Tool.new(
          name: "scale-compute-group",
          description: "Scale a compute group in a manifest.",
          arguments: [
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
            { "name" => "resource_id", "required" => true, "description" => "Compute group id" },
            { "name" => "replicas", "required" => true, "description" => "Replica count" }
          ],
          cli: ["scale", "compute-group"],
          requires_confirmation: true
        ),
        Tool.new(
          name: "attach-compute-group",
          description: "Attach a compute group to a load balancer.",
          arguments: [
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
            { "name" => "resource_id", "required" => true, "description" => "Compute group id" },
            { "name" => "load_balancer_id", "required" => true, "description" => "Load balancer id" }
          ],
          cli: ["attach", "compute-group"],
          requires_confirmation: true
        ),
        Tool.new(
          name: "detach-compute-group",
          description: "Detach a compute group from a load balancer.",
          arguments: [
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
            { "name" => "resource_id", "required" => true, "description" => "Compute group id" },
            { "name" => "load_balancer_id", "required" => true, "description" => "Load balancer id" }
          ],
          cli: ["detach", "compute-group"],
          requires_confirmation: true
        ),
        Tool.new(
          name: "remove-resource",
          description: "Remove a resource from a manifest.",
          arguments: [
            { "name" => "resource", "required" => true, "description" => "Resource kind" },
            { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
            { "name" => "resource_id", "required" => true, "description" => "Resource id" }
          ],
          cli: ["remove"],
          requires_confirmation: true
        )
      ]
    end

    private

    def tool_payload(entry)
      {
        "name" => entry.name,
        "description" => entry.description,
        "arguments" => entry.arguments,
        "requires_confirmation" => entry.requires_confirmation,
        "cli" => entry.cli
      }
    end

    def render_list_blueprints(parameters)
      render_cli("list", "blueprints")
    end

    def render_describe_blueprint(parameters)
      args = ["describe", "blueprint", parameters.fetch("blueprint")]
      variant = parameters["variant"] || parameters[:variant]
      args += ["--variant", variant] unless variant.nil? || variant.to_s.empty?
      args
    end

    def render_cli(*args)
      args.flatten.compact.map(&:to_s)
    end

    def render_add_compute_group(parameters)
      args = [
        "add", "compute-group", parameters.fetch("manifest_path"),
        "--id", parameters.fetch("id"),
        "--role", parameters.fetch("role"),
        "--type", parameters.fetch("type"),
        "--profile", parameters.fetch("profile")
      ]

      args += ["--replicas", parameters["replicas"].to_s] if parameters.key?("replicas") || parameters.key?(:replicas)
      args += ["--image", parameters["image"]] if parameters["image"]
      args += ["--port", parameters["port"].to_s] if parameters.key?("port") || parameters.key?(:port)
      Array(parameters["attach_to"] || parameters[:attach_to]).each { |value| args += ["--attach-to", value] }
      Array(parameters["links"] || parameters[:links]).each { |value| args += ["--link", value] }
      args
    end

    def render_resize_compute_group(parameters)
      [
        "resize", "compute-group", parameters.fetch("manifest_path"),
        parameters.fetch("resource_id"),
        "--profile", parameters.fetch("profile")
      ]
    end

    def render_scale_compute_group(parameters)
      [
        "scale", "compute-group", parameters.fetch("manifest_path"),
        parameters.fetch("resource_id"),
        "--replicas", parameters.fetch("replicas").to_s
      ]
    end

    def render_attach_compute_group(parameters)
      [
        "attach", "compute-group", parameters.fetch("manifest_path"),
        parameters.fetch("resource_id"),
        "--to", parameters.fetch("load_balancer_id")
      ]
    end

    def render_detach_compute_group(parameters)
      [
        "detach", "compute-group", parameters.fetch("manifest_path"),
        parameters.fetch("resource_id"),
        "--from", parameters.fetch("load_balancer_id")
      ]
    end

    def render_remove_resource(parameters)
      [
        "remove",
        parameters.fetch("resource"),
        parameters.fetch("manifest_path"),
        parameters.fetch("resource_id")
      ]
    end

  end
end
