# ADR: Ordered Kubernetes Platform Layers

- Status: Accepted
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
| 0 | `bootstrap` | `00-bootstrap` | Apply the root app-of-apps and install ArgoCD. |
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

The bootstrap layer is intentionally small. It renders the root `app-of-apps`
entrypoint, whose purpose is to install ArgoCD. Once ArgoCD is available, it
can reconcile the remaining layer applications. Bootstrap is therefore the
initial GitOps hand-off, not a general-purpose container for all pre-platform
resources.

## Ownership boundaries

- This contract owns layer identity, order, descriptions, defaults, and
  manifest-level enablement.
- `modules-kubernetes` owns module metadata and module schemas (#62).
- Source types, version/ref pinning, and lock metadata belong to #63.
- Component selection, values precedence, provider overrides, and detailed
  validation belong to #64.
- Provider repositories implement the provider-specific infrastructure behind
  the provider-neutral layer contract.

## Consequences

- Rendered plans are deterministic across providers.
- The manifest remains small and does not vendor or reproduce upstream chart
  values.
- There is no migration alias for the previous placeholder names (`core`,
  `observability`, and `apps`); the new contract is introduced before public
  consumers depend on the placeholder model.
- Later module and GitOps work can add content to stable directories without
  changing the layer selection contract.
