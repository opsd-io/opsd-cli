# frozen_string_literal: true

require_relative "manifest"
require_relative "manifest_capabilities_validator"

module OPSd
  class ConfigVerifier
    Finding = Struct.new(:severity, :code, :message, keyword_init: true) do
      def blocking?
        severity == "blocking"
      end
    end

    class VerificationError < StandardError
      attr_reader :findings, :manifest_path

      def initialize(findings, manifest_path: nil)
        super("Config verification failed")
        @findings = findings
        @manifest_path = manifest_path
      end
    end

    def initialize(contract_store:, template_store:)
      @contract_store = contract_store
      @template_store = template_store
    end

    def verify(manifest)
      findings = []
      findings.concat(validate_manifest(manifest))
      findings.concat(validate_contract_manifest(manifest))
      findings.concat(validate_supported_path(manifest))
      findings.concat(validate_capabilities(manifest))
      findings.concat(validate_policy_findings(manifest))
      findings
    end

    def blocking_findings(findings)
      findings.select(&:blocking?)
    end

    private

    def validate_manifest(manifest)
      manifest.validate!
      []
    rescue Manifest::ValidationError => e
      Array(e.errors).map do |message|
        finding("blocking", "OPSD-CONTRACT-STRUCTURE", message)
      end
    end

    def validate_contract_manifest(manifest)
      model = @contract_store.provider_model(manifest.provider)
      return [finding("blocking", "OPSD-CONTRACT-PROVIDER", "Provider #{manifest.provider} is not declared in the OPSd contract")] unless model.is_a?(Hash)

      findings = []

      Array(model["required_spec_keys"]).each do |key|
        next if manifest.spec.key?(key)

        findings << finding("blocking", "OPSD-CONTRACT-REQUIRED", "spec.#{key} is required by the OPSd contract")
      end

      sections = model["sections"]
      if sections.is_a?(Hash)
        sections.each do |section_key, section_model|
          next unless section_model.is_a?(Hash)

          required_shape = section_model["required_shape"]
          next if required_shape.nil?

          value = manifest.spec[section_key]

          case required_shape
          when "array"
            findings << finding("blocking", "OPSD-CONTRACT-SHAPE", "spec.#{section_key} must be an array") unless value.is_a?(Array)
          when "mapping"
            findings << finding("blocking", "OPSD-CONTRACT-SHAPE", "spec.#{section_key} must be a mapping") unless value.is_a?(Hash)
          end
        end
      end

      findings
    end

    def validate_supported_path(manifest)
      return [] if blank?(manifest.composer_blueprint) || blank?(manifest.composer_variant)

      path = @contract_store.supported_paths_for(manifest.provider).find do |entry|
        entry.is_a?(Hash) &&
          entry["blueprint"] == manifest.composer_blueprint &&
          entry["variant"] == manifest.composer_variant
      end

      return [] unless path.nil?

      [finding(
        "blocking",
        "OPSD-CONTRACT-PATH",
        "Blueprint #{manifest.composer_blueprint} variant #{manifest.composer_variant} is not a supported OPSd path for provider #{manifest.provider}"
      )]
    end

    def validate_capabilities(manifest)
      validator = ManifestCapabilitiesValidator.new(template_store: @template_store, provider: manifest.provider)
      validator.validate!(manifest)
      []
    rescue Manifest::ValidationError => e
      Array(e.errors).map do |message|
        finding("blocking", "OPSD-CAPABILITY", message)
      end
    end

    def validate_policy_findings(manifest)
      findings = []
      findings.concat(public_exposure_warning(manifest))
      findings.concat(control_plane_firewall_warnings(manifest))
      findings.concat(reliability_warning(manifest))
      findings
    end

    def control_plane_firewall_warnings(manifest)
      return [] unless manifest.provider == "digitalocean" && manifest.family == "kubernetes"

      bastion_values = manifest.kubernetes_component_values(layer: "infrastructure", component: "bastion")
      control_plane_cidrs = Array(bastion_values["control_plane_cidrs"]).filter_map do |cidr|
        cidr.to_s.strip unless cidr.to_s.strip.empty?
      end
      bastion_enabled = manifest.kubernetes_component_enabled?(layer: "infrastructure", component: "bastion")
      findings = []

      if !bastion_enabled && control_plane_cidrs.empty?
        findings << policy_finding(
          "OPSD-SEC-002",
          "DOKS control-plane firewall is disabled; the Kubernetes API endpoint remains publicly reachable."
        )
      end

      if control_plane_cidrs.any? { |cidr| ["0.0.0.0/0", "::/0"].include?(cidr) }
        findings << policy_finding(
          "OPSD-SEC-003",
          "DOKS control-plane firewall allows unrestricted public access; replace /0 sources with explicit operator CIDRs."
        )
      end

      findings
    end

    def public_exposure_warning(manifest)
      return [] unless public_exposure?(manifest)

      rule = rule_by_id("cost", "OPSD-COST-001")
      message = rule.nil? ? "Public exposure adds recurring cost and should be explicit." : rule.fetch("summary")

      [finding("warning", "OPSD-COST-001", message)]
    end

    def reliability_warning(manifest)
      return [] unless public_exposure?(manifest)
      return [] if total_compute_replicas(manifest) > 1

      rule = rule_by_id("reliability", "OPSD-REL-001")
      message = rule.nil? ? "Highly available workloads should declare redundant compute or managed failover." : rule.fetch("summary")

      [finding("warning", "OPSD-REL-001", message)]
    end

    def public_exposure?(manifest)
      compute_public = Array(manifest.compute_groups).any? { |entry| entry.is_a?(Hash) && entry.dig("exposure", "public") == true }
      node_public = Array(manifest.nodes).any? { |entry| entry.is_a?(Hash) && entry.dig("exposure", "public") == true }
      lb_public = Array(manifest.load_balancers).any? { |entry| entry.is_a?(Hash) && entry["visibility"] == "public" }
      cdn_public = Array(manifest.cdn_endpoints).any? { |entry| entry.is_a?(Hash) && entry["visibility"] == "public" }

      compute_public || node_public || lb_public || cdn_public
    end

    def total_compute_replicas(manifest)
      Array(manifest.compute_groups).sum do |entry|
        entry.is_a?(Hash) ? entry.fetch("replicas", 0).to_i : 0
      end
    end

    def rule_by_id(pack_name, rule_id)
      pack = @contract_store.rule_pack(pack_name)
      rules = pack.is_a?(Hash) ? Array(pack["rules"]) : []
      rules.find { |rule| rule.is_a?(Hash) && rule["id"] == rule_id }
    end

    def policy_finding(rule_id, fallback_message)
      rule = rule_by_id("security", rule_id)
      message = rule.nil? ? fallback_message : rule.fetch("summary")
      finding("warning", rule_id, message)
    end

    def finding(severity, code, message)
      Finding.new(severity: severity, code: code, message: message)
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end
