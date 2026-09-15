# Changelog

## Unreleased

### Features

- None yet.

### Fixes

- None yet.

### Docs

- None yet.

## [1.0.1](https://github.com/opsd-io/opsd-cli/compare/v1.0.0...v1.0.1) (2026-09-15)


### Bug Fixes

* make foundation tests self-contained ([#8](https://github.com/opsd-io/opsd-cli/issues/8)) ([1bab4ee](https://github.com/opsd-io/opsd-cli/commit/1bab4eeff9cf1a38b3f6a240b83a9733cc07aa55))
* publish cli release assets ([#6](https://github.com/opsd-io/opsd-cli/issues/6)) ([d4c549b](https://github.com/opsd-io/opsd-cli/commit/d4c549b2257d051220bb5b0c0f08327d63f0a123))

## 1.0.0 (2026-09-15)


### Features

* add cli release bundles ([#5](https://github.com/opsd-io/opsd-cli/issues/5)) ([9e8a907](https://github.com/opsd-io/opsd-cli/commit/9e8a9072e7f9732c8dee36d554967eef3e694f52))
* add shared workflows ([d9e10d9](https://github.com/opsd-io/opsd-cli/commit/d9e10d92c23efb532b1dd940f2832f13794ba450))
* add shared workflows ([249f719](https://github.com/opsd-io/opsd-cli/commit/249f7193c4432b9172c06a23a1bb99d93d0efd86))
* prepare opsd-cli foundation release ([#4](https://github.com/opsd-io/opsd-cli/issues/4)) ([9a41636](https://github.com/opsd-io/opsd-cli/commit/9a416360159e9184aaa25d174a715a71859d65d4))

## 0.1.0

2026-04-20

Initial public release baseline for OPSd CLI.

This baseline captures the first usable CLI line and starts the public changelog
from a clean release point so future entries can be appended without rewriting
history.

### Features

- portable CLI bundles for Linux amd64 and macOS Apple Silicon
- blueprint discovery, manifest initialization, validation, render, and growth flows
- module release locking for deterministic renders
- shell completion for bash, zsh, and fish
- composer-based OpenTofu output generation

### Fixes

- preserve DNS defaults in blueprint manifests
- tighten manifest validation for unsupported combinations
- correct blueprint completion and manifest completion paths
- stabilize portable bundle and runtime validation
- reuse local workspace modules from lockfile during repeated renders

### Docs

- bootstrap the public documentation set
- standardize CLI help and release documentation
- add release packaging and release process guidance
