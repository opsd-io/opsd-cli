# Quickstart

This is the shortest supported path from install to a rendered environment.

For the canonical setup walkthrough, see [Setup](./setup.md).

## 1. Create Or Select A Profile

Run from the activated checkout (Ruby `3.4.10`) or extracted bundle. Select
the workspace before creating a profile. The provider revision below is
compatible with the current CLI; see [Setup](./setup.md) for the release caveat.
For this cloud-free walkthrough, accept the default provider/region and leave
the API token blank.

```bash
export OPSD_APP_ROOT="$PWD"
export OPSD_WORKSPACE_ROOT=/absolute/path/to/workspace
mkdir -p "$OPSD_WORKSPACE_ROOT"
export OPSD_MODULES_DIGITALOCEAN_REF=4394491d50ebd3b1c1c1b6e895577dadb59e6bb8
bin/opsd config profile create work
bin/opsd config profile use work
```

If you already have a profile, use `bin/opsd config profile current` to verify it.

## 2. Inspect The Catalog

```bash
OPSD_PROFILE=work bin/opsd list blueprints
OPSD_PROFILE=work bin/opsd describe blueprint kubernetes-foundation
```

## 3. Initialize A Manifest

```bash
OPSD_PROFILE=work bin/opsd init blueprint kubernetes-foundation "$OPSD_WORKSPACE_ROOT/demo.yaml" --variant kubernetes
```

## 4. Validate And Render

```bash
OPSD_PROFILE=work bin/opsd validate manifest "$OPSD_WORKSPACE_ROOT/demo.yaml"
OPSD_PROFILE=work bin/opsd render manifest "$OPSD_WORKSPACE_ROOT/demo.yaml" --output "$OPSD_WORKSPACE_ROOT/live"
```

## Optional: Render The Kubernetes Platform

The initialized manifest has placeholder GitOps input. For a reproducible
cloud-free check, use the shipped example, synchronize its module and chart
sources, then render to a fresh directory. Git, Helm, Terraform, OpenTofu and
kubeconform must be available in `PATH`.

```bash
cp "$OPSD_APP_ROOT/examples/kubernetes-environment.yaml" "$OPSD_WORKSPACE_ROOT/platform-demo.yaml"
```

In `platform-demo.yaml`, set `spec.compute_groups[0].config.kubernetes_version`
to a concrete version before platform validation. This walkthrough was tested
with `1.33.0-do.0` (Kubernetes schemas `1.33.0`); the example's `latest` placeholder
cannot select a versioned schema. For actual infrastructure, select a version
supported by your provider.

```bash
OPSD_PROFILE=work bin/opsd modules sync "$OPSD_WORKSPACE_ROOT/platform-demo.yaml"
OPSD_PROFILE=work bin/opsd render manifest "$OPSD_WORKSPACE_ROOT/platform-demo.yaml" --output "$OPSD_WORKSPACE_ROOT/platform" --include-platform
OPSD_PROFILE=work bin/opsd validate manifest "$OPSD_WORKSPACE_ROOT/platform-demo.yaml" --platform
```

Platform validation needs network access the first time so it can cache
Terraform/OpenTofu providers and Kubernetes schemas. Once those caches are
warmed, add `--offline` to validate without network access.

## 5. Hand Off To OpenTofu

```bash
cd "$OPSD_WORKSPACE_ROOT/live"
tofu init -backend=false -input=false
tofu validate
```

To connect through MCP after these CLI checks, follow the
[verified compatibility matrix and connection steps](../reference/mcp-hosts.md).
