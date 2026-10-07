# opsd-cli

`opsd-cli` generates and validates infrastructure starting points for OPSd
environments.

The CLI uses provider-owned blueprints together with CLI-owned composer
templates to generate Terraform/OpenTofu projects. Provider modules are
resolved from versioned releases and recorded in `opsd.lock.yaml`, so a
generated environment can be reproduced with the same module commit.

The initial supported provider is DigitalOcean. The primary path is a
Kubernetes foundation with an ordered layer plan and selected platform
components. The CLI can render pinned Argo CD, ExternalDNS, External Secrets,
and cert-manager Helm charts when their manifest conditions are met; it also
renders DOKS Gateway API resources. The monitoring and application layers do
not yet provide a complete component catalog. Droplet and Spaces paths are
available where implemented.

## Quick start

```bash
opsd list blueprints
opsd init blueprint kubernetes-foundation environment.yaml
opsd validate manifest environment.yaml
opsd render manifest environment.yaml --output ./generated
```

[Setup](./docs/getting-started/setup.md),
[installation guide](./docs/getting-started/install.md),
[quickstart](./docs/getting-started/quickstart.md), and
[manifest reference](./docs/manifest.md) for details.

See the [central OPSd contribution guide](https://github.com/opsd-io/.github/blob/main/CONTRIBUTING.md)
for the required pull request and commit format, local checks, and
release/testing workflow.
