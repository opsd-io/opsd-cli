# frozen_string_literal: true

require "minitest/autorun"
require "opsd/contract_store"
require "opsd/lifecycle_verifier"

class LifecycleVerifierTest < Minitest::Test
  def test_summary_marks_supported_versions_as_supported
    verifier = OPSd::LifecycleVerifier.new(contract_store: contract_store)

    summary = verifier.summary(supported_snapshot)
    findings = verifier.verify(supported_snapshot)

    assert_equal ["supported", "supported", "supported"], summary.map { |component| component["status"] }
    assert_equal [], findings
  end

  def test_verify_reports_warnings_for_deprecated_versions
    verifier = OPSd::LifecycleVerifier.new(contract_store: contract_store)

    findings = verifier.verify(deprecated_snapshot)
    summary = verifier.summary(deprecated_snapshot)

    assert_equal ["supported", "deprecated", "deprecated"], summary.map { |component| component["status"] }
    assert_equal 2, findings.size
    assert findings.all? { |finding| finding.severity == "warning" }
    assert findings.all? { |finding| finding.code == "OPSD-LIFECYCLE-DEPRECATED" }
  end

  def test_verify_returns_distinct_failure_when_upgrade_path_is_missing
    verifier = OPSd::LifecycleVerifier.new(contract_store: contract_store)

    findings = verifier.verify(missing_upgrade_path_snapshot)
    summary = verifier.summary(missing_upgrade_path_snapshot)

    assert_equal "unsupported", summary.first["status"]
    assert_equal 1, findings.size
    assert_equal "blocking", findings.first.severity
    assert_equal "OPSD-LIFECYCLE-UPGRADE-MISSING", findings.first.code
  end

  private

  def contract_store
    @contract_store ||= OPSd::ContractStore.new(app_root: File.expand_path("..", __dir__))
  end

  def supported_snapshot
    {
      "provider" => "digitalocean",
      "provider_version" => "v1.0.0",
      "tofu_version" => "1.10.0",
      "policy_version" => "2"
    }
  end

  def deprecated_snapshot
    {
      "provider" => "digitalocean",
      "provider_version" => "v1.0.0",
      "tofu_version" => "1.9.0",
      "policy_version" => "1"
    }
  end

  def missing_upgrade_path_snapshot
    {
      "provider" => "digitalocean",
      "provider_version" => "v9.9.9",
      "tofu_version" => "1.10.0",
      "policy_version" => "2"
    }
  end
end
