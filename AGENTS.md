### Requirements of `ardos-packer2`

`ardos-packer2` is a **declarative and reproducible ROM generator for Ardos OS**, built on top of Nix's derivation system, leveraging its build engine, isolation, caching, and parallelism, but **without depending on Nix's runtime model**.

It is a rewrite of the original [ardos-packer](https://github.com/ardos-os/ardos-packer) project, originally written in Rust.

The main requirements are:

- Use **only Nix derivations** as the build unit.
- Leverage Nix's **sandbox**, **dependency graph**, **local/remote cache**, and **incremental builds**.
- Generate a **ROM (`.squashfs`) with the Ardos OS filesystem structure (modified FHS)**, without `/nix/store`.
- Treat **Ardos as its own platform/target** (e.g., `x86_64-*-ardos-*`), separate from conventional Linux GNU.
- Build a **`stdenv`** that reuses Nix's `stdenv` infrastructure but adapts the compilation process to the Ardos runtime.
- During **build**, compilers can only see dependencies declared in `/nix/store`, ensuring total isolation.
- At **runtime**, binaries must look for libraries only in the final Ardos paths, without depending on `/nix/store` or `patchelf`.
- Each derivation must declare its **runtime installation layout** (where its files will exist in the ROM), which is the single source of truth. Consumers never assume paths like `/usr/lib` or `/ardos/lib`.
- The linker must automatically obtain runtime paths from declared dependencies, avoiding global configurations and "split brain" issues.
- The ROM generator must automatically compute the **transitive closure** of dependencies and include all necessary files, without the user having to manually list indirect dependencies.
- The kernel, bootloader, disk image, ROM, and VM boot scripts must be **independent artifacts**, each represented by their own derivations.
- The system must support **cross-compilation** for other architectures (such as ARM64) simply by changing the target platform, reusing the same infrastructure.
- The goal is to provide an **excellent development experience**, where a developer who changes only one Ardos component recompiles only that component and the artifacts that depend on it, while everything else is obtained from the Nix cache.

For more technical details about the project, first take a look at the project's README.md and then examine the project's code to clarify more specific questions.

## Your mode of work

Your mode of work is to be minimalist and avoid unnecessary work. Don't reinvent the wheel. Analyze the existing context in Nixpkgs and our code, identify the abstractions already present, and always propose the smallest architectural change possible. Iterate on your changes until you find the canonical way to do something.

Also, always optimize the code for build time and cache hits. Avoid triggering colossal unnecessary rebuilds in cases where the applied patches don't produce different output.

## Architecture

The project is organized into pipeline stages, each with its own directory under `lib/`:

```
lib/host/         Stage 0 — host nixpkgs (for devShells, helper builds)
lib/toolchain/    Stage 1 — cross-compilation toolchain (crossPkgs)
lib/builder/      Stage 2 — per-package builder (mkArdosDerivation)
lib/sysroot/      Stage 3 — package merge (sysroot materialization)
lib/rom/          Stage 4 — ROM / squashfs assembly
```

External consumers (e.g. `flake.nix`) only call `init` from `lib/default.nix`. They should not import from the per-stage directories directly.

### Key APIs

- `ap2.init` — Initializes a build context for a target platform. Accepts `targetPlatform`, `buildSystem`, `externalMappings`, `toolchainConfig`, and `glibcPlugins`.
- `mkArdosDerivation` — Builds a package with Ardos metadata (runtime layout, symlink mappings).
- `mkRuntimeTree` — Generates a derivation containing a projection of the package's runtime filesystem.
- `wrapDerivation` — Wraps an existing derivation with Ardos runtime mappings.
- `callPackage` — Like `nixpkgs.callPackage` but with access to Ardos-specific helpers.
- `sysroot` — Constructs the final sysroot from package runtime trees.
- `rom` — Assembles the sysroot into a `.squashfs` ROM image.

### Builder hooks

The builder subsystem (`lib/builder/hooks/`) implements linker and shebang translation:

- `ld-wrapper.sh` — Stable stub (avoids unnecessary rebuilds).
- `ld-wrapper-impl.sh` — Mutable implementation of the linker wrapper.
- `ardos_ld_translate.rs` — Host-side Rust script that translates `-rpath` flags to Ardos runtime paths.

Setup hooks (`lib/builder/setup/`):

- `ardos-setup.sh` — Entry point for the setup hook.
- `early-init.rs`, `populate-map.rs`, `generate-layout.rs`, `translate-shebangs.rs` — Helper tools.

### Plugins

`lib/plugins/` contains optional plugins such as `nss-files.nix` for glibc NSS support.

## Development workflow

We use `just` as the task runner. Task configuration is split into files and subcommands by category to keep everything organized and make commands easy to remember:
```
[tiano@tiago-hp ardos-packer2]$ just
Available recipes:
    default              # Show all available recipes including submodules
    env target="default" # Enter development shell (default: toolset, or pass 'stdenv' for cross-compilers)
    start-ai             # Starts local ollama server and ollama client in a preset zellij layout
    build:
        check type name arch="x86_64" target=arch # Runs a nix check exported from the flake outputs by name [alias: test]
        pkg name arch="x86_64" target=arch        # Build an package exported from the flake outputs by name

    fmt:
        md       # [alias: markdown]
        nix      # Format all Nix files in the repository using alejandra
        rs       # [alias: rust]
        sh       # [aliases: script, shell]
```

The check `type` can be `e2e`, `integration`, or `unit`.
Test runner documentation in `tests/default.nix`:
```nix
  ##########################################################################
  ## Unit runner
  ##
  ## Unit tests are scripts that validate the outputs come out right and are
  ## ran in the context of the build system.
  ##########################################################################
[....]
  ################################################################################
  ## Integration runner
  ## --------------------
  ## 
  ## Sometimes running scripts in the build system context is not enough to
  ## validate something is working correctly and entering the OS environment
  ## becomes necessary.
  ## 
  ## Integration tests become in handy because the test runner chroots
  ## inside a sysroot with some packages you include and allows you to run
  ## a command and assert its outcome.
  ##
  ## Since integration tests assume binaries are runnable from the build
  ## system's cpu architecture, they are not runnable if the cpu of the system
  ## running them doesn't match the target cpu the packages were compiled to.
  ## 
  ##   NOTE: This chroot is rootless similar to podman and is implemented
  ##   using `proot`.
  ## 
  ################################################################################
[....]
  ################################################################################
  ## End-to-end runner
  ## -----------------
  ##
  ## E2E tests build complete ROM images from declarative configurations.
  ## Each test exports a spec with optional packages, glibcPlugins,
  ## toolchainConfig, and an optional check derivation.
  ##
  ## E2E tests are available as:
  ##   nix flake check  — runs the optional check derivation
  ##   nix build .#e2e-<name>-<target> — builds the ROM image
  ##
  ################################################################################
[....]
```
