# justfiles/build.just — Build recipes

# Project root (parent of justfiles/)
root := justfile_directory()
build_dir := root / "build"

nix_flags := "--extra-experimental-features 'nix-command flakes'"

# Build the Ardos x86_64 stdenv (cross-compilation toolchain) using nom
stdenv:
    #!/usr/bin/env bash
    outlink='{{build_dir}}/stdenv'
    mkdir -p "$(dirname "$outlink")"
    nom build .#packages.x86_64-linux.stdenv-x86_64-linux-ardos {{nix_flags}} --out-link "$outlink"

# Build a specific component of the Ardos x86_64 toolchain (cc, binutils, glibc) using nom
toolchain component:
    #!/usr/bin/env bash
    set -euo pipefail
    outlink='{{build_dir}}/toolchain/{{component}}'
    mkdir -p "$(dirname "$outlink")"
    nom build .#packages.x86_64-linux.toolchain-x86_64-linux-ardos.{{component}} {{nix_flags}} --out-link "$outlink"

# Build an Ardos package by name (e.g., hello, hellolibrary) using nom
pkg name:
    #!/usr/bin/env bash
    set -euo pipefail
    outlink='{{build_dir}}/pkg/{{name}}'
    mkdir -p "$(dirname "$outlink")"
    nom build .#packages.x86_64-linux.{{name}}-x86_64-linux-ardos {{nix_flags}} --out-link "$outlink"
