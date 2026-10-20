# MCP Resources

OPSd exposes a small read-only resource catalog so MCP hosts can inspect the
product data model without calling the CLI.

The catalog is transport-agnostic. It defines the stable resource URIs and
their machine-readable payloads.

## Contract Resources

- `opsd://contract`
  - full machine-readable OPSd contract
  - includes manifest shape, lifecycle data, and rule packs
- `opsd://rule-packs`
  - rule-pack data extracted from the OPSd contract

## Catalog Resources

- `opsd://catalog/blueprints/digitalocean`
  - blueprint catalog entries and variants for the supported provider
- `opsd://catalog/supported-paths/digitalocean`
  - supported path metadata declared in the OPSd contract

## Example Resources

- `opsd://examples`
  - supported example manifests checked into the repository

## Documentation Pointers

- `opsd://docs/pointers`
  - stable links to the canonical docs entrypoints for manifest, commands,
    packaging, exit packs, MCP tool mapping, and quickstart

## Payload Format

Every resource payload is JSON and intentionally stable for machine consumers.
The payloads are derived from existing OPSd sources of truth:

- `docs/contract.yaml`
- `modules/<provider>/blueprints/*.yaml`
- `examples/*.yaml`
- the public docs under `docs/`

## Ownership and Workspace Lookup

Application data comes from `OPSD_APP_ROOT`; selecting another workspace does
not replace the contract, documentation, or supported examples. Provider data
comes from `OPSD_WORKSPACE_ROOT`, using the same local module and release-cache
layout as the CLI.

| Content | Source | Missing content |
| --- | --- | --- |
| Contract, rule packs, supported paths | App `docs/contract.yaml` | Installation must include the contract |
| Examples | App `examples/*.yaml` and `*.yml` | `{"examples": []}` if the app has no examples directory |
| Documentation pointers | App `docs/` | Pointers name the canonical app documentation |
| Blueprints | Workspace `modules/<provider>/blueprints/`, then workspace release cache | Empty `blueprints` list |

Returned paths identify their base with `path_root: "app"` or
`path_root: "workspace"`. Contract source paths, documentation pointers, and
example paths use the app base. Blueprint paths, including cached blueprint
paths, use the workspace base. Workspace `examples/` does not override shipped
examples.

Provider resource URIs name a provider explicitly and do not require a selected
profile. A listed provider means it is active in the contract, not that its
modules have been installed. Blueprint reads do not synchronize modules.
When a local blueprint directory is absent, cached catalogs prefer `main`,
then the lexicographically greatest available release directory, matching
unpinned CLI lookup. Provider metadata follows the same cache ordering.

Blueprint catalog lookups refresh module directories on each read, so a
successful explicit `modules-sync` is visible within the same MCP session.
