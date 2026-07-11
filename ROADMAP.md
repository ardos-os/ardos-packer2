# Ardos Packer 2 — Implementation Roadmap

> **Status**: Research & Experimentation Phase Complete\
> **Goal**: A reproducible, Nix-driven ROM generator for Ardos OS that produces a clean, FHS-like filesystem image with no `/nix/store` references at runtime.

______________________________________________________________________

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         BUILD TIME (Nix Store)                      │
│                                                                     │
│  mkArdosDerivation                                                  │
│  ├── Compiles to $out (in /nix/store)                               │
│  ├── Generates nix-support/ardos-layout (source → target map)       │
│  └── passthru.ardos.runtimeTree (symlink tree derivation)           │
│                                                                     │
│  ardosStdenv                                                        │
│  ├── crossPkgs (patchedNixpkgs + ardosOverlay)                      │
│  ├── Linker wrapper with RPATH translation hook                     │
│  └── Setup hook aggregating ARDOS_RUNTIME_MAP from buildInputs      │
│                                                                     │
└─────────────────────┬───────────────────────────────────────────────┘
                      │  ardosRom (transitive closure)
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    RUNTIME (Ardos ROM / squashfs)                   │
│                                                                     │
│  /ardos/bin/bash                                                    │
│  /ardos/lib/libc.so.6                                               │
│  /ardos/lib/libncurses.so                                           │
│  /ardos/services/hello/bin/hello                                    │
│  ...                                                                │
└─────────────────────────────────────────────────────────────────────┘
```

______________________________________________________________________

## 📦 Milestones

### Milestone 1 — Ardos Stdenv Foundation ✅

> Cross-compilation base that produces target binaries with correct RPATH from day one.

| Task | Status | Notes |
|---|---|---|
| Patch Nixpkgs for `ardos` vendor (`nixpkgs.patch`) | ✅ Done | Adds `ardos` to `parse.nix` vendors enum |
| `crossPkgs` setup with `ardosOverlay` | ✅ Done | Builds `bash` and toolchain for Ardos |
| Patch `glibc` for `x86_64-ardos-linux-gnu` | ✅ Done | Via `glibc-add-ardos.patch` |
| Wrap `stdenv.mkDerivation` to patch `config.sub` in-place | ✅ Done | For target packages |
| Refactor `lib/stdenv/default.nix` with clean `let` blocks | ✅ Done | `ardosOverlay`, `wrapStdenvForArdos`, `patchAutotoolsConfig` |

______________________________________________________________________

### Milestone 2 — Runtime Layout & Linker Integration ✅

> Teach the linker to embed correct Ardos runtime paths, not Nix store paths.

#### 2.1 — `ld-wrapper-hook`

| Task | Status | Notes |
|---|---|---|
| Write `lib/stdenv/hooks/ld-wrapper-hook` | ✅ Done | Port from `experiments/ld-wrapper-hook` |
| Write `lib/stdenv/setup-hooks/ardos-map.sh` | ✅ Done | Aggregates `nix-support/ardos-layout` from `buildInputs` into `$ARDOS_RUNTIME_MAP` |
| Inject `ld-wrapper-hook` into cross-compiling `bintools` via overlay | ✅ Done | `bintools.overrideAttrs` in `ardosOverlay` |
| Inject `ardos-map.sh` as a setup hook into `ardosStdenv` | ✅ Done | Via `stdenv.setupHook` or `nativeBuildInputs` |

#### 2.2 — `mkArdosDerivation` helper

| Task | Status | Notes |
|---|---|---|
| Write `lib/mkArdosDerivation.nix` | ✅ Done | Wraps `crossPkgs.stdenv.mkDerivation` |
| Accept `runtimeLayoutScript` (Bash snippet) | ✅ Done | Developer-defined symlink script |
| Generate `nix-support/ardos-layout` from `runtimeLayoutScript` output | ✅ Done | Run the script into a temp dir, record the symlinks as `source -> target` lines |
| Provide default layout helpers (`defaultArdosLayout`) | ✅ Done | Automatically maps `bin/*`, `lib/*.so*`, etc. |
| Expose `passthru.ardos.runtimeLayout` attribute | ✅ Done | Nix-side metadata for introspection |

#### 2.3 — `mkRuntimeTree` helper

| Task | Status | Notes |
|---|---|---|
| Write `lib/mkRuntimeTree.nix` | ✅ Done | Takes a built Ardos derivation, materializes a symlink tree |
| Build output contains symlinks pointing into `/nix/store` | ✅ Done | e.g. `$out/ardos/lib/libfoo.so -> /nix/store/.../libfoo.so` |
| Expose as `passthru.ardos.runtimeTree` | ✅ Done | Used by ROM generator and linker wrapper |
| Verify no target path hardcoding | ✅ Done | Paths sourced entirely from `runtimeLayoutScript` output |

______________________________________________________________________

### Milestone 3 — ROM Generator ✅

> Compute the transitive closure of all required packages and assemble a clean squashfs image.

| Task | Status | Notes |
|---|---|---|
| Refactor `lib/ardosRom.nix` | ✅ Done | Currently a stub |
| Use `closureInfo` to compute transitive closure | ✅ Done | "Produces metadata about the closure of the given root paths." |
| Walk the closure and collect all `nix-support/ardos-layout` files | ✅ Done | Skip packages without a layout (build-only deps) |
| Stage real files into target directory structure | ✅ Done | `cp -a --no-preserve=ownership $(readlink -f $symlink) $dest` |
| Produce a `squashfs` image from the staged tree | ✅ Done | Via `mksquashfs` in a derivation |
| Expose as `packages.${system}.ardos-rom-${targetTriple}` | ✅ Done | Already wired in `flake.nix` |

______________________________________________________________________

### Milestone 4 — Rust Toolchain Integration 🔲

> Pre-compiled Rust standard library for Ardos as a Nix derivation.

| Task | Status | Notes |
|---|---|---|
| Compile `rust-std-ardos` derivation from `rustPlatform.rust.rustcSrc` | 🔲 |  |
| Caching dependency crate builds across packages/components written in rust | 🔲 |  |
| Building rust projects with `rustPlatform` from nixpkgs should just work | 🔲 |  |
| Similarly to the C compiler, rustc also needs to be a cross compiler to ardos and should compile effortlessly with the same experience as compiling to the host machine itself, no noisy derivations | 🔲 | |
| Verify `cargo build --target x86_64-ardos-linux-gnu.json` works without `-Z build-std` | 🔲 | |
| Add `rustcTargetSpec` JSON to each supported CPU in `supportedCpus.nix` | ✅ Done | Already declared |

______________________________________________________________________

### Milestone 5 — Multi-Architecture Support ✅

> Validate that the same infrastructure works for `aarch64-ardos-linux-gnu` and `riscv64-ardos-linux-gnu` without code duplication.

| Task | Status | Notes |
|---|---|---|
| Verify `aarch64-ardos-linux-gnu` cross-compilation builds | ✅ Done | Via `packages.x86_64-linux.cross-aarch64-ardos-linux-gnu` |
| Verify `riscv64-ardos-linux-gnu` cross-compilation builds | ✅ Done | Via `packages.x86_64-linux.cross-riscv64-ardos-linux-gnu` |
| Verify `runtimeLayoutScript` is arch-agnostic | ✅ Done | Scripts should not contain architecture-specific paths |
| Cross-compile `ardos-rom` for each supported architecture | ✅ Done | |

______________________________________________________________________

## 🔑 Key Design Principles (Non-Negotiable)

1. **No `/nix/store` at runtime**: All RPATH entries embedded in target binaries must point to Ardos filesystem paths only. The `ld-wrapper-hook` enforces this at link time.
1. **No `patchelf`**: Runtime paths must be correct from the first link. Post-build patching is forbidden.
1. **No global path assumptions**: The linker wrapper has zero hardcoded paths. All path knowledge lives in the packages themselves via `nix-support/ardos-layout`.
1. **Single source of truth**: Each package declares its own runtime layout. Consumers never assume paths like `/ardos/lib`.
1. **Transitive closure, not manual lists**: The ROM generator automatically includes all required files. Developers never manually list indirect dependencies.
1. **Incremental rebuilds**: Changing one package only rebuilds that package down, never up. The rest is served from cache. if you edit a music player program and suddently it starts rebuilding from toolchain stage 1, you probably did something very wrong.
