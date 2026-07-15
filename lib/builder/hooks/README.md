# Linker wrapper hooks

This directory contains the linker-time translation layer used by Ardos target
packages.

## Files

- `ld-wrapper.sh`: stable stub copied into the cross bintools wrapper. It only
  sources `$ARDOS_LD_HOOK` when present and should almost never change, because
  changes to it can rebuild the toolchain.
- `ld-wrapper-impl.sh`: mutable implementation sourced by the stub for Ardos
  package builds. It invokes the Rust translator and replaces the linker
  parameter arrays used by Nixpkgs' `ld-wrapper`.
- `ardos_ld_translate.rs`: host-side translator compiled by `rustScript`. It
  reads `ARDOS_RUNTIME_MAP`, rewrites `-rpath` and dynamic-linker arguments from
  `/nix/store` locations to Ardos runtime locations, and fails the build if an
  unmapped Nix-store runtime path remains.

## Contract

The hook consumes mappings of build-time directories to runtime directories:

```text
/nix/store/.../lib -> /ardos/lib
/nix/store/.../lib/ -> /ardos/lib/
```

Folder mappings (trailing `/`) are expanded on-the-fly via longest-prefix
matching: `/nix/store/.../lib/libfoo.so` matches prefix `/nix/store/.../lib/`
and translates to `/ardos/lib/libfoo.so`.

When multiple mappings have the same prefix length, the last one wins (insertion
order is preserved in the runtime map).

For each translated RPATH, it also adds an `-rpath-link` pointing at the original
Nix-store directory so the linker can still resolve libraries during the build.
The final ELF runtime search paths therefore point at Ardos paths, while link
resolution remains isolated inside declared Nix-store dependencies.
