# OPSd CLI Architecture Decisions

This document captures stable architecture and product decisions for `opsd-cli`.
It is intended to serve as the default reference for future design and
implementation work.

## Product Role

- `opsd-cli` is the developer-facing entrypoint for OPSd.
- The CLI is intended for developers who do not want to compose infrastructure
  from raw Terraform/OpenTofu modules.
- The CLI starts users from a known-good scenario or blueprint rather than from
  empty infrastructure primitives.

## Source Of Truth

- The selected blueprint or scenario is the seed, not the long-term source of
  truth.
- The generated manifest becomes the editable source of truth for the
  environment.
- Rendered OpenTofu output is a managed artifact and should not be the primary
  place for user customization.
- Manual edits to generated OpenTofu are not the intended steady-state workflow.

## Blueprint-Anchored Evolution

- A user starts from a blueprint and variant because the product must provide a
  working baseline immediately.
- After initialization, the manifest may be modified and re-rendered.
- The baseline from `spec.origin` remains important as provenance and as the
  architectural starting point.
- The product should support in-place environment evolution without requiring
  users to design infrastructure from scratch.

## Environment Evolution Model

- The preferred model is scenario-seeded or blueprint-seeded environment
  evolution.
- The seed gives users a working environment immediately, but it must not become
  a dead-end that forces later manual infrastructure authoring.
- Users should be able to extend an existing environment over time, for example
  by resizing compute or databases and by adding supporting services.
- Typical follow-up changes may include adding Redis, storage, messaging, worker
  groups, or changing replica counts.
- The CLI should manipulate the manifest rather than encouraging direct edits to
  generated OpenTofu.

## Startup Growth Principle

- The product should remain useful after initial onboarding, not only at day
  zero.
- A startup should be able to start from a known-good seed and later evolve the
  same environment through CLI-driven manifest changes.
- The preferred path for growth is:
  - generate from blueprint
  - evolve manifest over time
  - re-render managed OpenTofu
- If the product pushes teams into hand-editing generated OpenTofu for normal
  growth, the architecture has failed its intended purpose.

## Runtime Boundary

- Small and medium architectural extensions should be possible within an
  existing environment when the renderer and provider support them.
- A change that replaces the base runtime family or operating model should be
  treated as a new environment plus migration, not an in-place mutation.
- Examples of migration-boundary changes include VM to App Platform and App
  Platform to Kubernetes.
- Adding adjunct services such as Redis, storage, messaging, worker groups, or
  load-balanced replicas is expected to remain in-place when supported.
- The current supported in-place growth set also includes:
  - adding or removing a CDN endpoint within the `spaces` scenario family
  - adding singleton VM nodes such as bastion hosts within selected droplet
    scenarios

## Scenario Ladder

- Blueprint variants are intentionally structured as a progression across
  operating levels, for example VM, App Platform, and Kubernetes.
- The product therefore supports two different kinds of growth:
  - in-place growth within the current scenario level
  - level-up growth by moving to the next scenario and migrating
- In-place growth covers changes such as resize, scale, add cache, add storage,
  add worker groups, and add load-balanced replicas when the current scenario
  supports them.
- Level-up growth covers changes such as VM to App Platform or App Platform to
  Kubernetes and should be modeled as selecting the next scenario rather than
  rewriting the existing environment in place.
- Scenarios are therefore both:
  - a known-good starting point
  - a ladder of supported next operating models
- The manifest is responsible for day-two evolution within the current scenario
  level, while scenario changes are responsible for stepping the user to the
  next operating level.

## Manifest Semantics

- `compute_groups` model replicated copies of the same workload role.
- `nodes` model singleton machines with distinct purpose, such as bastion,
  cron, or migration hosts.
- In droplet-backed scenarios, singleton `nodes` are rendered as additional VM
  instances alongside the primary workload rather than as a scenario family
  change.
- `replicas` belong to `compute_groups`, not to `nodes`.
- `links` describe runtime dependencies on backing services and supporting
  resources.
- `attach_to` describes traffic attachment to named load balancers.
- `enabled` should be used sparingly for optional add-on style resources, not
  as a blanket replacement for resource presence.
- Repeated copies of the same application role should be modeled as one
  `compute_group` with `replicas > 1`, not as multiple singleton `nodes`.
- CLI resource commands should use manifest `id` values as their stable
  identifiers rather than provider-native ids or Terraform runtime addresses.

## Renderer Direction

- The current product may continue to seed environments from known scenarios or
  blueprint variants.
- The renderer should remain scenario-driven at the baseline level because
  scenarios are the intended entrypoint and operating-level ladder for the
  product.
- Within a selected scenario level, the manifest should support in-place
  evolution through supported mutations.
- The renderer direction is therefore:
  - scenario-driven for baseline selection and level-up transitions
  - manifest-driven for supported day-two evolution within the current scenario
- The architecture should move toward stable per-resource rendering inside a
  scenario level so that add, remove, scale, attach, and resize operations can
  change only the relevant generated files.

## Capability Model

- Not every manifest combination needs to be supported for every blueprint
  variant.
- Capability rules should be owned by the provider blueprint variants, not by an
  ad hoc hardcoded policy in the CLI alone.
- `opsd-cli` should validate manifest edits against blueprint-variant capability
  metadata before render.

## Workspace-Local State

- `opsd-cli` should keep its local working state inside the active workspace,
  not in a shared global home-directory store.
- The intended local state root is `<workspace>/.opsd/`.
- Provider config should be stored in `<workspace>/.opsd/config`.
- Resolved provider module releases should be cached under
  `<workspace>/.opsd/cache/releases/<provider>/<version>`.
- This keeps one workspace self-contained and avoids mixing state across
  unrelated environments handled by the same CLI installation.
- Workspace-local modules and workspace-local lockfiles should remain first-class
  resolution targets.

## CI Confidence Model

- CLI confidence should be split across multiple validation layers rather than a
  single monolithic job.
- The intended layers are:
  - `unit-cli` for command-level and object-level Ruby tests
  - `growth-smoke` for selected day-two mutation flows
  - `render-smoke` for supported end-to-end render verification
- `render-smoke` should verify both:
  - baseline scenario renders
  - selected supported growth paths that are expected to remain renderable
- The render-smoke matrix should be generated dynamically from current blueprint
  metadata and capability rules, then executed through a generated child
  pipeline.
- A separate render-smoke capability coverage report should compare tracked
  blueprint capabilities against the currently generated render-smoke matrix so
  that newly supported growth paths do not get added silently without smoke
  coverage.
- CI should also enforce a simple regression gate on top of that report: the
  number of `not_covered` capability entries must not grow beyond the committed
  baseline unless the baseline is intentionally updated in the same change.
- The product should prefer a functional coverage checklist over raw line
  coverage percentages.

## Scenario Verifier Relationship

- `opsd-cli` render-smoke is the fast confidence layer for:
  - manifest mutation
  - supported growth-path rendering
  - `tofu validate`
- The deeper operational deployability model for:
  - baseline scenario verification
  - supported mutation verification
  - `plan/apply/assert/destroy`
  belongs in `scenario-verifier`, not in `opsd-cli`.
- `opsd-cli` and `scenario-verifier` should still speak the same product
  language for supported growth paths so that renderability and deployability
  stay aligned.

## Repository Boundaries

- `opsd-cli` owns manifest semantics, validation, CLI UX, and rendering.
- Provider repositories own blueprint definitions and blueprint-specific
  capability metadata.
- The verifier repository owns environment verification and end-to-end
  confidence, not manifest authoring.

## Product Site Role

- `opsd.io` should function as the public product entrypoint for OPSd, not only
  as a visual marketing landing page.
- The site should help a new user:
  - understand what OPSd is
  - understand what can be built with it today
  - install the CLI
  - reach a first successful scenario render quickly
  - understand when self-serve use is enough and when support is available
- The site should serve simultaneously as:
  - product landing page
  - docs hub
  - trust and support entrypoint

## Product Site Information Architecture

- The product site and documentation site should be implemented as one site,
  not as two separate public properties in the first iteration.
- The preferred structure is one website with two clearly separated modes:
  - product-facing pages at the root
  - technical documentation under `/docs`
- The site should therefore share:
  - one domain
  - one visual system
  - one deployment flow
  while still keeping product storytelling and technical reference content
  clearly separated in navigation and page structure.
- The preferred first-version site structure is:
  - `Home`
  - `Install`
  - `Quickstart`
  - `Scenarios`
  - `Supported Paths`
  - `How It Works`
  - `Docs`
  - `Releases`
  - `Support`
- `Home` should explain the product in plain technical language and point users
  toward installation and first-run success.
- `Install` should document bundle install, `asdf`, shell completion, supported
  platforms, and install verification.
- `Quickstart` should contain one canonical path from install to first rendered
  environment.
- `Scenarios` should present currently supported blueprints and variants in a
  way that helps users choose the right starting point.
- `Supported Paths` should define the current support boundary clearly, not only
  the aspirational product surface.
- `How It Works` should explain blueprint, manifest, lockfile, render, and
  growth semantics in practical terms.
- `Support` should explain the available engagement model and what users can
  expect from OPSd-led help.

## Documentation Search

- Full-text search for documentation is required in the first public product
  site iteration.
- The search should prioritize technical documentation and help users find:
  - commands
  - manifest concepts
  - scenario names
  - growth paths
  - troubleshooting topics
- The preferred implementation is static-site full-text search rather than a
  custom backend search service.
- The current preferred technical direction is `Pagefind`, because it fits the
  static Astro-based site model and provides genuine full-text search without
  introducing an additional service dependency.
- Search should be treated as part of the self-serve onboarding experience, not
  as optional polish.

## Product Site Messaging

- OPSd should be positioned as scenario-driven infrastructure bootstrap and
  controlled growth, not as a black-box platform or a Terraform replacement.
- The preferred product message is:
  - start from a known-good scenario
  - evolve through supported growth paths
  - render standard OpenTofu output
  - keep control of the generated infrastructure
- The site should avoid generic platform-marketing language and instead explain
  the concrete workflow and product boundaries.
- The site should emphasize technical clarity over aspirational or inflated
  claims.

## Product Site UI Principle

- The product site should be designed by and for engineers.
- Readability should be prioritized over decorative or novelty-oriented UI.
- The preferred visual standard is:
  - clear hierarchy
  - strong contrast
  - predictable navigation
  - code-first presentation where appropriate
- Code examples should be treated as first-class UX elements rather than as
  decorative snippets.
- Wherever code appears publicly, the site should provide:
  - syntax highlighting
  - copy-to-clipboard
  - consistent code block styling across docs, blog, quickstart, and product
    examples
- The site should optimize for fast technical comprehension, not for visual
  spectacle.

## Own-The-Output Principle

- A core OPSd promise is that the generated infrastructure output stays with the
  client.
- The site should explicitly communicate:
  - manifests stay with the client
  - lockfiles stay with the client
  - rendered OpenTofu stays with the client
  - the client can continue operating the generated stack independently
- OPSd should be presented as accelerating bootstrap and supported evolution,
  not as creating dependency through opaque control planes or hidden ownership.
- The intended public framing is:
  - no lock-in by design
  - own the output
  - exit stays clear
- This is a deliberate product and trust decision, even if it reduces the
  incentive to rely on lock-in as a revenue mechanism.

## Support Model

- The public site should include support as part of the product model, not as an
  afterthought.
- The preferred support structure is:
  - self-serve use
  - guided adoption
  - hands-on first deployment
- `Self-serve` should mean users can install OPSd, follow docs, and operate
  within the documented support boundary on their own.
- `Guided adoption` should mean help selecting a scenario, reviewing the first
  manifest, and getting to a successful first render and plan.
- `Hands-on first deployment` should mean OPSd can actively help drive the
  first deployment and supporting workflow setup together with the client.
- The site should describe support honestly as paid acceleration, review, and
  risk reduction rather than as artificial dependency.
- The support offer should remain clearly bounded:
  - supported scenarios and growth paths only
  - no implicit promise of full managed operations unless offered separately
  - no false suggestion of enterprise-style always-on support where that does
    not exist

## Public Site Standard

- The first public site should favor one highly polished and honest entry path
  over a broad but vague feature catalog.
- The first public experience should make it easy to complete:
  - install
  - select a provider
  - inspect blueprints
  - initialize a scenario
  - validate and render a manifest
- A small number of clearly promoted happy paths is preferable to claiming
  broad support without equally clear onboarding.
