# frozen_string_literal: true

require "minitest/autorun"
require "opsd/manifest"

class ManifestValidationTest < Minitest::Test
  def test_valid_v2_vm_manifest_passes
    manifest = OPSd::Manifest.new(base_v2_manifest, profile_catalog: digitalocean_profile_catalog)

    manifest.validate!
  end

  def test_v2_accepts_layer_plan
    data = base_v2_manifest
    data["spec"]["layers"] = {
      "core" => { "enabled" => true },
      "bootstrap" => { "argocd" => { "enabled" => true } },
      "observability" => { "enabled" => false },
      "tools" => { "enabled" => false },
      "apps" => { "enabled" => false }
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
    assert_equal true, OPSd::Manifest.new(data).layers.dig("core", "enabled")
  end

  def test_v2_rejects_unknown_kubernetes_layer
    data = base_v2_manifest
    data["spec"]["layers"] = { "unknown" => {} }

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.layers.unknown is not supported"
  end

  def test_manifest_requires_supported_api_version
    data = base_v2_manifest
    data["apiVersion"] = "opsd.io/unsupported"

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "apiVersion must be opsd.io/v2alpha1"
  end

  def test_v2_requires_origin_family_and_stack
    data = base_v2_manifest
    data["spec"]["origin"].delete("family")
    data["spec"]["origin"].delete("stack")

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.origin.family is required"
    assert_includes error.errors, "spec.origin.stack is required"
  end

  def test_v2_requires_known_load_balancer_references
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["attach_to"] = ["missing-lb"]

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.compute_groups[0].attach_to references unknown load_balancer=missing-lb"
  end

  def test_v2_requires_known_link_targets
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["links"] = ["missing-db"]

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.compute_groups[0].links references unknown target=missing-db"
  end

  def test_v2_rejects_unsupported_digitalocean_vm_profile
    data = base_v2_manifest
    data["spec"]["nodes"][0]["profile"] = "starter"

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.nodes[0].profile=starter is not a supported DigitalOcean vm profile. Use one of: s-1vcpu-1gb, s-1vcpu-2gb, s-2vcpu-4gb"
  end

  def test_v2_rejects_unsupported_database_profile
    data = base_v2_manifest
    data["spec"]["databases"][0]["profile"] = "db-custom"

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.databases[0].profile=db-custom is not a supported DigitalOcean database profile. Use one of: db-s-1vcpu-1gb, db-s-2vcpu-4gb"
  end

  def test_v2_accepts_structured_database_config
    data = base_v2_manifest
    data["spec"]["databases"][0]["config"] = {
      "node_count" => 2,
      "database_name" => "orders",
      "app_user_name" => "orders_app"
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_invalid_structured_database_config
    data = base_v2_manifest
    data["spec"]["databases"][0]["config"] = {"node_count" => 0, "unsupported" => true}

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.databases[0].config.unsupported is not supported"
    assert_includes error.errors, "spec.databases[0].config.node_count must be a positive integer"
  end

  def test_v2_accepts_structured_cache_config
    data = base_v2_manifest
    data["spec"]["caches"][0]["config"] = {
      "node_count" => 2,
      "eviction_policy" => "allkeys-lru"
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_invalid_structured_cache_config
    data = base_v2_manifest
    data["spec"]["caches"][0]["config"] = {"node_count" => 0, "unsupported" => true}

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.caches[0].config.unsupported is not supported"
    assert_includes error.errors, "spec.caches[0].config.node_count must be a positive integer"
  end

  def test_v2_accepts_structured_cdn_config
    data = base_v2_manifest
    data["spec"]["object_storage"] = [{"id" => "assets-main", "profile" => "standard", "visibility" => "private"}]
    data["spec"]["cdn_endpoints"] = [{
      "id" => "cdn-public",
      "origin" => "assets-main",
      "visibility" => "public",
      "config" => {
        "ttl" => 7200,
        "custom_domain" => "cdn.example.com",
        "certificate_name" => "example-com"
      }
    }]

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_invalid_structured_cdn_config
    data = base_v2_manifest
    data["spec"]["object_storage"] = [{"id" => "assets-main", "profile" => "standard", "visibility" => "private"}]
    data["spec"]["cdn_endpoints"] = [{
      "id" => "cdn-public",
      "origin" => "assets-main",
      "visibility" => "public",
      "config" => {"ttl" => 0, "unsupported" => true}
    }]

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.cdn_endpoints[0].config.unsupported is not supported"
    assert_includes error.errors, "spec.cdn_endpoints[0].config.ttl must be a positive integer"
  end

  def test_v2_accepts_structured_object_storage_config
    data = base_v2_manifest
    data["spec"]["object_storage"] = [{
      "id" => "assets-main",
      "profile" => "standard",
      "visibility" => "private",
      "config" => {
        "acl" => "private",
        "force_destroy" => false,
        "versioning_enabled" => true
      }
    }]

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_invalid_structured_object_storage_config
    data = base_v2_manifest
    data["spec"]["object_storage"] = [{
      "id" => "assets-main",
      "profile" => "standard",
      "visibility" => "private",
      "config" => {"acl" => "public", "force_destroy" => "false"}
    }]

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.object_storage[0].config.acl must be one of: private, public-read"
    assert_includes error.errors, "spec.object_storage[0].config.force_destroy must be a boolean"
  end

  def test_v2_accepts_structured_kubernetes_config
    data = base_v2_manifest
    data["spec"]["origin"].merge!("family" => "kubernetes", "variant" => "kubernetes", "stack" => "kubernetes-basic")
    data["spec"]["compute_groups"][0].delete("image")
    data["spec"]["compute_groups"][0].merge!("type" => "cluster", "role" => "cluster", "profile" => "s-2vcpu-4gb")
    data["spec"]["compute_groups"][0]["config"] = {
      "kubernetes_version" => "1.31.1-do.0",
      "ha" => true,
      "node_size" => "s-4vcpu-8gb",
      "node_count" => 3,
      "create_vpc" => false,
      "vpc_uuid" => "vpc-uuid"
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_invalid_structured_kubernetes_config
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["type"] = "cluster"
    data["spec"]["compute_groups"][0]["config"] = {"node_count" => 0, "ha" => "true", "unsupported" => true}

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.compute_groups[0].config.unsupported is not supported"
    assert_includes error.errors, "spec.compute_groups[0].config.node_count must be a positive integer"
    assert_includes error.errors, "spec.compute_groups[0].config.ha must be a boolean"
  end

  def test_v2_accepts_per_resource_destroy_protection
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["lifecycle"] = {"prevent_destroy" => true}
    data["spec"]["databases"][0]["lifecycle"] = {"prevent_destroy" => true}
    data["spec"]["load_balancers"][0]["lifecycle"] = {"prevent_destroy" => true}

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_invalid_per_resource_destroy_protection
    data = base_v2_manifest
    data["spec"]["databases"][0]["lifecycle"] = {"prevent_destroy" => "true", "unsupported" => true}

    error = assert_raises(OPSd::Manifest::ValidationError) do
      OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
    end

    assert_includes error.errors, "spec.databases[0].lifecycle.unsupported is not supported"
    assert_includes error.errors, "spec.databases[0].lifecycle.prevent_destroy must be a boolean"
  end

  def test_v2_requires_dns_domain_when_manage_zone_is_false
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["exposure"] = {
      "public" => true,
      "ports" => [80, 443],
      "dns" => {
        "enabled" => true,
        "manage_zone" => false,
        "record" => "api"
      }
    }

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.compute_groups[0].exposure.dns.domain is required when dns is enabled and manage_zone is false"
  end

  def test_v2_requires_priority_for_mx_additional_dns_records
    data = base_v2_manifest
    data["spec"]["load_balancers"][0]["dns"]["records"] = [
      {
        "type" => "MX",
        "name" => "@",
        "value" => "mail.example.com"
      }
    ]

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.load_balancers[0].dns.records[0].priority is required for MX records"
  end

  def test_v2_allows_multiple_forwarding_rules_for_a_load_balancer
    data = base_v2_manifest
    data["spec"]["load_balancers"][0].delete("protocol")
    data["spec"]["load_balancers"][0].delete("port")
    data["spec"]["load_balancers"][0].delete("target_port")
    data["spec"]["load_balancers"][0]["forwarding_rules"] = [
      {
        "entry_protocol" => "http",
        "entry_port" => 80,
        "target_protocol" => "http",
        "target_port" => 8080
      },
      {
        "entry_protocol" => "https",
        "entry_port" => 443,
        "target_protocol" => "http",
        "target_port" => 8080
      }
    ]
    data["spec"]["load_balancers"][0]["tls"] = {
      "certificate" => {
        "mode" => "existing",
        "name" => "example-com"
      }
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_allows_tcp_and_udp_forwarding_rules
    data = base_v2_manifest
    load_balancer = data["spec"]["load_balancers"][0]
    load_balancer.delete("protocol")
    load_balancer.delete("port")
    load_balancer.delete("target_port")
    load_balancer["forwarding_rules"] = [
      {
        "entry_protocol" => "tcp",
        "entry_port" => 5432,
        "target_protocol" => "tcp",
        "target_port" => 5432
      },
      {
        "entry_protocol" => "udp",
        "entry_port" => 51820,
        "target_protocol" => "udp",
        "target_port" => 51820
      }
    ]

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_unsupported_load_balancer_protocol
    data = base_v2_manifest
    data["spec"]["load_balancers"][0]["protocol"] = "icmp"

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.load_balancers[0].protocol must be one of: http, https, tcp, udp"
  end

  def test_v2_allows_https_forwarding_rules_with_managed_certificate
    data = base_v2_manifest
    load_balancer = data["spec"]["load_balancers"][0]
    load_balancer.delete("protocol")
    load_balancer.delete("port")
    load_balancer.delete("target_port")
    load_balancer["forwarding_rules"] = [
      {
        "entry_protocol" => "https",
        "entry_port" => 443,
        "target_protocol" => "http",
        "target_port" => 8080
      }
    ]
    load_balancer["tls"] = {
      "certificate" => {
        "mode" => "managed",
        "name" => "example-com",
        "domains" => ["example.com"]
      }
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_requires_a_certificate_for_https_forwarding_rules
    data = base_v2_manifest
    load_balancer = data["spec"]["load_balancers"][0]
    load_balancer.delete("protocol")
    load_balancer.delete("port")
    load_balancer.delete("target_port")
    load_balancer["forwarding_rules"] = [
      {
        "entry_protocol" => "https",
        "entry_port" => 443,
        "target_protocol" => "http",
        "target_port" => 8080
      }
    ]

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.load_balancers[0].tls.certificate is required for HTTPS forwarding rules"
  end

  def test_v2_allows_a_dns_records_targeting_a_node_by_reference
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["exposure"] = {
      "public" => true,
      "ports" => [80, 443],
      "dns" => {
        "enabled" => true,
        "record" => "api",
        "target_ref" => "bastion-1",
        "records" => [
          {
            "type" => "A",
            "name" => "bastion",
            "target_ref" => "bastion-1"
          }
        ]
      }
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_unknown_dns_target_references
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["exposure"] = {
      "public" => true,
      "ports" => [80, 443],
      "dns" => {
        "enabled" => true,
        "record" => "api",
        "target_ref" => "missing-node"
      }
    }

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.compute_groups[0].exposure.dns.target_ref references unknown node=missing-node"
  end

  def test_v2_rejects_target_ref_for_non_a_dns_records
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["exposure"] = {
      "public" => true,
      "dns" => {
        "enabled" => true,
        "record" => "api",
        "records" => [
          {
            "type" => "MX",
            "name" => "@",
            "target_ref" => "bastion-1",
            "priority" => 10
          }
        ]
      }
    }

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.compute_groups[0].exposure.dns.records[0].target_ref is not supported for MX records"
  end

  def test_v2_allows_security_egress_preset
    data = base_v2_manifest
    data["spec"]["security"] = {
      "egress" => {
        "preset" => "web"
      }
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_unknown_security_egress_preset
    data = base_v2_manifest
    data["spec"]["security"] = {
      "egress" => {
        "preset" => "chatty"
      }
    }

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.security.egress.preset must be one of: open, web, dns_only"
  end

  def test_v2_allows_a_reserved_ip_for_a_public_node
    data = base_v2_manifest
    data["spec"]["nodes"] = [
      {
        "id" => "bastion-1",
        "type" => "vm",
        "role" => "bastion",
        "profile" => "s-1vcpu-1gb",
        "image" => "ubuntu-24-04",
        "exposure" => {
          "public" => true,
          "reserved_ip" => true,
          "ports" => [22]
        }
      }
    ]

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_a_reserved_ip_for_a_private_node
    data = base_v2_manifest
    data["spec"]["nodes"] = [
      {
        "id" => "bastion-1",
        "type" => "vm",
        "role" => "bastion",
        "profile" => "s-1vcpu-1gb",
        "image" => "ubuntu-24-04",
        "exposure" => {
          "public" => false,
          "reserved_ip" => true
        }
      }
    ]

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.nodes[0].exposure.reserved_ip requires exposure.public=true"
  end

  def test_v2_allows_raw_cloud_init_bootstrap_user_data
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["delivery"] = {
      "mode" => "bootstrap",
      "bootstrap" => {
        "cloud_init_user" => "opsd",
        "ssh_keys" => ["ssh-key-id"],
        "ssh_authorized_keys" => ["ssh-ed25519 AAAA... opsd@example"],
        "user_data" => "#cloud-config\npackages:\n  - curl\n"
      }
    }

    OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate!
  end

  def test_v2_rejects_non_string_cloud_init_bootstrap_user_data
    data = base_v2_manifest
    data["spec"]["compute_groups"][0]["delivery"] = {
      "mode" => "bootstrap",
      "bootstrap" => {
        "user_data" => ["#cloud-config"]
      }
    }

    error = assert_raises(OPSd::Manifest::ValidationError) { OPSd::Manifest.new(data, profile_catalog: digitalocean_profile_catalog).validate! }

    assert_includes error.errors, "spec.compute_groups[0].delivery.bootstrap.user_data must be a string"
  end

  private

  def base_v2_manifest
    {
      "apiVersion" => "opsd.io/v2alpha1",
      "kind" => "Environment",
      "metadata" => {
        "name" => "demo-v2",
        "environment" => "production",
        "region" => "fra1",
        "tags" => ["managed-by-opsd"],
        "labels" => {}
      },
      "spec" => {
        "provider" => "digitalocean",
        "origin" => {
          "blueprint" => "kubernetes-foundation",
          "variant" => "vm",
          "family" => "droplet",
          "stack" => "droplet-managed-postgres",
          "modules" => {
            "repo" => "https://github.com/opsd-io/modules-digitalocean.git",
            "version" => "v1.0.0",
            "commit" => "abcdef1234567890"
          }
        },
        "defaults" => {
          "project" => "demo-v2",
          "network" => "shared",
          "dns_zone" => "example.com"
        },
        "compute_groups" => [
          {
            "id" => "api-public",
            "type" => "vm",
            "role" => "api",
            "replicas" => 2,
            "profile" => "s-1vcpu-1gb",
            "image" => "ubuntu-24-04",
            "port" => 8080,
            "attach_to" => ["lb-public"],
            "links" => ["db-main", "cache-main"],
            "network" => {
              "vpc" => "shared",
              "firewall" => "public"
            },
            "delivery" => {
              "mode" => "bootstrap",
              "source" => {
                "mode" => "external"
              },
              "bootstrap" => {
                "cloud_init_user" => "opsd",
                "ssh_keys" => ["ssh-key-id"]
              }
            },
            "metadata" => {
              "tags" => [],
              "labels" => {}
            }
          }
        ],
        "nodes" => [
          {
            "id" => "bastion-1",
            "type" => "vm",
            "role" => "bastion",
            "profile" => "s-1vcpu-1gb",
            "image" => "ubuntu-24-04",
            "network" => {
              "vpc" => "shared",
              "firewall" => "public"
            },
            "exposure" => {
              "public" => true,
              "ports" => [22]
            }
          }
        ],
        "databases" => [
          {
            "id" => "db-main",
            "engine" => "postgres",
            "profile" => "db-s-1vcpu-1gb",
            "version" => "16"
          }
        ],
        "caches" => [
          {
            "id" => "cache-main",
            "engine" => "redis",
            "profile" => "db-s-1vcpu-1gb"
          }
        ],
        "load_balancers" => [
          {
            "id" => "lb-public",
            "visibility" => "public",
            "protocol" => "http",
            "port" => 80,
            "target_port" => 8080,
            "dns" => {
              "enabled" => true,
              "domain" => "example.com",
              "record" => "api",
              "records" => [
                {
                  "type" => "MX",
                  "name" => "@",
                  "value" => "mail.example.com",
                  "priority" => 10
                }
              ]
            }
          }
        ],
        "object_storage" => [],
        "cdn_endpoints" => [],
        "policies" => {
          "drift_detection" => "strict",
          "managed_output" => true
        }
      }
    }
  end

  def digitalocean_profile_catalog
    {
      "compute" => {
        "droplet" => %w[s-1vcpu-1gb s-1vcpu-2gb s-2vcpu-4gb],
        "kubernetes" => %w[s-2vcpu-4gb]
      },
      "databases" => {
        "postgres" => %w[db-s-1vcpu-1gb db-s-2vcpu-4gb],
        "mysql" => %w[db-s-1vcpu-1gb db-s-2vcpu-4gb]
      },
      "caches" => {
        "redis" => %w[db-s-1vcpu-1gb db-s-2vcpu-4gb]
      },
      "object_storage" => {
        "spaces" => %w[standard]
      }
    }
  end
end
