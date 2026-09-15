# MCP Prompts

OPSd exposes reusable prompt templates for common read and review workflows.

These prompts are designed for MCP hosts that want to guide a user through a
standard OPSd task without inventing a new workflow layer.

## Prompt Catalog

- `inspect-blueprint`
  - review a blueprint, its variants, and the supported OPSd paths behind it
- `inspect-manifest`
  - review a manifest against the OPSd contract and layout expectations
- `verify-config`
  - explain config verification findings for a manifest
- `verify-plan`
  - explain plan verification findings and reversibility concerns
- `export-exit-pack`
  - guide export of a rendered handoff into an exit pack

## Design Notes

- Prompts are parameterized and reusable.
- Prompt text stays aligned with OPSd terminology and existing workflow names.
- The prompt catalog is read-only and does not mutate OPSd state.

## Related Docs

- [MCP Resources](./mcp-resources.md)
- [Manifest Contract](../manifest.md)
- [Command Reference](./commands.md)
- [Exit Pack](../exit-pack.md)
