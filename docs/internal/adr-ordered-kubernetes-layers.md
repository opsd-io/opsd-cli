# ADR: Ordered Kubernetes Platform Layers

- Status: Accepted (implementation notes updated)
- Scope: `opsd-cli` Kubernetes manifests and rendered layer plans
- Related: #51, #61

## Context

OPSd needs a provider-neutral way to describe Kubernetes platform composition.
The manifest should select platform capabilities without embedding Helm chart
details, provider implementation, or client-specific values. Rendered output
must have a stable structure so that later GitOps and module work can consume it
deterministically.

## Decision

OPSd defines five canonical Kubernetes layers with fixed semantic IDs, numeric
render order, names, descriptions, and output directories:

| Order | ID | Directory | Responsibility |
| ---: | --- | --- | --- |
| 0 | `bootstrap` | `00-bootstrap` | Initial Argo CD and GitOps hand-off. |
| 10 | `infrastructure` | `10-infrastructure` | Provider and cluster infrastructure integrations. |
| 20 | `monitoring` | `20-monitoring` | Metrics, logs, alerts and dashboards. |
| 30 | `tools` | `30-tools` | Ingress, certificates, DNS and registries. |
| 40 | `applications` | `40-applications` | Application namespaces and workloads. |

The order is part of the OPSd contract. Clients may enable or disable layers,
but may not rename, reorder, or assign their own numeric order.

The manifest represents layer selection under `spec.layers`:

```yaml
spec:
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

Each declared layer requires an explicit boolean `enabled` value. A missing
layer uses the contract default: `bootstrap` and `infrastructure` are enabled,
while `monitoring`, `tools`, and `applications` are disabled. The renderer
always emits the complete five-layer plan and directory structure, including
disabled layers.

The bootstrap layer is intentionally small. `opsd bootstrap` installs the
pinned Argo CD chart directly. When GitOps repository settings are present,
rendering also emits the root Application, AppProjects, and layer Applications
for the client repository. The operator applies the bootstrap Project and root
Application once; Argo CD then reconciles the remaining configuration. Helm
charts and Kubernetes resources supported by the platform renderer are emitted
under their respective generated platform and layer paths. The layer plan
remains broader than the currently implemented component set.

## Ownership boundaries

- This contract owns layer identity, order, descriptions, defaults, and
  manifest-level enablement.
- `modules-kubernetes` owns module metadata, defaults, schemas, and chart
  sources.
- `opsd-cli` synchronizes and locks module repositories and chart artifacts.
- `opsd-cli` currently recognizes selected components and applies module
  defaults, manifest values, and provider overrides. Module JSON Schema value
  validation and provider-default loading remain implementation gaps.
- Provider repositories implement the provider-specific infrastructure behind
  the provider-neutral layer contract.

## Consequences

- Rendered plans are deterministic across providers.
- The manifest remains small and does not vendor or reproduce upstream chart
  values.
- There is no migration alias for the previous placeholder names (`core`,
  `observability`, and `apps`); the new contract is introduced before public
  consumers depend on the placeholder model.
- Additional modules and GitOps resources can populate stable directories
  without changing the layer selection contract; the CLI must explicitly
  support newly added module IDs before it renders them.
