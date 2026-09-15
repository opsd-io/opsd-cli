# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "minitest/autorun"
require "opsd/provider_catalog_store"

class ProviderCatalogStoreTest < Minitest::Test
  def test_profile_catalog_reads_profiles_from_provider_metadata
    Dir.mktmpdir("opsd-provider-catalog") do |workspace|
      provider_root = File.join(workspace, "modules", "digitalocean")
      FileUtils.mkdir_p(provider_root)
      File.write(File.join(provider_root, "opsd.yaml"), <<~YAML)
        renderer:
          repo: local
          ref: local
        profiles:
          compute:
            droplet:
              - s-1vcpu-1gb
          databases:
            postgres:
              - db-s-1vcpu-1gb
        addons:
          databases:
            - postgres
      YAML

      store = OPSd::ProviderCatalogStore.new(workspace_root: workspace)

      assert_equal(
        {
          "compute" => { "droplet" => ["s-1vcpu-1gb"] },
          "databases" => { "postgres" => ["db-s-1vcpu-1gb"] }
        },
        store.profile_catalog("digitalocean")
      )
      assert_equal({ "databases" => ["postgres"] }, store.addons_catalog("digitalocean"))
    end
  end

  def test_profile_catalog_requires_provider_metadata_file
    Dir.mktmpdir("opsd-provider-catalog") do |workspace|
      store = OPSd::ProviderCatalogStore.new(workspace_root: workspace)

      error = assert_raises(RuntimeError) { store.profile_catalog("digitalocean") }

      assert_includes error.message, "Provider metadata not found for digitalocean"
    end
  end

  def test_profile_catalog_falls_back_to_cached_release_metadata
    Dir.mktmpdir("opsd-provider-catalog") do |workspace|
      cached_root = File.join(workspace, ".opsd", "cache", "releases", "digitalocean", "main", "modules", "digitalocean")
      FileUtils.mkdir_p(cached_root)
      File.write(File.join(cached_root, "opsd.yaml"), <<~YAML)
        renderer:
          repo: local
          ref: local
        profiles:
          compute:
            droplet:
              - s-1vcpu-1gb
        addons:
          databases:
            - postgres
      YAML

      store = OPSd::ProviderCatalogStore.new(workspace_root: workspace)

      assert_equal(
        { "compute" => { "droplet" => ["s-1vcpu-1gb"] } },
        store.profile_catalog("digitalocean")
      )
      assert_equal({ "databases" => ["postgres"] }, store.addons_catalog("digitalocean"))
    end
  end
end
