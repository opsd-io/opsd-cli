# OPSd Component Release Contract

This contract applies to distributable OPSd components such as `opsd-cli`, the
asdf plugin, and provider modules. The shared workflow and release-note
machinery are provided by the public reusable workflows repository; each
repository keeps ownership of its own build and publication details.

## Component matrix

| Component | Versioned artifact | Release labels | Publishes independently | Coordination trigger |
| --- | --- | --- | --- | --- |
| `opsd-cli` | platform bundles and docs snapshot | yes | yes | consumes a compatible module pin |
| asdf plugin | plugin repository/tag | yes | yes | update when the CLI URL or install contract changes |
| DigitalOcean modules | module source release | yes | yes | coordinate when CLI rendering requires a new module contract |

All components use the same release-impact labels and precedence:
`major > minor > patch > none`. A component does not bump its version for
`release::none`-only changes.

## Common lifecycle

1. Pull requests receive exactly one release-impact label.
2. Merged changes accumulate on the component's default branch.
3. Release Please opens or updates the release pull request.
4. Release Please calculates the next SemVer and generates grouped notes.
5. The release pull request is reviewed, including dependency pins and the test plan.
6. Merging the release pull request updates the version/changelog and creates the
   protected `vX.Y.Z` tag.
7. The tag pipeline builds and validates the component artifacts.
8. Artifacts are published to durable, versioned storage.
9. Post-release verification downloads the public artifacts, checks metadata
   and checksums, and verifies the documented version.

The last three steps are component-specific, but their success is required
before considering the release complete.

## Dependencies and pins

Dependencies used to build or document a release must be represented by one of:

- a released component version, when compatibility is expressed by SemVer;
- an immutable Git tag, when a named release is the dependency; or
- an immutable commit SHA, when a release tag is not available yet.

Unqualified branches such as `main` are not valid release inputs. A dependency
update should be a separately reviewable change and should state whether it
requires a coordinated release.

## Independent versus coordinated releases

Independent releases are the default. Use them when a component's public
contract remains compatible and consumers can continue using their existing
version or pin.

Coordinate releases when any of the following applies:

- a CLI release requires a new module interface or blueprint contract;
- a module release changes rendering semantics required by the CLI;
- the asdf plugin must change because the CLI artifact naming or download URL
  changes; or
- public documentation must describe a cross-component behavior change.

Coordination means preparing the dependent pins first, releasing the provider
or plugin, and then releasing the consumer against those immutable versions.
It does not require one shared version number across repositories.

## Artifact contract

Every published artifact must have:

- a deterministic name containing component, version, operating system, and
  architecture where applicable;
- a durable versioned URL independent of CI job artifacts;
- a checksum published beside the artifact; and
- release metadata containing at least component name and version.

The consumer's post-release job must verify that the downloaded artifact,
metadata, checksum, installer/plugin, and documentation all refer to the same
version.

## Implementation plan

1. Keep release-impact validation and release preparation in the shared
   reusable workflows repository.
2. Integrate the same workflows into `opsd-cli`, the asdf
   plugin, and provider module repositories.
3. Give every component a small adapter for its version file, artifact build,
   publication, and post-release verification.
4. Move each consumer from branch-based dependency inputs to release tags or
   commit pins.
5. Add a coordinated-release checklist to the Release MR template and test one
   independent and one cross-component release before declaring the contract
   stable.
