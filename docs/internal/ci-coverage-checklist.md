# OPSd CLI CI Coverage Checklist

This document tracks functional coverage targets for `opsd-cli`.

The current goal is not line coverage percentage. The goal is confidence in the
developer-facing CLI contract and the supported day-zero and day-two flows.

## CI Job Split

The GitHub Actions pipeline is intentionally split into three validation layers:

- `unit-cli`
  all Ruby tests in `test/*_test.rb`
- `render-smoke`
  selected end-to-end render verification against generated OpenTofu output
  for both baseline scenarios and selected supported growth paths, including
  storage/CDN and singleton-node growth where supported
- `growth-smoke`
  selected day-two mutation flows such as add/remove/resize/scale and re-render

This keeps fast command-level coverage separate from heavier render-path checks.

## Functional Checklist

### `config`

- `profile create`
- `profile configure`
- `profile edit`
- `profile list`
- `profile show`
- `profile use`
- `profile current`
- invalid provider

### `describe`

- summary view
- `--variant` view
- invalid variant

### `init`

- success
- overwrite behavior
- invalid blueprint

### `validate`

- success
- schema failure
- capability failure
- provider catalog failure

### `render`

- success baseline
- success growth path
- unsupported shape
- dynamic child pipeline generation
- render-smoke matrix generation for supported growth cases
- render-smoke capability coverage report for tracked capability families

### `add` / `remove` / `resize` / `scale` / `attach` / `detach`

- happy path
- duplicate ids
- missing arguments
- invalid option values
- unsupported capability path

## Notes

The checklist is product-oriented on purpose.

It should answer:

- can a developer complete the expected flow?
- are unsupported paths rejected clearly?
- do supported growth paths remain renderable over time?

When new CLI commands or new scenario growth paths are added, update this
checklist together with the tests and CI jobs.

## Current foundation coverage

The current test suite treats `kubernetes-foundation` as the supported
DigitalOcean path. Its catalog exposure and rendering are covered by
`test/kubernetes_foundation_test.rb`; obsolete scenario smoke matrices are no
longer part of CI.

That job compares the current report against:

- `docs/internal/coverage/render-smoke-coverage-baseline.yaml`

The gate fails only when `not_covered` grows beyond the committed baseline.

This is a product coverage report, not a line coverage report.
