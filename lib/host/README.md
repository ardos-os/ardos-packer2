# Stage 0: host nixpkgs

`lib/host` prepares the Nixpkgs tree that every later pipeline stage imports.
It is intentionally small: it applies the repository's Nixpkgs compatibility
patches and exposes the Cachix configuration used by the rest of the build.

## Inputs

- `nixpkgs`: the upstream Nixpkgs source passed by `lib/default.nix`.

## Outputs

`default.nix` returns:

- `patchedNixpkgs`: the upstream Nixpkgs source after applying
  `patches/nixpkgs.patch`.

## How it fits in the pipeline

1. `lib/default.nix` imports this stage first.
1. `lib/toolchain` re-imports `patchedNixpkgs` for the requested build system
   and target platform.
1. Later stages do not need to know which Nixpkgs patches were required; they
   consume the patched package sets exposed by the toolchain stage.

Keep this stage limited to changes that must affect the Nixpkgs source itself.
Target-package behaviour should usually live in `lib/toolchain` overlays or in
`lib/builder` hooks so changes do not invalidate the whole patched Nixpkgs
input unnecessarily.
