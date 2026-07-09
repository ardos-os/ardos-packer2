# Stage 1: Ardos cross toolchain

`lib/toolchain` builds the package sets and compiler wrappers used to compile
Ardos target packages.

## Inputs

- `nixpkgs`: the original Nixpkgs input, used only to access library helpers.
- `targetPlatform`: an Ardos platform from `lib/platforms.nix`, such as
  `x86_64-linux-ardos`.
- `buildSystem`: the host system string used for native build tools.
- `host`: the output of `lib/host`, including `patchedNixpkgs` and cache
  settings.
- `rustScript`: the helper from `lib/builder/rustScript.nix` used to compile
  small host-side Rust tools for setup hooks.

## Outputs

`default.nix` returns:

- `buildPkgs`: patched Nixpkgs imported for the build machine.
- `crossPkgs`: patched Nixpkgs imported with `crossSystem = targetPlatform` and
  the Ardos overlay enabled.
- `toolchain`: a small public attrset exposing the target C compiler, binutils,
  glibc, and host bash.

## Overlay responsibilities

The Ardos overlay does only target-toolchain work:

1. Patch autotools `config.sub` files so source packages accept the Ardos target
   triplet.
2. Patch cross binutils and glibc where Nixpkgs needs target awareness.
3. Wrap the target `stdenv` so Ardos target packages receive the setup hook from
   `lib/builder/setup`.
4. Install the stable linker-wrapper stub from `lib/builder/hooks/ld-wrapper.sh`
   into cross bintools.
5. Patch LLVM target-environment detection for Ardos.

The stable linker stub is copied into the toolchain, while the mutable linker
translation implementation remains outside it. This keeps toolchain rebuilds
small: iterating on runtime path translation should rebuild target packages, not
binutils itself.
