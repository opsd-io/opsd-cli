# Changelog

## Unreleased

### Features

- None yet.

### Fixes

- None yet.

### Docs

- None yet.

## [1.0.1](https://github.com/opsd-io/opsd-cli/compare/v1.1.0...v1.0.1) (2026-09-16)


### Features

* add cli release bundles ([#5](https://github.com/opsd-io/opsd-cli/issues/5)) ([9e8a907](https://github.com/opsd-io/opsd-cli/commit/9e8a9072e7f9732c8dee36d554967eef3e694f52))
* add shared workflows ([d9e10d9](https://github.com/opsd-io/opsd-cli/commit/d9e10d92c23efb532b1dd940f2832f13794ba450))
* add shared workflows ([249f719](https://github.com/opsd-io/opsd-cli/commit/249f7193c4432b9172c06a23a1bb99d93d0efd86))
* automate CLI version bumps ([#10](https://github.com/opsd-io/opsd-cli/issues/10)) ([8ddf094](https://github.com/opsd-io/opsd-cli/commit/8ddf094c741502f60ee0ab8c8ac2f0a14147a826))
* **ci:** add private integration test caller ([c292a13](https://github.com/opsd-io/opsd-cli/commit/c292a133beb676c8151dfe2b93499a3a6001ab8e))
* prepare opsd-cli foundation release ([#4](https://github.com/opsd-io/opsd-cli/issues/4)) ([9a41636](https://github.com/opsd-io/opsd-cli/commit/9a416360159e9184aaa25d174a715a71859d65d4))
* run public infrastructure plan ([#24](https://github.com/opsd-io/opsd-cli/issues/24)) ([432e627](https://github.com/opsd-io/opsd-cli/commit/432e6275696a26131603b386722507534482f010))


### Bug Fixes

* **ci:** set release please changelog baseline ([#37](https://github.com/opsd-io/opsd-cli/issues/37)) ([5016b14](https://github.com/opsd-io/opsd-cli/commit/5016b1408ca804d7f50b9d537d58b63bc963994d))
* clean withdrawn release entries ([#30](https://github.com/opsd-io/opsd-cli/issues/30)) ([bb5711e](https://github.com/opsd-io/opsd-cli/commit/bb5711e8e17271e421015577dded3b77c3fd7d2e))
* **cli:** exclude vpc from project resources ([#35](https://github.com/opsd-io/opsd-cli/issues/35)) ([7edb35f](https://github.com/opsd-io/opsd-cli/commit/7edb35f2414c3c09634ebdbf93672e006d437f04))
* configure Ruby release component ([#15](https://github.com/opsd-io/opsd-cli/issues/15)) ([7b63d61](https://github.com/opsd-io/opsd-cli/commit/7b63d611f666dca3e13b38799d1160c6f46e68af))
* force CLI release 1.0.1 ([#29](https://github.com/opsd-io/opsd-cli/issues/29)) ([705c385](https://github.com/opsd-io/opsd-cli/commit/705c38552765789cc8022f752e3ccc52badf128d))
* force initial CLI release version ([#21](https://github.com/opsd-io/opsd-cli/issues/21)) ([c5e96c2](https://github.com/opsd-io/opsd-cli/commit/c5e96c26dfbdd81519fa29fa91159c844ee7bf76))
* initialize CLI release version ([#19](https://github.com/opsd-io/opsd-cli/issues/19)) ([a2ca647](https://github.com/opsd-io/opsd-cli/commit/a2ca647b4b54ce14b7cd530bc93ac24ed062d4d2))
* make foundation tests self-contained ([#8](https://github.com/opsd-io/opsd-cli/issues/8)) ([1bab4ee](https://github.com/opsd-io/opsd-cli/commit/1bab4eeff9cf1a38b3f6a240b83a9733cc07aa55))
* public plan workflow inputs ([#25](https://github.com/opsd-io/opsd-cli/issues/25)) ([2b395da](https://github.com/opsd-io/opsd-cli/commit/2b395daa3c28ddb708e4dd95b52796b3e05562c3))
* publish cli release assets ([#6](https://github.com/opsd-io/opsd-cli/issues/6)) ([d4c549b](https://github.com/opsd-io/opsd-cli/commit/d4c549b2257d051220bb5b0c0f08327d63f0a123))
* render optional Kubernetes Redis ([#26](https://github.com/opsd-io/opsd-cli/issues/26)) ([e822e32](https://github.com/opsd-io/opsd-cli/commit/e822e325442aa81aff2ee1dce8317b2dc9f09c27))
* restore CLI version after withdrawn release ([#27](https://github.com/opsd-io/opsd-cli/issues/27)) ([f1603d5](https://github.com/opsd-io/opsd-cli/commit/f1603d58659c9253f63765b5d34450cbc6788e02))

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
