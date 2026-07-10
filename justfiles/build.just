# justfiles/build.just — Build recipes

# Project root (parent of justfiles/)
root := justfile_directory()
build_dir := root / "build"

nix_flags := "--extra-experimental-features 'nix-command flakes'"

# Build an package exported from the flake outputs by name
pkg name arch="x86_64" target=arch:
    #!/usr/bin/env bash
    set -euo pipefail
    cd '{{root}}'
    outlink='{{build_dir}}/pkg/{{name}}'
    mkdir -p "$(dirname "$outlink")"
    nix run nixpkgs#nix-output-monitor -- build .#packages.{{arch}}-linux.{{name}}-{{target}}-linux-ardos {{nix_flags}} --out-link "$outlink"

# Runs a nix check exported from the flake outputs by name
check name arch="x86_64" target=arch:
    #!/usr/bin/env bash
    set -euo pipefail
    cd '{{root}}'
    outlink='{{build_dir}}/checks/{{name}}'
    mkdir -p "$(dirname "$outlink")"
    nix run nixpkgs#nix-output-monitor -- build .#checks.{{arch}}-linux.{{name}}-{{target}}-linux-ardos {{nix_flags}} --out-link "$outlink"

alias test := check