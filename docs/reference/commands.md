# Command Reference

This page explains the command surface at a higher level.

For exact syntax, flags, and edge cases, use `bin/opsd help <command>`.
Completion already covers the discoverable command and flag names, so this page focuses on intent.

## Basics

- `help` shows command-specific help and examples.
- `version` prints the CLI version.
- `completion` manages shell completion for Bash, Zsh, and Fish.
- `config` manages the active CLI configuration.

## Discovery

- `list` shows the available blueprint catalog.
- `describe` prints details for a blueprint, including its supported variants.

## Workflow

- `init` creates a starter manifest from a blueprint.
- `validate` checks a manifest without rendering infrastructure.
- `verify` checks a manifest, plan, or lifecycle snapshot against OPSd rules.
- `render` generates the final OpenTofu handoff from a valid manifest.
- `export` packages a rendered handoff into a portable exit pack.

## Mutations

- `add` adds a supported resource or capability to an existing manifest.
- `resize` changes the size of a supported resource.
- `scale` adjusts the instance count for a supported resource.
- `attach` links one supported resource to another.
- `detach` removes a supported link.
- `remove` removes a supported resource or capability from a manifest.

## Configuration Profiles

Use `config profile` when you need a named local CLI profile.

- `config profile list` shows saved profiles.
- `config profile show` prints one profile.
- `config profile create` adds a new profile.
- `config profile edit` changes an existing profile.
- `config profile use` switches the active profile.
- `config profile current` prints the active profile.

## Completion Installation

Use `completion install` when you want the shell to keep completion current across CLI updates.

- `completion install bash`
- `completion install zsh`
- `completion install fish`

## How To Read This Page

This is a compact reference, not a duplicate of the full help text.
If you need the exact flag list or argument order, trust `bin/opsd help <command>` over this page.
