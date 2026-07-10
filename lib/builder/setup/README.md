# Ardos setup hook tools

`lib/builder/setup` implements the setup hook injected into every Ardos target
package by `lib/toolchain`.

## Hook entry point

`ardos-setup.sh` is turned into a Nix setup hook with `makeSetupHook`. During a
package build it:

1. Runs `early-init.rs` to create a temporary `ARDOS_RUNTIME_MAP` file and export
   the linker-hook path as `ARDOS_LD_HOOK`.
1. Registers `populate-map.rs` in configure/build hooks so link steps can see
   dependency runtime mappings before compilation starts.
1. Registers `generate-layout.rs` before fixup to create fallback layout
   metadata for packages that did not provide custom Ardos metadata.
1. Registers `translate-shebangs.rs` after fixup to rewrite script interpreters
   from Nix-store paths to their declared Ardos runtime paths.

## Helper tools

- `early-init.rs`: creates the per-build runtime map and prints shell exports
  consumed by the setup hook.
- `populate-map.rs`: scans Nix build flags and input metadata, follows relevant
  propagated inputs and `nix-support` references, and appends discovered
  `ardos-layout` entries to the runtime map.
- `generate-layout.rs`: writes a conservative default `nix-support/ardos-layout`
  when a package has no explicit layout metadata.
- `translate-shebangs.rs`: walks `$out` and rewrites `#! /nix/store/...`
  interpreters using the runtime map.

The setup hook is deliberately outside the toolchain patches so it can evolve
without forcing full toolchain rebuilds.
