# Changelog

## Unreleased

### Features

- None yet.

### Fixes

- None yet.

### Docs

- None yet.

## [0.2.0](https://github.com/opsd-io/opsd-cli/compare/v0.1.0...v0.2.0) (2026-09-25)


### Features

* **cli:** add locked Kubernetes module sources ([#139](https://github.com/opsd-io/opsd-cli/issues/139)) ([8c35661](https://github.com/opsd-io/opsd-cli/commit/8c3566197ec94407c65fb1d129a82f9b2d9c2632))
* **cli:** define bastion access contract ([#141](https://github.com/opsd-io/opsd-cli/issues/141)) ([a322558](https://github.com/opsd-io/opsd-cli/commit/a322558f62330050b2776d2d7873c82b42d812c0))
* **cli:** define Kubernetes module metadata format ([#138](https://github.com/opsd-io/opsd-cli/issues/138)) ([07bdbd0](https://github.com/opsd-io/opsd-cli/commit/07bdbd0935b682c8dd7d9dfd92fada7700302365))
* **cli:** define ordered Kubernetes layer contract ([#136](https://github.com/opsd-io/opsd-cli/issues/136)) ([471c437](https://github.com/opsd-io/opsd-cli/commit/471c43748ebf95f2e9deac18c65afd6c2c045ce6))
* **cli:** extend Kubernetes platform manifest contract ([#140](https://github.com/opsd-io/opsd-cli/issues/140)) ([2a7c97e](https://github.com/opsd-io/opsd-cli/commit/2a7c97ec4e882c49f74309c755adf40f71b0e3b1))
* **cli:** warn on unsafe DOKS control plane access ([#142](https://github.com/opsd-io/opsd-cli/issues/142)) ([a3d2745](https://github.com/opsd-io/opsd-cli/commit/a3d2745648fe13f2dba43f0f890bde0dcd99def0))

## [0.1.0](https://github.com/opsd-io/opsd-cli/compare/v2.1.0...v0.1.0) (2026-09-21)


### ⚠ BREAKING CHANGES

* **cli:** use DigitalOcean cache names ([#42](https://github.com/opsd-io/opsd-cli/issues/42))

### Features

* add cli release bundles ([#5](https://github.com/opsd-io/opsd-cli/issues/5)) ([9e8a907](https://github.com/opsd-io/opsd-cli/commit/9e8a9072e7f9732c8dee36d554967eef3e694f52))
* add shared workflows ([d9e10d9](https://github.com/opsd-io/opsd-cli/commit/d9e10d92c23efb532b1dd940f2832f13794ba450))
* add shared workflows ([249f719](https://github.com/opsd-io/opsd-cli/commit/249f7193c4432b9172c06a23a1bb99d93d0efd86))
* automate CLI version bumps ([#10](https://github.com/opsd-io/opsd-cli/issues/10)) ([8ddf094](https://github.com/opsd-io/opsd-cli/commit/8ddf094c741502f60ee0ab8c8ac2f0a14147a826))
* **ci:** add private integration test caller ([c292a13](https://github.com/opsd-io/opsd-cli/commit/c292a133beb676c8151dfe2b93499a3a6001ab8e))
* **cli:** separate project resource assignments ([#43](https://github.com/opsd-io/opsd-cli/issues/43)) ([6abc78b](https://github.com/opsd-io/opsd-cli/commit/6abc78bd6570b358b0e574e77396e8619caaa97a))
* **cli:** use DigitalOcean cache names ([#42](https://github.com/opsd-io/opsd-cli/issues/42)) ([b6a7465](https://github.com/opsd-io/opsd-cli/commit/b6a746518f297d681186e00e58a83b0a8d3ff367))
* prepare opsd-cli foundation release ([#4](https://github.com/opsd-io/opsd-cli/issues/4)) ([9a41636](https://github.com/opsd-io/opsd-cli/commit/9a416360159e9184aaa25d174a715a71859d65d4))
* run public infrastructure plan ([#24](https://github.com/opsd-io/opsd-cli/issues/24)) ([432e627](https://github.com/opsd-io/opsd-cli/commit/432e6275696a26131603b386722507534482f010))


### Bug Fixes

* **ci:** identify qualification runs uniquely ([#49](https://github.com/opsd-io/opsd-cli/issues/49)) ([c4f18c5](https://github.com/opsd-io/opsd-cli/commit/c4f18c54ac4b37101ec1ee0e803ed0b63c3f3496))
* **ci:** remove temporary release overrides ([#39](https://github.com/opsd-io/opsd-cli/issues/39)) ([795bdd8](https://github.com/opsd-io/opsd-cli/commit/795bdd8785c70aa5e69d6aaa2c83c0d85a9896c1))
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
* **release:** reset first CLI release to 0.1.0 ([#47](https://github.com/opsd-io/opsd-cli/issues/47)) ([50ed00e](https://github.com/opsd-io/opsd-cli/commit/50ed00efac488c29c9a0b7dfe6ad998f51b13cc6))
* render optional Kubernetes Redis ([#26](https://github.com/opsd-io/opsd-cli/issues/26)) ([e822e32](https://github.com/opsd-io/opsd-cli/commit/e822e325442aa81aff2ee1dce8317b2dc9f09c27))
* restore CLI version after withdrawn release ([#27](https://github.com/opsd-io/opsd-cli/issues/27)) ([f1603d5](https://github.com/opsd-io/opsd-cli/commit/f1603d58659c9253f63765b5d34450cbc6788e02))

## [2.1.0](https://github.com/opsd-io/opsd-cli/compare/v2.0.0...v2.1.0) (2026-09-17)


### Features

* **cli:** separate project resource assignments ([#43](https://github.com/opsd-io/opsd-cli/issues/43)) ([6abc78b](https://github.com/opsd-io/opsd-cli/commit/6abc78bd6570b358b0e574e77396e8619caaa97a))

## [2.0.0](https://github.com/opsd-io/opsd-cli/compare/v1.0.1...v2.0.0) (2026-09-17)


### ⚠ BREAKING CHANGES

* **cli:** use DigitalOcean cache names ([#42](https://github.com/opsd-io/opsd-cli/issues/42))

### Features

* **cli:** use DigitalOcean cache names ([#42](https://github.com/opsd-io/opsd-cli/issues/42)) ([b6a7465](https://github.com/opsd-io/opsd-cli/commit/b6a746518f297d681186e00e58a83b0a8d3ff367))


### Bug Fixes

* **ci:** remove temporary release overrides ([#39](https://github.com/opsd-io/opsd-cli/issues/39)) ([795bdd8](https://github.com/opsd-io/opsd-cli/commit/795bdd8785c70aa5e69d6aaa2c83c0d85a9896c1))

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
