# OPSd Manifest Schema Decisions

This document is now historical context for the earlier family-based manifest
model.

The active manifest contract lives in:

- `docs/manifest.md`

The material below is kept only as design background for the original
workload/services model.

## Decision Model

Each field is classified as one of:

- `global required`
- `family required`
- `optional`

The decision model keeps the shared contract stable without forcing users to fill
fields that can safely come from defaults or only matter for a specific runtime
family.

## Global Required

These fields exist for every family:

| Field | Why |
| --- | --- |
| `apiVersion` | versioned manifest contract |
| `kind` | explicit document type |
| `metadata.name` | stable environment identity |
| `metadata.environment` | stage classification and default tagging |
| `metadata.region` | placement decision the user should control |
| `metadata.tags` | grouped operations and automation metadata |
| `metadata.labels` | structured key/value automation metadata |
| `spec.provider` | source-of-truth provider in manifest |
| `spec.family` | runtime family selector |
| `spec.workload.kind` | top-level workload intent |
| `spec.workload.topology` | user-facing topology model |
| `spec.workload.profile` | provider-facing size slug |
| `spec.exposure.public` | public/private baseline |
| `spec.security.network.mode` | network baseline across families |
| `spec.security.network.firewall` | firewall/security baseline across families |
| `spec.delivery.mode` | delivery model selector |
| `spec.delivery.source.mode` | source model selector |

## Global Optional

These fields are part of the shared contract but stay optional in the
schema, usually with good defaults or family-specific meaning.

| Field | Notes |
| --- | --- |
| `spec.services.database.*` | only required when database is enabled |
| `spec.services.cache.*` | only required when cache is enabled |
| `spec.load_balancers[].forwarding_rules` | optional multi-listener DigitalOcean forwarding rules; the single `port`/`target_port` shape remains supported as fallback |
| `spec.exposure.dns.*` | only required when DNS is enabled; `target_ref` may be used for droplet-family `A` records that should resolve to a managed node |
| `spec.exposure.redirect_www_to_apex` | relevant mainly for web-facing families |
| `spec.compute_groups[].exposure.reserved_ip`, `spec.nodes[].exposure.reserved_ip` | stable public endpoint for singleton droplet hosts |
| `spec.security.access.public_ssh_cidrs` | active mainly for droplet |
| `spec.compute_groups[].security.egress.preset` | preset outbound policy for public droplets and nodes |
| `spec.delivery.source.image.*` | depends on `source.mode=image` |
| `spec.delivery.source.github.*` | depends on `source.mode=github` |
| `spec.delivery.bootstrap.*` | active mainly for droplet |
| `spec.delivery.env` | optional runtime env |
| `spec.delivery.secret_env` | optional secure env |

## Family Required

### Droplet

| Field | Why |
| --- | --- |
| `spec.workload.image` | base VM image must be explicit |
| `spec.delivery.source.mode` | currently `external` |
| `spec.delivery.bootstrap.cloud_init_user` | bootstrap identity is required |
| `spec.delivery.bootstrap.ssh_keys` | VM access must be defined |
| `spec.security.network.mode` | explicit baseline in shared contract |
| `spec.security.network.firewall` | explicit baseline in shared contract |

Recommended defaults:

- `spec.workload.kind = vm-service`
- `spec.workload.topology = single`
- `spec.workload.profile = s-1vcpu-1gb`
- `spec.security.network.mode = dedicated`
- `spec.security.network.firewall = managed`
- `spec.delivery.mode = bootstrap`

### App Platform

| Field | Why |
| --- | --- |
| `spec.workload.port` | service runtime needs an application port |
| `spec.workload.instances` | desired service scale is explicit |
| `spec.delivery.source.mode` | determines image vs github flow |
| `spec.security.network.mode` | explicit baseline in shared contract |
| `spec.security.network.firewall` | explicit baseline in shared contract |

When `spec.delivery.source.mode = image`, require:

| Field | Why |
| --- | --- |
| `spec.delivery.source.image.registry` | image source definition |
| `spec.delivery.source.image.repository` | image source definition |
| `spec.delivery.source.image.tag` | image version definition |

Recommended defaults:

- `spec.workload.kind = service`
- `spec.workload.topology = platform-service`
- `spec.workload.profile = apps-s-1vcpu-1gb`
- `spec.delivery.mode = image`

### Kubernetes

Current minimum family-required fields:

| Field | Why |
| --- | --- |
| `spec.workload.topology = cluster` | explicit cluster family contract |
| `spec.security.network.mode` | cluster networking baseline must be declared |
| `spec.security.network.firewall` | baseline security mode must be declared |

Recommended defaults:

- `spec.workload.kind = cluster-service`
- `spec.workload.topology = cluster`
- `spec.workload.profile = s-2vcpu-4gb`
- `spec.delivery.mode = gitops`

## Conditional Rules

These rules apply even if some fields remain optional in raw schema form.

| Rule | Meaning |
| --- | --- |
| `database.enabled=true` requires `database.engine` | no implicit DB engine |
| `database.enabled=true` requires `database.profile` | no implicit DB sizing |
| `cache.enabled=true` requires `cache.profile` | avoid partial cache config |
| `dns.enabled=true` requires `dns.domain` and `dns.record` | public endpoint intent must be explicit; `dns.records` may carry supplementary DNS entries such as MX records; droplet-family `A` records may use `target_ref` to resolve a managed node at render time |
| `droplet` singleton hosts with `exposure.reserved_ip=true` require `exposure.public=true` | Reserved IPs are public endpoints |
| `droplet` + `topology=load-balanced` must not use `reserved_ip` | invalid combination |
| `security.egress` is meaningful mainly for public droplets and nodes | outbound policy is most relevant on hosts with internet exposure |
| `kubernetes` must use `topology=cluster` | keep the family explicit |
| `public_ssh_cidrs` is meaningful mainly for `droplet` | family-aware validation |

## Why Tags And Labels Are Both Present

Both stay in the contract:

| Field | Purpose |
| --- | --- |
| `metadata.tags` | simple grouping |
| `metadata.labels` | precise `key=value` automation and inventory filters |

Suggested default labels:

- `environment`
- `managed_by`
- `runtime`
- `role`

These support:

- dynamic inventory
- maintenance group targeting
- governance automation
- ownership reporting

## Init Policy

`opsd init blueprint`

- generates a starter manifest from a blueprint variant
- does not use an interactive wizard
- relies on blueprint defaults plus later manifest editing

## Rendering Implication

The current family manifest is the active rendering contract for OPSd:

- it drives template generation
- it supports semantic validation
- it carries blueprint/variant/composer metadata when needed
- it resolves to a composer stack and generated stack artifact

The renderer:

- consumes the family-based manifest
- produces a stable shared stack layout
- supports additive evolution where possible
- avoids depending on a full matrix of hand-maintained generated directories

## Still Open

- Should `spec.exposure.public` remain explicit if most environments are public?
- Should `cache` stay placeholder-only until a full cross-family model exists?
- Which fields should be hidden entirely from `init` starters for each family?
