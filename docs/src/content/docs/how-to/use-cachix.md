---
title: Use the Cachix binary cache
description: Configure the ardos-os.cachix.org substituter so builds download the prebuilt toolchain instead of rebuilding it.
---

Ardos publishes prebuilt store paths on the [Cachix](https://cachix.org/) binary cache at `ardos-os.cachix.org`. The largest entries are the cross toolchain for the Ardos target, the patched Rust and GCC builds, and the packages built with them. Once your machine trusts the cache, `nix build` and `nix flake check` download those paths instead of compiling them locally.

## Before you start

- Nix with flakes enabled.
- The public key below, which Cachix uses to authenticate the store paths it serves.

## Trust the substituter

Add the substituter and its public key to your Nix configuration. On a single-user install, edit `~/.config/nix/nix.conf`:

```
substituters = https://ardos-os.cachix.org
trusted-public-keys = ardos-os.cachix.org-1:ER39Zub8rFCCCdjZ7VUG+654TvPFkH8fvk2Iofzt74s=
```

On a multi-user (daemon) install, the daemon must also trust the substituter, so the same two lines go in `/etc/nix/nix.conf`. You can then reload the daemon with `sudo systemctl reload nix-daemon`.

## Verify that it works

Build anything from the flake. When Nix fetches a path from the cache, it prints the cache URL next to `copying path`, for example:

```
copying path '/nix/store/...-ardos-patched-rust-...' (210.6 MiB) to '/nix/store'...
```

## Use it without touching your Nix config

You can also pass the substituter once, per command. The public key is still required:

```sh
nix build .#default \
  --extra-substituters https://ardos-os.cachix.org \
  --extra-trusted-public-keys ardos-os.cachix.org-1:ER39Zub8rFCCCdjZ7VUG+654TvPFkH8fvk2Iofzt74s=
```

This is useful for a one-off build on a machine you do not want to configure permanently. The `--extra-trusted-*` flags are accepted even by non-root users.

## What is cached

The cache holds everything the example packages and the CI pipeline build:

- The cross toolchain, including the Ardos-patched Rust and GCC builds.
- The `hello`, `hellolibrary`, and other example packages from this repository.
- VM and boot support artifacts where they are built by the checks.

Builds with private derivation names are not uploaded. Only the repository and its checks publish to the cache.
