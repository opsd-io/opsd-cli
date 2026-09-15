# Changelog

## Unreleased

### Features

- None yet.

### Fixes

- None yet.

### Docs

- None yet.

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
