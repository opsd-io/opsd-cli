# frozen_string_literal: true

require "tmpdir"
require "minitest/autorun"
require "opsd/contract_store"

class ContractStoreTest < Minitest::Test
  def test_loads_machine_readable_contract_from_docs
    store = OPSd::ContractStore.new(app_root: File.expand_path("..", __dir__))

    assert_equal 1, store.contract_version
    assert_equal "opsd.io/v2alpha1", store.contract["api_version"]
    assert_equal "Environment", store.contract["kind"]
    assert_equal "reference", store.provider_model("digitalocean").fetch("status")
    assert_includes store.provider_model("digitalocean").fetch("required_spec_keys"), "compute_groups"
    assert_equal "placeholder", store.provider_model("aws").fetch("status")
    assert_equal "placeholder", store.provider_model("azure").fetch("status")
    assert_equal "placeholder", store.provider_model("gcp").fetch("status")
    assert_includes store.active_provider_names, "digitalocean"
    assert_equal [], store.supported_path_ids("aws")
    assert_includes store.supported_path_ids("digitalocean"), "digitalocean-reference-droplet-single"
    assert_equal "v1.0.0", store.lifecycle_provider_module("digitalocean").dig("versions", "supported").first
    assert_includes store.lifecycle_opentofu.dig("versions", "supported"), "1.10.0"
    assert_includes store.lifecycle_managed_policies.dig("versions", "supported"), "2"

    security = store.rule_pack("security")
    assert_equal 1, security.fetch("version")
    assert_includes security.fetch("rules").map { |rule| rule["id"] }, "OPSD-SEC-001"
    assert_includes security.fetch("rules").map { |rule| rule["id"] }, "OPSD-SEC-002"
    assert_includes security.fetch("rules").map { |rule| rule["id"] }, "OPSD-SEC-003"
  end

  def test_missing_contract_file_raises_a_clear_error
    Dir.mktmpdir("opsd-contract-store") do |root|
      store = OPSd::ContractStore.new(app_root: root)

      error = assert_raises(OPSd::ContractStore::ContractError) { store.contract }

      assert_includes error.errors.first, "contract file not found"
    end
  end
end
