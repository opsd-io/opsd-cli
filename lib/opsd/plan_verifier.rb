# frozen_string_literal: true

require "json"

require_relative "contract_store"

module OPSd
  class PlanVerifier
    Finding = Struct.new(:severity, :code, :message, :address, keyword_init: true) do
      def blocking?
        severity == "blocking"
      end
    end

    class VerificationError < StandardError
      attr_reader :findings, :plan_path

      def initialize(findings, plan_path: nil)
        super("Plan verification failed")
        @findings = findings
        @plan_path = plan_path
      end
    end

    def initialize(contract_store:)
      @contract_store = contract_store
    end

    def verify(plan)
      resource_changes(plan).flat_map do |change|
        validate_change(change)
      end
    end

    def blocking_findings(findings)
      findings.select(&:blocking?)
    end

    def change_summary(plan)
      changes = resource_changes(plan)
      summary = {
        "additive" => 0,
        "destructive" => 0,
        "replacements" => 0,
        "updates" => 0,
        "noop" => 0,
        "unknown" => 0
      }

      changes.each do |change|
        case normalized_actions(change)
        when ["create"]
          summary["additive"] += 1
        when ["update"]
          summary["updates"] += 1
        when ["delete"]
          summary["destructive"] += 1
        when ["delete", "create"], ["create", "delete"]
          summary["replacements"] += 1
        when ["no-op"], []
          summary["noop"] += 1
        else
          summary["unknown"] += 1
        end
      end

      summary
    end

    private

    def resource_changes(plan)
      value = plan.is_a?(Hash) ? plan["resource_changes"] : nil
      Array(value).select { |entry| entry.is_a?(Hash) }
    end

    def validate_change(change)
      actions = normalized_actions(change)
      address = change["address"].to_s

      case actions
      when ["create"]
        []
      when ["update"]
        validate_update(change, address)
      when ["delete"]
        [
          finding(
            "blocking",
            "OPSD-EXIT-001",
            format_rule_message("reversibility", "OPSD-EXIT-001", "Destroying #{resource_label(change)} #{address} is destructive and outside the supported exit-first path"),
            address: address
          )
        ]
      when ["delete", "create"], ["create", "delete"]
        [
          finding(
            "blocking",
            "OPSD-EXIT-001",
            format_rule_message("reversibility", "OPSD-EXIT-001", "Replacing #{resource_label(change)} #{address} requires a destructive transition and is not supported without an explicit migration path"),
            address: address
          )
        ]
      when ["no-op"], []
        []
      else
        [
          finding(
            "blocking",
            "OPSD-PLAN-UNKNOWN",
            "Unsupported plan action #{actions.inspect} for #{address}",
            address: address
          )
        ]
      end
    end

    def validate_update(change, address)
      before = change.dig("change", "before")
      after = change.dig("change", "after")
      return [] unless before.is_a?(Hash) && after.is_a?(Hash)

      findings = []

      if resource_type(change) == "digitalocean_droplet" && replicas_changed?(before, after)
        findings << finding(
          "warning",
          "OPSD-REL-001",
          format_rule_message("reliability", "OPSD-REL-001", "Updating #{address} changes droplet capacity in-place; confirm the resulting topology remains supported"),
          address: address
        )
      end

      findings
    end

    def replicas_changed?(before, after)
      before["droplet_size"] != after["droplet_size"] || before["size"] != after["size"]
    end

    def normalized_actions(change)
      Array(change.dig("change", "actions")).map(&:to_s)
    end

    def resource_type(change)
      change["type"].to_s
    end

    def resource_label(change)
      type = resource_type(change)
      return "resource" if type.empty?

      type
    end

    def format_rule_message(pack_name, rule_id, fallback)
      rule = rule_by_id(pack_name, rule_id)
      return fallback unless rule.is_a?(Hash)

      summary = rule["summary"].to_s
      summary.empty? ? fallback : "#{fallback} - #{summary}"
    end

    def rule_by_id(pack_name, rule_id)
      pack = @contract_store.rule_pack(pack_name)
      rules = pack.is_a?(Hash) ? Array(pack["rules"]) : []
      rules.find { |rule| rule.is_a?(Hash) && rule["id"] == rule_id }
    end

    def finding(severity, code, message, address:)
      Finding.new(severity: severity, code: code, message: message, address: address)
    end
  end
end
