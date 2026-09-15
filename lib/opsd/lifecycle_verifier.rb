# frozen_string_literal: true

module OPSd
  class LifecycleVerifier
    Finding = Struct.new(:severity, :code, :message, :component, :version, :upgrade_path, keyword_init: true) do
      def blocking?
        severity == "blocking"
      end
    end

    class VerificationError < StandardError
      attr_reader :findings, :lifecycle_path

      def initialize(findings, lifecycle_path: nil)
        super("Lifecycle verification failed")
        @findings = findings
        @lifecycle_path = lifecycle_path
      end
    end

    def initialize(contract_store:)
      @contract_store = contract_store
    end

    def verify(snapshot)
      return [finding("blocking", "OPSD-LIFECYCLE-INPUT", "lifecycle snapshot must be a mapping")] unless snapshot.is_a?(Hash)

      findings = []
      findings.concat(check_component(
        "provider module",
        snapshot["provider"],
        snapshot["provider_version"],
        @contract_store.lifecycle_provider_module(snapshot["provider"])
      ))
      findings.concat(check_component(
        "OpenTofu",
        "opentofu",
        snapshot["tofu_version"],
        @contract_store.lifecycle_opentofu
      ))
      findings.concat(check_component(
        "managed policy data",
        "managed_policies",
        snapshot["policy_version"],
        @contract_store.lifecycle_managed_policies
      ))
      findings
    end

    def summary(snapshot)
      return [] unless snapshot.is_a?(Hash)

      [
        component_summary("provider module", snapshot["provider"], snapshot["provider_version"], @contract_store.lifecycle_provider_module(snapshot["provider"])),
        component_summary("OpenTofu", "opentofu", snapshot["tofu_version"], @contract_store.lifecycle_opentofu),
        component_summary("managed policy data", "managed_policies", snapshot["policy_version"], @contract_store.lifecycle_managed_policies)
      ]
    end

    private

    def component_summary(label, component_key, version, lifecycle_data)
      return { "label" => label, "component" => component_key, "status" => "missing", "version" => nil, "upgrade_path" => nil } if blank?(version)
      return { "label" => label, "component" => component_key, "status" => "unavailable", "version" => version.to_s, "upgrade_path" => nil } unless lifecycle_data.is_a?(Hash)

      versions = lifecycle_data.fetch("versions", {})
      supported = Array(versions["supported"]).map(&:to_s)
      deprecated = Array(versions["deprecated"]).map(&:to_s)
      unsupported = Array(versions["unsupported"]).map(&:to_s)
      upgrade_paths = lifecycle_data.fetch("upgrade_paths", {})
      normalized_version = version.to_s

      return { "label" => label, "component" => component_key, "status" => "supported", "version" => normalized_version, "upgrade_path" => nil } if supported.include?(normalized_version)

      if deprecated.include?(normalized_version)
        path = upgrade_paths[normalized_version]
        status = "deprecated"
        return { "label" => label, "component" => component_key, "status" => status, "version" => normalized_version, "upgrade_path" => path }
      end

      if unsupported.include?(normalized_version)
        path = upgrade_paths[normalized_version]
        status = blank?(path) ? "unsupported" : "unsupported-with-upgrade"
        return { "label" => label, "component" => component_key, "status" => status, "version" => normalized_version, "upgrade_path" => path }
      end

      path = upgrade_paths[normalized_version]
      status = blank?(path) ? "unsupported" : "unsupported-with-upgrade"
      { "label" => label, "component" => component_key, "status" => status, "version" => normalized_version, "upgrade_path" => path }
    end

    def check_component(label, component_key, version, lifecycle_data)
      summary = component_summary(label, component_key, version, lifecycle_data)
      case summary["status"]
      when "supported"
        []
      when "deprecated"
        path = summary["upgrade_path"]
        message = "#{label} version #{summary['version']} is deprecated"
        message = "#{message}; upgrade to #{path}" unless blank?(path)
        [finding("warning", "OPSD-LIFECYCLE-DEPRECATED", message, component_key, summary["version"], upgrade_path: path)]
      when "unsupported-with-upgrade"
        [finding("blocking", "OPSD-LIFECYCLE-UNSUPPORTED", "#{label} version #{summary['version']} is unsupported; upgrade to #{summary['upgrade_path']}", component_key, summary["version"], upgrade_path: summary["upgrade_path"])]
      when "unsupported"
        [finding("blocking", "OPSD-LIFECYCLE-UPGRADE-MISSING", "No upgrade path is available for #{label} version #{summary['version']}", component_key, summary["version"])]
      when "missing"
        [finding("blocking", "OPSD-LIFECYCLE-MISSING", "#{label} version is required", component_key, nil)]
      else
        [finding("blocking", "OPSD-LIFECYCLE-UNKNOWN-COMPONENT", "#{label} compatibility data is not available", component_key, summary["version"])]
      end
    end

    def finding(severity, code, message, component, version, upgrade_path: nil)
      Finding.new(
        severity: severity,
        code: code,
        message: message,
        component: component,
        version: version,
        upgrade_path: upgrade_path
      )
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end
