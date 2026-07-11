# Rust target specifications

This directory contains Rust target JSON files for supported Ardos platforms.
Each file describes one Rust compilation target matching a platform from
`lib/platforms.nix` and `lib/supportedCpus.nix`.

The files are data inputs, not build logic. They should stay aligned with the
platform `config` strings used by Nixpkgs, for example:

- `x86_64-ardos-linux-gnu.json`
- `aarch64-ardos-linux-gnu.json`
- `riscv64gc-ardos-linux-gnu.json`

Add a new file here when adding Rust support for a new Ardos CPU target, and
update the platform list so the rest of the pipeline can select it through the
same target-platform abstraction.
