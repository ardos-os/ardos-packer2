# Ardos Packer 2 — Implementation Roadmap

> **Status**: Research & Experimentation Phase Complete  
> **Goal**: A reproducible, Nix-driven ROM generator for Ardos OS that produces a clean, FHS-like filesystem image with no `/nix/store` references at runtime.

---

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

---

## 📦 Milestones

### Milestone 1 — Ardos Stdenv Foundation ✅ (In Progress)
> Cross-compilation base that produces target binaries with correct RPATH from day one.

| Task | Status | Notes |
|---|---|---|
| Patch Nixpkgs for `ardos` ABI (`nixpkgs.patch`) | ✅ Done | Adds `ardos` to `parse.nix`, `libgcc`, `gcc` |
| `crossPkgs` setup with `ardosOverlay` | ✅ Done | Builds `bash` and toolchain for Ardos |
| Patch `binutils-unwrapped` for `x86_64-linux-ardos` | ✅ Done | Via `binutils-add-ardos.patch` |
| Patch `glibc` for `x86_64-linux-ardos` | ✅ Done | Via `glibc-add-ardos.patch` |
| Patch LLVM for Ardos environment | ✅ Done | Via `llvm-add-ardos-environment.patch` |
| Wrap `stdenv.mkDerivation` to patch `config.sub` in-place | ✅ Done | For target packages |
| Refactor `lib/stdenv/default.nix` with clean `let` blocks | ✅ Done | `ardosOverlay`, `wrapStdenvForArdos`, `patchAutotoolsConfig` |

---

### Milestone 2 — Runtime Layout & Linker Integration 🔲
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

---

### Milestone 3 — ROM Generator 🔲
> Compute the transitive closure of all required packages and assemble a clean squashfs image.

| Task | Status | Notes |
|---|---|---|
| Refactor `lib/ardosRom.nix` | 🔲 | Currently a stub |
| Use `exportReferencesGraph` to compute transitive closure | 🔲 | Built-in Nix feature to get all store paths a derivation depends on |
| Walk the closure and collect all `nix-support/ardos-layout` files | 🔲 | Skip packages without a layout (build-only deps) |
| Stage real files into target directory structure | 🔲 | `cp --remove-destination $(readlink -f $symlink) $dest` |
| Produce a `squashfs` image from the staged tree | 🔲 | Via `mksquashfs` in a derivation |
| Expose as `packages.${system}.ardos-rom-${targetTriple}` | 🔲 | Already wired in `flake.nix` |

---

### Milestone 4 — Rust Toolchain Integration 🔲
> Pre-compiled Rust standard library for Ardos as a Nix derivation.

| Task | Status | Notes |
|---|---|---|
| Compile `rust-std-ardos` derivation from `rustPlatform.rust.rustcSrc` | 🔲 | See `rust_compiler_setup_plan.md` |
| Create unified sysroot via `symlinkJoin` | 🔲 | Host `rustc` + `rustStdArdos` |
| Wrap `rustc` with `--sysroot` flag via `makeWrapper` | 🔲 | Overlay `rustc` in `ardosOverlay` |
| Verify `cargo build --target x86_64-linux-ardos.json` works without `-Z build-std` | 🔲 | |
| Add `rustcTargetSpec` JSON to each supported CPU in `supportedCpus.nix` | ✅ Done | Already declared |

---

### Milestone 5 — Developer Experience 🔲
> Make it easy to work on individual Ardos packages without rebuilding the world.

| Task | Status | Notes |
|---|---|---|
| `devShells.${system}.default` in `flake.nix` | 🔲 | Cross-compiler, cargo, make in PATH |
| `nix develop` loads cross-compiling environment | 🔲 | `CC`, `CXX`, `LD` pointing to Ardos cross-compiler |
| `ARDOS_RUNTIME_MAP` auto-generated in dev shell | 🔲 | From declared packages |
| Document `mkArdosDerivation` API | 🔲 | How to declare `runtimeLayoutScript` |
| Add a proof-of-concept C package (`hello`) | 🔲 | Library + binary using the full pipeline |
| Add `nix build .#hello` and `nix build .#helloRuntimeTree` targets | 🔲 | Verify Milestone 2 end-to-end |

---

### Milestone 6 — Multi-Architecture Support 🔲
> Validate that the same infrastructure works for `aarch64-linux-ardos` and `riscv64-linux-ardos` without code duplication.

| Task | Status | Notes |
|---|---|---|
| Verify `aarch64-linux-ardos` cross-compilation builds | 🔲 | Via `packages.x86_64-linux.cross-aarch64-linux-ardos` |
| Verify `riscv64-linux-ardos` cross-compilation builds | 🔲 | Via `packages.x86_64-linux.cross-riscv64-linux-ardos` |
| Verify `runtimeLayoutScript` is arch-agnostic | 🔲 | Scripts should not contain architecture-specific paths |
| Cross-compile `ardos-rom` for each supported architecture | 🔲 | |

---

## 🔑 Key Design Principles (Non-Negotiable)

1. **No `/nix/store` at runtime**: All RPATH entries embedded in target binaries must point to Ardos filesystem paths only. The `ld-wrapper-hook` enforces this at link time.
2. **No `patchelf`**: Runtime paths must be correct from the first link. Post-build patching is forbidden.
3. **No global path assumptions**: The linker wrapper has zero hardcoded paths. All path knowledge lives in the packages themselves via `nix-support/ardos-layout`.
4. **Single source of truth**: Each package declares its own runtime layout. Consumers never assume paths like `/ardos/lib`.
5. **Transitive closure, not manual lists**: The ROM generator automatically includes all required files. Developers never manually list indirect dependencies.
6. **Incremental rebuilds**: Changing one package only rebuilds that package and its dependents. The rest is served from cache.

---

## 📁 Final File Layout (Target)

```
ardos-packer2/
├── flake.nix
├── lib/
│   ├── default.nix
│   ├── platforms.nix
│   ├── supportedCpus.nix
│   ├── ardosRom.nix            ← Milestone 3
│   ├── mkArdosDerivation.nix   ← Milestone 2.2
│   ├── mkRuntimeTree.nix       ← Milestone 2.3
│   ├── rustTargets/
│   │   ├── x86_64-linux-ardos.json
│   │   ├── aarch64-linux-ardos.json
│   │   └── riscv64gc-linux-ardos.json
│   └── stdenv/
│       ├── default.nix
│       ├── hooks/
│       │   └── ld-wrapper-hook     ← Milestone 2.1
│       └── setup-hooks/
│           └── ardos-map.sh        ← Milestone 2.1
│       └── patches/
│           ├── nixpkgs.patch
│           ├── binutils-add-ardos.patch
│           ├── glibc-add-ardos.patch
│           ├── llvm-add-ardos-environment.patch
│           └── gcc-add-ardos.patch
└── experiments/                ← To be cleaned up or archived
    ├── conclusions.md
    ├── ld-wrapper-hook
    ├── test_mapping.nix
    ├── test_wrapper_hook.sh
    ├── test_wrapper_run.sh
    └── test_full_compilation.nix
```
