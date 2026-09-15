# frozen_string_literal: true

require "pathname"

require_relative "contract_store"
require_relative "template_store"

module OPSd
  class McpPromptCatalog
    Prompt = Struct.new(:name, :description, :arguments, :template, keyword_init: true)

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

    def prompts
      [
        inspect_blueprint_prompt,
        inspect_manifest_prompt,
        verify_config_prompt,
        verify_plan_prompt,
        export_exit_pack_prompt
      ]
    end

    def prompt(name)
      prompts.find { |entry| entry.name == name.to_s }
    end

    def render(name, parameters = {})
      entry = prompt(name)
      raise "Unsupported MCP prompt: #{name}" if entry.nil?

      render_template(entry.template, normalize_parameters(parameters))
    end

    private

    def inspect_blueprint_prompt
      Prompt.new(
        name: "inspect-blueprint",
        description: "Review a blueprint, its variants, and the supported OPSd paths behind it.",
        arguments: [
          { "name" => "provider", "required" => true, "description" => "OPSd provider name such as digitalocean" },
          { "name" => "blueprint", "required" => true, "description" => "Blueprint id to inspect" },
          { "name" => "variant", "required" => false, "description" => "Optional blueprint variant to review" }
        ],
        template: <<~PROMPT
          Inspect the OPSd blueprint `{{blueprint}}` for provider `{{provider}}`.

          Use the OPSd blueprint catalog and the machine-readable contract to answer:
          - what the blueprint is for
          - which variants exist
          - which supported path entries map to this blueprint

          If `variant` is provided, focus on that variant and explain the supported
          runtime, components, and any relevant restrictions.

          Reference facts:
          - provider: {{provider}}
          - blueprint: {{blueprint}}
          - blueprint variants: {{blueprint_variants}}
          - variant: {{variant}}
          - supported paths: {{supported_paths}}

          Prefer OPSd terms from the contract and docs rather than inventing new ones.
        PROMPT
      )
    end

    def inspect_manifest_prompt
      Prompt.new(
        name: "inspect-manifest",
        description: "Review an OPSd manifest against the active contract and common lifecycle rules.",
        arguments: [
          { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" },
          { "name" => "focus", "required" => false, "description" => "Optional area to focus on, such as topology or delivery" }
        ],
        template: <<~PROMPT
          Review the OPSd manifest at `{{manifest_path}}`.

          Summarize:
          - provider and origin metadata
          - compute groups, nodes, databases, caches, load balancers, object storage, and CDN endpoints
          - any drift between the manifest shape and the OPSd contract

          If `focus` is set, prioritize that area.

          Use the manifest contract from `docs/contract.yaml` and the canonical
          manifest reference in `docs/manifest.md`.

          Focus: {{focus}}
        PROMPT
      )
    end

    def verify_config_prompt
      Prompt.new(
        name: "verify-config",
        description: "Analyze a manifest using OPSd config verification rules and explain the findings.",
        arguments: [
          { "name" => "manifest_path", "required" => true, "description" => "Path to a manifest file" }
        ],
        template: <<~PROMPT
          Verify the OPSd manifest at `{{manifest_path}}` with the OPSd config
          contract and capability rules.

          Explain:
          - which contract requirements are satisfied
          - which checks are blocking
          - which findings are warnings
          - what should happen next in the OPSd flow

          Use the contract data from `docs/contract.yaml`, especially:
          - manifest.required_top_level_keys
          - manifest.provider_models
          - lifecycle
          - rule packs

          Produce the result in the same terminology used by OPSd `verify config`.
        PROMPT
      )
    end

    def verify_plan_prompt
      Prompt.new(
        name: "verify-plan",
        description: "Review a plan for reversibility and explain whether the change stays inside the supported exit-first path.",
        arguments: [
          { "name" => "plan_path", "required" => true, "description" => "Path to a Terraform/OpenTofu plan JSON file" }
        ],
        template: <<~PROMPT
          Verify the OPSd plan JSON at `{{plan_path}}`.

          Explain:
          - whether the change is additive, destructive, or a replacement
          - which resource changes would violate the exit-first path
          - whether the plan looks compatible with supported OPSd growth

          Use the OPSd plan verification rules and the reversibility policy in the
          machine-readable contract.

          Keep the explanation aligned with OPSd `verify plan` output.
        PROMPT
      )
    end

    def export_exit_pack_prompt
      Prompt.new(
        name: "export-exit-pack",
        description: "Guide a user through exporting a rendered handoff into an exit pack.",
        arguments: [
          { "name" => "rendered_dir", "required" => true, "description" => "Rendered OPSd output directory" },
          { "name" => "output_path", "required" => false, "description" => "Destination archive path" }
        ],
        template: <<~PROMPT
          Export the rendered OPSd handoff in `{{rendered_dir}}` into an exit pack.

          Explain:
          - what the archive contains
          - why the archive is client-owned
          - how the user should continue with OpenTofu after export

          If `output_path` is provided, mention it explicitly as the target archive.

          Reference the handoff and packaging guidance from:
          - `docs/exit-pack.md`
          - `docs/release/packaging.md`

          Output path: {{output_path}}
        PROMPT
      )
    end

    def render_template(template, parameters)
      template.gsub(/\{\{([a-zA-Z0-9_]+)\}\}/) do
        key = Regexp.last_match(1)
        value = parameters.fetch(key, "")
        value.nil? ? "" : value.to_s
      end.strip
    end

    def normalize_parameters(parameters)
      parameters.each_with_object({}) do |(key, value), memo|
        memo[key.to_s] = value
      end.merge(
        "supported_paths" => supported_paths_summary,
        "blueprint_variants" => blueprint_variants_summary(parameters[:provider] || parameters["provider"], parameters[:blueprint] || parameters["blueprint"])
      )
    end

    def supported_paths_summary
      @contract_store.supported_paths_for("digitalocean").map do |entry|
        "#{entry['blueprint']}:#{entry['variant']}"
      end.join(", ")
    end

    def blueprint_variants_summary(provider, blueprint_id)
      provider = provider.to_s
      blueprint_id = blueprint_id.to_s
      return "" if provider.empty? || blueprint_id.empty?

      blueprint = @template_store.blueprint(provider: provider, id: blueprint_id)
      return "" if blueprint.nil?

      Array(blueprint[:variants]).map { |variant| variant.fetch("id") }.join(", ")
    end
  end
end
