# Repository Guidelines

## Project Structure & Module Organization

This repository is a Nix flake for building Ardos OS artifacts and cross-compiling packages.

- `lib/` contains the reusable packer implementation: builders, toolchains, VM/boot support, sysroot handling, and runtime-layout translation.
- `packages/` defines example and test packages such as `hello`, `hellolibrary`, and `vm-initramfs`.
- `tests/` contains Nix checks grouped as `unit`, `integration`, and `e2e`, plus fixtures and Rust probes.
- `devShells/` defines development environments; `justfiles/` contains build and formatting recipes; `docs/` contains architecture diagrams.

Keep new functionality in the narrowest applicable `lib/` module, and add or update a corresponding check under `tests/`.

## Documentation

The project documentation is a Starlight site in `docs/` (content under `docs/src/content/docs/`, sidebar and build config in `docs/astro.config.mjs`). It is deployed to GitHub Pages, and every page listed below lives under the `ardos-packer2` base path.

When you change user-visible behavior, update the matching page and its sidebar entry.

- Tutorials
  - [Build your first Ardos image](docs/src/content/docs/tutorials/first-build.mdx)
- How-to guides
  - [Add a package to an Ardos image](docs/src/content/docs/how-to/add-package.md)
  - [Use the Cachix binary cache](docs/src/content/docs/how-to/use-cachix.md)
  - [Assemble the system image](docs/src/content/docs/how-to/assemble-image.mdx)
  - [Run the image in a virtual machine](docs/src/content/docs/how-to/run-vm.mdx)
- Reference
  - [Instance](docs/src/content/docs/reference/instance.md) — `ap2.init` options
  - [Builders](docs/src/content/docs/reference/builders.md) — package builders and `runtimeLayout`
- Explanation
  - [About the build pipeline](docs/src/content/docs/explanation/build-pipeline.md) — why runtime paths are translated
- Contributing
  - [Repository commands](docs/src/content/docs/contributing/commands.mdx)
  - [Commit messages](docs/src/content/docs/contributing/commit-messages.mdx) — commit structure and style

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

Follow the [commit message guide](docs/src/content/docs/contributing/commit-messages.mdx). Keep the summary imperative and within 72 characters; an area tag may come first. Add a focused body that explains why the change was made. Keep commits atomic and focused on one logical change. Where possible, each commit should leave the repository in a valid state so it can be reverted without breaking the build or leaving incomplete code. Avoid "rebuild the world" commits that combine unrelated changes. Pull requests should explain the behavior change, identify affected packages and checks, include test commands and results, and attach diagrams or screenshots when changing documentation or VM behavior. Update relevant README or module documentation alongside user-visible changes.
