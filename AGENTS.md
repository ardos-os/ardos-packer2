# Repository Guidelines

## Project Structure & Module Organization

This repository is a Nix flake for building Ardos OS artifacts and cross-compiling packages.

- `lib/` contains the reusable packer implementation: builders, toolchains, VM/boot support, sysroot handling, and runtime-layout translation.
- `packages/` defines example and test packages such as `hello`, `hellolibrary`, and `vm-initramfs`.
- `tests/` contains Nix checks grouped as `unit`, `integration`, and `e2e`, plus fixtures and Rust probes.
- `devShells/` defines development environments; `justfiles/` contains build and formatting recipes; `docs/` contains architecture diagrams.

Keep new functionality in the narrowest applicable `lib/` module, and add or update a corresponding check under `tests/`.

## Build, Test, and Development Commands

Use Nix with flakes enabled and run commands through the repository’s `just` recipes:

```sh
just                         # list recipes
just env                     # enter the default development shell
just build pkg hello         # build a flake test package
just test unit hello-binary  # build a named check
nix flake check              # run the complete flake check set
just fmt nix                 # format Nix files with alejandra
just fmt rs                  # format Rust files with rustfmt
just fmt sh && just fmt md   # format scripts and Markdown
```

Package and check recipes accept optional architecture and target arguments; see `justfiles/build.just` for the exact output names.

## Coding Style & Naming Conventions

Format Nix with `alejandra`, Rust with `rustfmt`, shell scripts with `shfmt`, and Markdown and MDX with `remark` (via the docs bun project, `just fmt md`). Preserve existing two-space Nix indentation and repository naming patterns: lowercase kebab-free Nix attributes, descriptive module filenames, and Rust `snake_case` identifiers. Prefer small, composable Nix functions and keep target/runtime mapping explicit.

## Testing Guidelines

Checks are declarative Nix builds rather than a host-language test runner. Name checks by scope and subject, for example `unit hello-binary`, `integration hello`, or `e2e combined`. Run the narrowest affected check first, then `nix flake check`; cross-compiled binaries may not run on the build host, so validate through the provided target checks.

## Commit & Pull Request Guidelines

Use concise imperative subjects, optionally prefixed with `fix:`, `build:`, or an area such as `vm:`. Keep commits focused. Pull requests should explain the behavior change, identify affected packages/checks, include test commands and results, and attach diagrams or screenshots when changing documentation or VM behavior. Update relevant README or module documentation alongside user-visible changes.
