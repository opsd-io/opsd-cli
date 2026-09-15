# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require "minitest/autorun"
require "opsd/config_store"

class ConfigStoreTest < Minitest::Test
  def test_stores_config_inside_workspace_opsd_directory
    Dir.mktmpdir("opsd-config") do |workspace|
      store = OPSd::ConfigStore.new(workspace_root: workspace)

      store.set_profile_value("work", "provider", "aws")
      store.set_profile_value("work", "token", "secret")
      store.set_current_profile("work")

      assert_equal File.join(workspace, ".opsd", "config"), store.path.to_s
      data = YAML.load_file(store.path)
      assert_equal({ "provider" => "aws", "token" => "secret" }, data["profiles"]["work"])
      assert_equal "work", data["current_profile"]
      assert_equal %w[work], store.profile_names
      assert_equal "aws", store.profile_value("work", "provider")
      assert_equal "work", store.current_profile_name
    end
  end

  def test_delete_profile_updates_workspace_local_config
    Dir.mktmpdir("opsd-config") do |workspace|
      store = OPSd::ConfigStore.new(workspace_root: workspace)
      store.set_profile_value("work", "provider", "aws")
      store.set_current_profile("work")

      store.delete_profile("work")

      data = YAML.load_file(store.path)
      assert_equal({}, data.fetch("profiles", {}))
      assert_nil data["current_profile"]
      assert_nil store.current_profile_name
    end
  end

  def test_profile_unset_removes_empty_profiles
    Dir.mktmpdir("opsd-config") do |workspace|
      store = OPSd::ConfigStore.new(workspace_root: workspace)
      store.set_profile_value("work", "provider", "aws")

      store.unset_profile_value("work", "provider")

      data = YAML.load_file(store.path)
      assert_equal({}, data.fetch("profiles", {}))
    end
  end

  def test_unset_current_profile_clears_selection
    Dir.mktmpdir("opsd-config") do |workspace|
      store = OPSd::ConfigStore.new(workspace_root: workspace)
      store.set_profile_value("work", "provider", "aws")
      store.set_current_profile("work")

      store.unset_current_profile

      data = YAML.load_file(store.path)
      assert_nil data["current_profile"]
      assert_nil store.current_profile_name
    end
  end
end
