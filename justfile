# Ardos Packer 2 — Development Task Runner

mod build 'justfiles/build.just'
mod cache 'justfiles/cache.just'

# Show all available recipes including submodules
default:
    @just --list --list-submodules
