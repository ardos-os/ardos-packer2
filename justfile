# Ardos Packer 2 — Development Task Runner




# Commands for building ardos-packer's outputs
mod build 'justfiles/build.just'

# Format code
mod fmt 'justfiles/fmt.just'
# Show all available recipes including submodules
default:
    @just --list --list-submodules


# Enter development shell (default: toolset, or pass 'stdenv' for cross-compilers)
env target="default":
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#{{target}}


alias check := build::check
alias test := build::check