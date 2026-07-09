# Host Nixpkgs patches

This directory contains patches applied by `lib/host/default.nix` before any
other stage imports Nixpkgs.

`nixpkgs.patch` teaches Nixpkgs about the Ardos ABI in places that must be
known while constructing package sets, such as platform parsing and compiler
support code. Because this patch changes the source tree seen by every later
stage, keep it minimal and avoid putting per-package build policy here.

Prefer the following locations when possible:

- `lib/toolchain/default.nix` for overlays that adapt cross packages or stdenv.
- `lib/builder/setup` for setup-hook behaviour that should affect Ardos target
  packages without changing Nixpkgs globally.
- `lib/builder/hooks` for linker-wrapper behaviour that should not rebuild the
  cross toolchain when iterated on.
