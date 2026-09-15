# OPSd Composer

The composer is the OPSd-side assembly layer that connects:

- provider blueprints
- implementation variants
- stack definitions
- rendered stack output

The flow is:

`blueprint -> variant -> stack -> composer -> rendered stack`

## Responsibilities

The composer belongs to OPSd, not to the provider module repositories.

Provider repositories keep:

- reusable Terraform/OpenTofu modules
- product-facing blueprint catalogs

The composer keeps:

- component registry
- stack definitions
- composition rules
- renderer inputs

## Provider Layout

Provider-specific composer data lives under:

- `composer/<provider>/components.yaml`
- `composer/<provider>/stacks/*.yaml`

## Rendering Note

`opsd render` uses OPSd-side composer stacks and templates as the active render
path.

Provider repositories provide the versioned modules and blueprint catalog. They
do not contain the active renderer templates; those remain versioned with the
CLI so the generated stack contract stays explicit.
