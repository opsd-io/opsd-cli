# OPSd CLI Process Design

This document captures the current product and workflow decisions behind
`opsd-cli`. It is intentionally focused on process and design, not only on the
current code shape.

## Goal

Build a thin developer-facing layer over infrastructure-as-code that:

- gives developers a simple, guided entry point
- keeps OpenTofu/Terraform as the real exit artifact
- avoids locking the client into an API or proprietary control plane
- supports gradual growth from simple runtime models to more advanced ones

## Product Direction

OPSd is designed around this split:

- `manifest as UX`
- `Terraform/OpenTofu as engine`

Developers should not compose low-level modules directly. They should work with
a higher-level environment manifest. The system then validates that manifest and
later renders a normal IaC stack.

## Responsibility Boundary

OPSd is meant to understand:

- infrastructure topology
- supported capabilities
- safe defaults and guardrails
- validation rules
- change classification

OPSd is not meant to understand:

- application business logic
- database/data migrations
- deployment sequencing inside the app
- cutover strategy
- release validation

This means OPSd can evolve infrastructure shape, but it should not promise full
application migration automation.

## Exit Strategy

OpenTofu/Terraform remains the exit artifact for the client.

The handoff includes:

- infrastructure code
- state/backend ownership on the client side
- client-owned credentials and secrets
- client-owned CI/CD execution
- operational documentation

This is one of the main reasons to keep IaC as the execution layer instead of
moving too early to an API- or UI-only platform model.

## User Experience Model

The user flow is:

1. developer lists blueprints
2. developer inspects a blueprint
3. developer creates a manifest from a blueprint variant
4. developer edits the manifest
5. manifest is validated
6. manifest is rendered into IaC
7. plan/apply happens against client-owned infrastructure

## Why Commented YAML

The generated manifest is intentionally verbose and self-documented.

The rationale:

- developers should not have to jump between YAML and external documentation
- fields like `topology`, `profile`, `kind`, or `mode` need inline legend
- onboarding is easier when context is located next to the editable field

The pattern is:

- `init blueprint` generates a commented starter manifest
- `render` later generates ordinary IaC output without the educational layer

## Family-Based Model

The CLI uses a shared environment model with family-specific validation and
render rules behind blueprint and variant selection.

Current runtime families:

- `droplet`
- `kubernetes`
- `spaces`

The shared contract uses sections such as:

- `metadata`
- `spec.origin`
- `spec.defaults`
- `spec.compute_groups`
- `spec.nodes`
- `spec.databases`
- `spec.caches`
- `spec.load_balancers`
- `spec.object_storage`
- `spec.cdn_endpoints`
- `spec.policies`

Examples live in:

- `examples/kubernetes-environment.yaml`
- `examples/environment-schema-example.yaml`

## Blueprints And Families

Blueprints are the public user-facing entry point.

Blueprints map to composer stacks in `composer/<provider>/stacks/*`.
OPSd then renders runnable OpenTofu stacks from composer templates.

Families remain part of the manifest and validation model, but they are not the
primary public discovery surface of the CLI.

## Composer Boundary

The implementation boundary is now:

- `modules/<provider>/blueprints/*.yaml`
  product-facing entry points
- `composer/<provider>/stacks/*.yaml`
  stack definitions selected by blueprint variants
- `composer/<provider>/templates/*`
  stack templates rendered by OPSd

Provider repositories do not provide render-time scenarios. OPSd renders stack
artifacts directly from the CLI-owned composer templates and uses provider
blueprints only as the product-facing catalog and manifest input.

## Why Not a Full Matrix

The design explicitly avoids building one generated stack per infrastructure
combination.

Instead, the implemented approach is:

- define runtime families
- define supported capabilities
- define resource composition rules
- define supported evolution paths

This avoids combinatorial explosion such as:

- droplet
- droplet + dns
- droplet + postgres
- droplet + mysql
- droplet + valkey
- droplet + lb + postgres + valkey

Instead, the model expresses:

- topology
- optional services
- exposure choices
- security and delivery defaults

## Evolution Model

The model supports additive environment evolution where possible.

Example:

- existing environment: single Droplet
- desired state: same Droplet plus managed PostgreSQL

In practice, this becomes:

- change intent in the manifest
- render updated stack definition
- `tofu plan` shows additive change

This does not mean OPSd migrates application data or application release logic.
It means OPSd models infrastructure evolution cleanly.

## Drift Policy

The policy is:

- source of truth remains manifest + generated IaC
- drift detection should exist
- drift reporting should be explicit
- automatic reverse import into manifest should be limited or avoided

Reason:

- cloud state does not fully express user intent
- reverse-mapping provider state back to a clean product manifest is lossy

So the model is:

- detect drift
- report drift
- let the user either reconcile back to code or update the manifest manually

## Init Scope

The current public init flow is blueprint-based:

- select blueprint
- inspect available variants
- choose a specific `--variant`
- generate a starter manifest

Detailed runtime settings remain editable in the generated manifest.

## Tags and Labels

The shared manifest supports both:

- `metadata.tags`
- `metadata.labels`

Reason:

- tags are useful for simple grouping
- labels are better for `key=value` filtering, inventory, ownership, and
  automation workflows such as dynamic inventory or maintenance targeting

The current starter manifests include basic defaults such as:

- environment
- managed-by-opsd
- runtime family

## Current State

Today the CLI supports:

- `opsd config`
- `opsd list`
- `opsd init`
- `opsd validate`
- `opsd verify`
- `opsd render`
- `opsd export exit-pack`
- `opsd validate manifest <manifest>`

Current limitations:

- `render` only works for stacks implemented in composer templates
- not every possible provider/runtime combination has a composer stack yet
