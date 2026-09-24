# ADR: Provider-Neutral Kubernetes Module Format

- Status: Accepted
- Scope: `modules-kubernetes` repository and `opsd-cli` module metadata validation
- Related: #51, #62, #63, #64

## Context

Kubernetes platform layers need reusable modules without coupling the manifest
to a specific cloud provider or copying upstream chart values into every client
repository. The module repository must describe what a module is, where its
upstream artifact comes from, which layer owns it, and how its values are
validated.

## Repository layout

The provider-neutral repository uses this layout:

```text
modules-kubernetes/
├── catalog.yaml
├── schemas/
│   └── module-metadata.schema.yaml
├── modules/
│   └── <layer>/
│       └── <module-id>/
│           ├── module.yaml
│           ├── defaults.yaml
│           ├── schema.yaml
│           └── README.md
└── extensions/
    └── <provider>/
        └── <module-id>/
            └── values.yaml
```

`module.yaml` is the authoritative metadata entrypoint. Defaults and schema
are separate files so that chart defaults are not mixed with environment or
client values.

## Metadata contract

Each module declares:

- `metadata.id`, `name`, and `description`;
- the canonical Kubernetes layer under `spec.layer`;
- an upstream source of type `helm`, `oci`, or `git`;
- relative paths to provider-neutral defaults and the module schema;
- ownership as `official` or `custom`;
- supported providers and optional provider extension points;
- validation mode: official modules must use `strict`, custom modules may use
  `permissive`.

Example:

```yaml
apiVersion: opsd.io/modules/v1alpha1
kind: KubernetesModule

metadata:
  id: root-app-of-apps
  name: Root App of Apps
  description: Bootstrap entrypoint that installs ArgoCD and hands off GitOps.

spec:
  layer: bootstrap
  source:
    type: helm
    repository: https://charts.example.invalid/opsd
    chart: root-app-of-apps
  defaults: defaults.yaml
  schema: schema.yaml
  ownership:
    type: official
    repository: opsd-io/modules-kubernetes
  supported_providers: [digitalocean, aws, azure, gcp]
  provider_extensions: {}
  validation:
    mode: strict
```

Source-specific version, ref, digest, and lock metadata are deliberately not
defined here. They belong to #63 and are resolved by the client-owned lock
workflow.

## Ownership boundaries

- `modules-kubernetes` owns official module metadata, defaults, schemas, and
  provider-neutral templates.
- Provider repositories own provider-specific infrastructure and extension
  values; they do not redefine the canonical module identity.
- Client repositories may materialize pinned modules and add `custom` modules.
- `opsd-cli` validates the metadata envelope and official/custom boundary;
  detailed component values and manifest overrides belong to #64.

## Consequences

- Official modules have a strict, discoverable contract.
- Custom modules are possible without weakening official module validation.
- Upstream charts are referenced rather than vendored.
- Provider-specific behavior is an extension, not a fork of the provider-neutral
  module definition.
