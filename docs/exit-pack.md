# Exit Pack

`opsd export exit-pack` packages a rendered OPSd handoff into a portable archive.

The goal is to let a client continue operating the rendered OpenTofu stack
without relying on an OPSd service or runtime.

## What It Contains

The export is built from a rendered project directory and includes:

- `opsd.manifest.yaml`
- `opsd.lock.yaml`
- `opsd.auto.tfvars`
- `main.tf`
- `variables.tf`
- `outputs.tf`
- `README.md`
- `scenario.json`
- `tofu.tfvars.example`
- `HANDOFF.md`
- `opsd.exit-pack.json`

## Metadata

The archive metadata captures:

- the OPSd CLI version used to build the archive
- the manifest API version and environment identity
- the pinned provider-module release information from `opsd.lock.yaml`
- the list of packaged artifacts and their sizes

The metadata file is stored at `exit-pack/opsd.exit-pack.json` inside the
archive.

## Reproducibility

The export is deterministic for the same rendered input.

That means the archive can be recreated from the same rendered directory and
should produce the same content ordering and timestamps.

## Recreate The Bundle

Use the CLI on an already rendered project:

```bash
opsd export exit-pack ./rendered --output ./exit-pack.tar.gz
```

Then unpack the archive and continue with the client-owned OpenTofu workflow.
