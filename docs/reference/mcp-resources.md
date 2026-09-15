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
    packaging, exit packs, and quickstart

## Payload Format

Every resource payload is JSON and intentionally stable for machine consumers.
The payloads are derived from existing OPSd sources of truth:

- `docs/contract.yaml`
- `modules/<provider>/blueprints/*.yaml`
- `examples/*.yaml`
- the public docs under `docs/`
