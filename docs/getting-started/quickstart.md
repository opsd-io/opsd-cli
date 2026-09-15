# Quickstart

This is the shortest supported path from install to a rendered environment.

For the canonical setup walkthrough, see [Setup](./setup.md).

## 1. Create Or Select A Profile

```bash
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
OPSD_PROFILE=work bin/opsd init blueprint kubernetes-foundation demo.yaml --variant kubernetes
```

## 4. Validate And Render

```bash
OPSD_PROFILE=work bin/opsd validate manifest demo.yaml
OPSD_PROFILE=work bin/opsd render manifest demo.yaml --output live/
```

## 5. Hand Off To OpenTofu

```bash
cd live
tofu init -backend=false -input=false
tofu validate
```

If you are using a workspace, set `OPSD_WORKSPACE_ROOT` to the directory that contains
`modules/<provider>/*` before running the commands above.
