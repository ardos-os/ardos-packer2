# Ardos Packer 2 — Development Task Runner

mod build 'justfiles/build.just'
mod cache 'justfiles/cache.just'
mod fmt 'justfiles/fmt.just'

# Enter development shell (default: toolset, or pass 'stdenv' for cross-compilers)
env target="default":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{target}}" in
        default)
            nix develop .#default --extra-experimental-features "nix-command flakes"
            ;;
        stdenv)
            nix develop .#stdenv --extra-experimental-features "nix-command flakes"
            ;;
        *)
            echo "Unknown env target '{{target}}'. Available: default, stdenv" >&2
            exit 1
            ;;
    esac

# Show all available recipes including submodules
default:
    @just --list --list-submodules
