# OPSd Manifest Contract

This document defines the `opsd.io/v2alpha1` manifest contract used by OPSd
CLI.

The machine-readable OPSd contract and rule packs live in
[`./contract.yaml`](./contract.yaml).

The `v2alpha1` model keeps blueprints as the starting point for environment
bootstrap, but moves the long-term source of truth into the manifest itself.

It is intended to support:

- initialization from a predefined blueprint and variant
- additive and subtractive infrastructure changes over time
- repeated validate -> render -> apply workflows
- managed OpenTofu output generated from structured manifest sections

## Why This Shape Exists

The manifest contract is centered around explicit infrastructure resources
rather than a single abstract workload shape.

Examples of changes this contract is meant to support:

- add a second compute group behind a separate load balancer
- add a singleton node such as a bastion host
- add or remove a database or cache
- keep evolving the manifest without hand-editing generated `.tf` files

## Lifecycle

The intended lifecycle is:

1. initialize an environment from a blueprint and variant
2. persist the chosen blueprint/variant as manifest origin metadata
3. evolve the manifest over time as the source of truth
4. validate the manifest
5. render managed OpenTofu output
6. apply via OpenTofu

In this model:

- the blueprint is the starting point
- the manifest is the long-term source of truth
- rendered OpenTofu output is a managed artifact

## DNS Model

When OPSd manages a DigitalOcean DNS zone, the zone is owned by the generated
setup and can carry both the primary application records and any extra
domain-based records the environment needs.

The intended split is:

- `exposure.dns.record` for the main public application host
- `exposure.dns.records` for supplementary records such as `MX`, `TXT`, `SRV`,
  `A`, or `CNAME`

When a droplet-family environment needs a DNS `A` record to follow a managed
node, the record may use `target_ref` instead of a literal IP. The renderer
resolves that logical reference during export so the final stack still receives
an actual address.

This keeps the web entrypoint explicit while still allowing the same managed
zone to support mail, verification, and other name-based services.

## Contract Shape

```yaml
apiVersion: opsd.io/v2alpha1
kind: Environment

metadata:
  name: <environment-name>
  environment: <development|staging|production>
  region: <provider-region>
  tags: []
  labels: {}

spec:
  provider: <provider>

  origin:
    blueprint: <blueprint-id>
    variant: <variant-id>
    modules:
      repo: <modules-repository-url>
      version: <release-or-tag>
      commit: <resolved-commit-sha>

  defaults: {}

  compute_groups: []
  nodes: []
  databases: []
  caches: []
  load_balancers: []
  object_storage: []
  cdn_endpoints: []
  policies: {}
```

## Top-Level Sections

### `metadata`

Shared environment metadata.

`metadata.name` is expected to serve as the stable environment identity and the
logical project/namespace name used during rendering.

### `spec.provider`

The source-of-truth provider for the manifest.

### `spec.origin`

Records which blueprint and variant the manifest started from, together with
the pinned provider module release used during initialization.

This section preserves bootstrap provenance, but does not override later user
customization of the manifest.

### `spec.defaults`

Shared environment defaults that may be reused during rendering, such as:

- project name
- network name
- DNS zone

This section is intentionally lightweight and may evolve further.

### `spec.compute_groups`

Describes repliable compute workloads.

This section is intended for groups such as:

- API nodes
- worker nodes
- frontend nodes

### `spec.nodes`

Describes singleton compute resources that should not be modeled as groups.

Examples:

- bastion
- cron host
- migration host

### `spec.databases`

Describes relational or similar database resources required by the environment.

### `spec.caches`

Describes cache resources required by the environment.

### `spec.load_balancers`

Describes public or private load balancers and their configuration.

### `spec.object_storage`

Describes object storage resources such as private asset buckets.

### `spec.cdn_endpoints`

Describes CDN-backed public delivery endpoints rooted in object storage.

### `spec.compute_groups[].security`

Describes optional security policy hints that should be rendered into
provider-specific infrastructure.

The current manifest model keeps egress intentionally simple by exposing a
small preset set instead of raw firewall rule authoring.

#### `spec.compute_groups[].security.egress`

Controls outbound firewall behavior for public droplets and similar hosts.

Supported presets:

- `open` - allow general outbound traffic
- `web` - allow DNS, HTTP, HTTPS, and NTP
- `dns_only` - allow DNS-only outbound access

### `spec.policies`

Defines manifest/render lifecycle policies, such as drift detection and whether
rendered output is treated as managed-only.

### `spec.layers`

Defines the ordered platform layers requested for a Kubernetes environment. The
provider implements the infrastructure details for each layer while the
manifest keeps the logical contract consistent across clouds.

The canonical layers and their fixed render order are:

| Order | Layer | Directory | Purpose |
| ---: | --- | --- | --- |
| 0 | `bootstrap` | `00-bootstrap` | Apply the root app-of-apps and install ArgoCD. |
| 10 | `infrastructure` | `10-infrastructure` | Provider and cluster infrastructure integrations. |
| 20 | `monitoring` | `20-monitoring` | Metrics, logs, alerts and dashboards. |
| 30 | `tools` | `30-tools` | Ingress, certificates, DNS and registries. |
| 40 | `applications` | `40-applications` | Application namespaces and workloads. |

The order and directory names are owned by OPSd and cannot be changed in the
manifest. Every declared layer requires an explicit boolean `enabled` flag.
Omitted layers use the defaults from the layer contract: `bootstrap` and
`infrastructure` are enabled; the remaining layers are disabled.

The infrastructure layer may include an optional `bastion` component. When it
is enabled, the DigitalOcean renderer provisions a bastion in the cluster VPC,
assigns a Reserved IP, and adds that address to the DOKS control-plane firewall
sources. DigitalOcean SSH key references and additional inline public keys are
separate inputs; inline keys may include a description for generated handoff
documentation:

```yaml
spec:
  layers:
    infrastructure:
      enabled: true
      components:
        bastion:
          enabled: true
          values:
            user: bastion
            digitalocean_keys:
              - ref: platform-admin-key
                description: Platform team key
            authorized_keys:
              - key: ssh-ed25519 AAAA... alice@example
                description: Alice laptop
            ssh_allow_cidrs:
              - 198.51.100.0/24
            control_plane_cidrs:
              - 203.0.113.10/32
            egress_preset: web
```

Disabling the component removes the bastion and its Reserved IP. Kubernetes
credentials are not installed on the bastion; access is expected to use a
local SSH tunnel or `ProxyJump`. The module provisions and hardens the SSH
server, disables root and password authentication, and stores operator keys
under `/etc/ssh/authorized_keys/<user>` instead of the user's home directory.

For a Kubernetes foundation, the control-plane firewall is enabled when the
bastion is enabled or when `control_plane_cidrs` is configured. The bastion's
Reserved IP is added automatically when the bastion is enabled. Configuration
verification warns when the firewall is disabled or when a `/0` source exposes
the Kubernetes API to unrestricted public access.

The current renderer materializes the ordered layer plan and placeholders. The
Helm/GitOps module outputs are added in their respective implementation stages.

#### Layer components

Each layer may select components from the catalog exposed by the pinned
Kubernetes module release. Component identifiers are stable module IDs; the
CLI does not hardcode the catalog so new module releases can add components
without requiring a CLI release.

```yaml
spec:
  layers:
    tools:
      enabled: true
      components:
        ingress:
          enabled: true
          values:
            replicas: 2
          provider_overrides:
            digitalocean:
              values:
                service_type: LoadBalancer
```

Every selected component requires an explicit boolean `enabled` value. A
component cannot be enabled while its parent layer is disabled. Component
values are merged in this order, from lowest to highest precedence:

1. module defaults;
2. provider defaults;
3. manifest component `values`;
4. manifest `provider_overrides.<provider>.values`.

The module release is pinned once as a whole in `spec.origin.modules`; a
component does not carry a separate source pin. Official module schemas use
JSON Schema and are strict. Custom modules must be explicitly marked
permissive by their module metadata before they can accept provider-specific
extensions.

Example:

```yaml
  layers:
  bootstrap:
    enabled: true
  infrastructure:
    enabled: true
  monitoring:
    enabled: false
  tools:
    enabled: false
  applications:
    enabled: false
```

## Section Shapes

### `compute_groups`

```yaml
compute_groups:
  - id: api-public
    type: vm
    role: api
    replicas: 2
    profile: s-1vcpu-1gb
    image: ubuntu-24-04-x64
    port: 8080
    attach_to:
      - lb-public
    links:
      - db-main
      - cache-main
    network:
      vpc: shared
      firewall: public
    exposure:
      public: true
        dns:
          enabled: true
          domain: example.com
          record: api
          target_ref: bastion-1
          records:
          - type: MX
            name: "@"
            value: mail.example.com
            priority: 10
          - type: A
            name: mail
            value: 203.0.113.10
            ttl: 300
    delivery:
      mode: bootstrap
      source:
        mode: image
        image:
          registry: dockerhub
          repository: nginx
          tag: latest
    metadata:
      tags: []
      labels: {}
```

For Kubernetes compute groups, `config` exposes cluster and node-pool settings:

```yaml
compute_groups:
  - id: primary
    type: cluster
    role: cluster
    replicas: 1
    profile: s-2vcpu-4gb
    config:
      kubernetes_version: latest
      node_pool_name: default
      node_size: s-4vcpu-8gb
      node_count: 3
      node_auto_scale: false
      ha: true
      create_vpc: true
```

Supported fields include Kubernetes version, upgrade and HA flags, VPC settings, node-pool sizing/autoscaling, tags/labels, and maintenance settings.

### Per-resource destroy protection

Resources can opt into explicit destroy protection:

```yaml
databases:
  - id: db-main
    engine: postgres
    profile: db-s-1vcpu-1gb
    lifecycle:
      prevent_destroy: true
```

The same `lifecycle.prevent_destroy` shape is supported on compute groups, nodes, databases, caches, load balancers, object storage, and CDN endpoints. Kubernetes cluster groups use the same explicit policy at the cluster resource boundary.

### `nodes`

```yaml
nodes:
  - id: bastion-1
    type: vm
    role: bastion
    profile: s-1vcpu-1gb
    image: ubuntu-24-04-x64
    network:
      vpc: shared
      firewall: public
    exposure:
      public: true
      reserved_ip: true
```

For droplet nodes, `exposure.reserved_ip: true` allocates a stable public
DigitalOcean Reserved IP and requires `exposure.public: true`.

### `delivery.bootstrap.user_data`

Droplet bootstrap can pass a small raw cloud-init document to the provider.
This is useful for minimal first-boot provisioning while keeping SSH key
injection in `bootstrap.ssh_keys`:

```yaml
delivery:
  mode: bootstrap
  source:
    mode: external
  bootstrap:
    # Linux user created by cloud-init for Ansible and other provisioning tools.
    cloud_init_user: opsd
    # Existing DigitalOcean SSH key ID or fingerprint, passed to the droplet resource.
    ssh_keys:
      - your-ssh-key-id
    # Actual public key material installed in opsd's ~/.ssh/authorized_keys.
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... opsd@example
    # Optional raw cloud-config merged with the generated opsd user setup.
    user_data: |
      #cloud-config
      packages:
        - curl
      runcmd:
        - [bash, -lc, "echo provisioned > /etc/opsd-provisioned"]
```

`ssh_keys` are DigitalOcean key IDs or fingerprints used by the provider.
`ssh_authorized_keys` are the actual public key strings installed for
`cloud_init_user`. When `user_data` is present, OPSd adds that user to the
cloud-config document instead of dropping the SSH configuration.

### `compute_groups` vs `nodes`

The manifest distinguishes between replicated workload groups and singleton
machines.

#### `compute_groups`

`compute_groups` represent sets of identical compute instances that serve the
same runtime role.

A compute group is used when:

- all instances run the same workload role
- all instances share the same profile, image, delivery model, and dependency links
- the main difference is the replica count
- the group may optionally sit behind a shared load balancer

Examples:

- three CMS web nodes behind a public load balancer
- two API nodes serving the same application
- four worker nodes processing the same queue

In this model:

- `id` identifies the logical workload group
- `replicas` defines how many identical instances belong to that group
- the group is the unit of scaling, attachment, and role definition

#### `nodes`

`nodes` represent singleton machines that should be modeled individually rather
than as part of a replicated group.

A node is used when:

- the machine has a unique purpose
- it should exist as exactly one instance
- it is managed independently from horizontally scaled workloads

Examples:

- bastion host
- migration host
- cron host
- ad hoc utility VM
- dedicated admin box

In this model:

- each node is a single explicitly named machine
- nodes do not use `replicas` as the primary scaling mechanism
- nodes are intended for special-purpose infrastructure, not horizontally scaled application tiers

#### Practical Rule

Use `compute_groups` for repeated copies of the same workload.

Use `nodes` for one-off machines with a distinct operational role.

For example:

- a CMS served by three identical VMs should be modeled as one `compute_group` with `replicas: 3`
- a bastion host in the same environment should be modeled separately in `nodes`

### `databases`

```yaml
databases:
  - id: db-main
    engine: postgres
    profile: db-s-1vcpu-1gb
    version: "16"
    config:
      # Provider-specific database options with stable OPSd defaults.
      node_count: 2
      database_name: app
      app_user_name: app
```

`config` is optional for PostgreSQL and MySQL databases. Supported fields are `node_count`, `database_name`, and `app_user_name`; omitted fields keep their existing defaults.

### `caches`

```yaml
caches:
  - id: cache-main
    engine: valkey
    profile: db-s-1vcpu-1gb
    config:
      # Optional Valkey-specific settings.
      node_count: 2
      eviction_policy: allkeys-lru
```

`config` is optional for Redis caches. Supported fields are `node_count` and `eviction_policy`; omitted fields keep their existing defaults.

### `load_balancers`

```yaml
load_balancers:
  - id: lb-public
    visibility: public
    tls:
      certificate:
        mode: managed
        name: example-com
        domains:
          - example.com
    forwarding_rules:
      - entry_protocol: http
        entry_port: 80
        target_protocol: http
        target_port: 8080
      - entry_protocol: https
        entry_port: 443
        target_protocol: http
        target_port: 8080
      - entry_protocol: tcp
        entry_port: 5432
        target_protocol: tcp
        target_port: 5432
      - entry_protocol: udp
        entry_port: 51820
        target_protocol: udp
        target_port: 51820
    dns:
      enabled: true
      domain: example.com
      record: api
      records:
        - type: MX
          name: "@"
          value: mail.example.com
          priority: 10
        - type: A
          name: mail
          value: 203.0.113.10
          ttl: 300

    - id: lb-internal
      visibility: private
      protocol: http
      port: 8080
      target_port: 8080
```

Forwarding rules support `http`, `https`, `tcp`, and `udp`. TCP and UDP rules use transport-level healthchecks and do not set an HTTP healthcheck path.

### `policies`

```yaml
policies:
  drift_detection: strict
  managed_output: true
```

### `object_storage`

```yaml
object_storage:
  - id: assets-main
    profile: standard
    visibility: private
    config:
      # Optional Spaces access and lifecycle settings.
      acl: private
      force_destroy: false
      versioning_enabled: true
```

`config` is optional for object storage. Supported fields are `acl` (`private` or `public-read`), `force_destroy`, and `versioning_enabled`.

### `cdn_endpoints`

```yaml
cdn_endpoints:
  - id: cdn-public
    origin: assets-main
    visibility: public
    config:
      # Optional CDN provider settings.
      ttl: 7200
      custom_domain: cdn.example.com
      certificate_name: example-com
    dns:
      enabled: true
      domain: example.com
      record: assets
      records:
        - type: MX
          name: "@"
          value: mail.example.com
          priority: 10
        - type: A
          name: mail
          value: 203.0.113.10
          ttl: 300
```

`config` is optional for public CDN endpoints. Supported fields are `ttl`, `custom_domain`, and `certificate_name`; omitted fields keep their existing defaults.

## Field Semantics

### `id`

Stable identifier for an object within its section.

`id` is the logical handle used for:

- dependency links
- load balancer attachment
- per-resource edits
- stable mapping from manifest objects to generated output

All CLI resource identifiers should refer to manifest `id` values, not to
provider-native ids, Terraform state addresses, or runtime API object ids.

For example:

- `opsd remove load-balancer cms-public` refers to `load_balancers[].id == cms-public`
- `opsd resize database db-main --profile ...` refers to `databases[].id == db-main`

This keeps CLI operations anchored to the manifest as the source of truth rather
than to provider-specific runtime identifiers.

### `role`

Human-meaningful intent of a compute group or singleton node.

Examples:

- `api`
- `frontend`
- `worker`
- `bastion`
- `cms`

`role` is primarily descriptive and operational.

It helps distinguish workload purpose such as:

- web tier
- API tier
- worker tier
- bastion
- migration host

### `replicas`

`replicas` defines how many identical instances belong to a `compute_group`.

Use `replicas` when:

- the instances are operationally the same
- they share the same role, profile, image, and delivery model
- they scale as one logical group

Do not model repeated copies of the same workload as separate `nodes`.

### `profile`

Provider-facing size or class identifier used by the renderer.

### `attach_to`

Declares that a compute group should be attached to one or more named load
balancers.

`attach_to` describes serving topology, not application dependency.

It answers the question:

"Through which load balancer does traffic reach this workload?"

Typical examples:

- a public web tier attached to a public load balancer
- an internal API tier attached to a private load balancer

`attach_to` should reference valid ids from `spec.load_balancers`.

### `links`

A simple list of object ids describing runtime dependencies.

`links` are intended to describe backing services and supporting resources used
by a workload.

They answer the question:

"What backing resources does this workload use?"

Initial intended meaning:

- this compute object consumes or depends on the linked object

Examples:

- app group -> database
- app group -> cache
- CMS -> object storage
- worker -> messaging service

This field is intentionally lightweight and may later evolve into richer link
objects if needed.

`links` and `attach_to` are not interchangeable:

- use `links` for backing services and supporting resources
- use `attach_to` for ingress and traffic distribution infrastructure

### `enabled`

`enabled` should be used only for optional resources that may logically exist as
part of the environment model but be switched on or off by product-supported
workflow.

Good uses of `enabled` include:

- optional cache
- optional object storage
- optional CDN endpoint
- optional messaging service

Avoid using `enabled` as a blanket replacement for resource presence.

For resources that are naturally modeled as a list of distinct objects, adding
or removing the object is usually clearer than keeping a disabled entry.

Practical rule:

- use `enabled` for optional singleton-style add-ons
- use list add/remove for naturally plural resource types

### `visibility`

Used by `load_balancers` to distinguish:

- `public`
- `private`

### `network.firewall`

Represents a named firewall policy or a simple firewall mode reference.

The first phase assumes a lightweight policy model rather than a fully
described firewall resource graph.

## Example

The following is a schema-level example showing how optional resources are
represented. It is not the minimal `kubernetes-foundation` starter manifest;
only the resource combinations implemented by the selected composer stack can
be rendered.

```yaml
apiVersion: opsd.io/v2alpha1
kind: Environment

metadata:
  name: acme-platform
  environment: production
  region: fra1
  tags:
    - opsd
    - production
  labels:
    owner: platform-team
    cost_center: engineering

spec:
  provider: digitalocean

  origin:
    blueprint: kubernetes-foundation
    variant: kubernetes
    modules:
      repo: https://github.com/opsd-io/modules-digitalocean.git
      version: v1.0.0
      commit: abcdef1234567890

  defaults:
    project: acme-platform
    network: shared
    dns_zone: example.com

  compute_groups:
    - id: api-public
      type: vm
      role: api
      replicas: 2
      profile: s-1vcpu-1gb
      image: ubuntu-24-04-x64
      port: 8080
      attach_to:
        - lb-public
      links:
        - db-main
        - cache-main
      network:
        vpc: shared
        firewall: public
      delivery:
        mode: bootstrap
        source:
          mode: image
          image:
            registry: dockerhub
            repository: nginx
            tag: latest
      metadata:
        tags:
          - public
        labels:
          tier: web

  nodes:
    - id: bastion-1
      type: vm
      role: bastion
      profile: s-1vcpu-1gb
      image: ubuntu-24-04-x64
      network:
        vpc: shared
        firewall: public
      exposure:
        public: true

  databases:
    - id: db-main
      engine: postgres
      profile: db-s-1vcpu-1gb
      version: "16"

  caches:
    - id: cache-main
      engine: valkey
      profile: db-s-1vcpu-1gb

  load_balancers:
    - id: lb-public
      visibility: public
      protocol: http
      port: 80
      target_port: 8080
      dns:
        enabled: true
        domain: example.com
        record: api

    - id: lb-internal
      visibility: private
      protocol: http
      port: 8080
      target_port: 8080

    security:
      egress:
        preset: web

  policies:
    drift_detection: strict
    managed_output: true
```

## Relationship To Blueprints

In `v2alpha1`, a blueprint is still responsible for giving the user a
predefined starting point.

That blueprint is expected to initialize:

- one or more `compute_groups`
- optional `nodes`
- optional `databases`
- optional `caches`
- optional `load_balancers`
- `origin` metadata

After initialization, the manifest becomes the source of truth and may evolve
independently of the original blueprint defaults.

## What v2alpha1 Does Not Try To Solve Yet

This version does not yet try to define:

- a full generic infrastructure graph DSL
- arbitrary resource kinds
- full reverse import from rendered or cloud state back into manifest
- every possible cross-cloud service category
- automated migration from older manifest experiments

The goal of `v2alpha1` is to define a practical, evolvable manifest model that
extends the current blueprint bootstrap flow into a longer-lived infrastructure
workflow.
