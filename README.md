# Ardos Packer 2

This is a rewrite of [ardos-packer](https://github.com/ardos-os/ardos-packer) in the Nix language, prioritizing reproducibility, 
isolated package builds, and better support for cross-compiling.

> WARNING: This is still experimental and unfinished so don't judge too soon.

## How is this even possible?

It might seem impossible since Nix is highly tied to the Nix store and NixOS runtime models. However, Nix is the perfect tool for building reproducible artifacts in a declarative manner. It gives you a full-blown functional programming language made specifically for package management, remote caching, reproducible builds, build sandboxing (cutting off internet and other impurities), explicit dependencies, and isolated builds. All one needs to build an Ardos OS image is Nix.

We can use the host's `nixpkgs` to build a cross-compiling toolchain targeting Ardos OS with all the libraries in the right places as it is implemented in [lib/stdenv/default.nix](file:///lib/stdenv/default.nix).

The Ardos OS `stdenv` is built on top of the Nixpkgs `stdenv` frameworks; however, the toolchain is patched and overlayed to ensure everything is building correct Ardos OS binaries and libraries. In addition, [nixpkgs itself is patched](file:///lib/stdenv/patches/nixpkgs.patch) to make the generic builder recognize Ardos OS as a valid target.

This answers the building story, but how do we go from `/nix/store/gibberish` to clean Ardos OS paths inside the squashfs?

---

## Technical Architecture

The transition from the Nix store model to the final Ardos FHS runtime model relies on three key mechanisms: **Symbolic Link Mapping**, **Linker RUNPATH Translation**, and **Shebang Rewriting**.

### 1. Symbolic Link Mapping (`mkArdosDerivation`)

Nix store paths are treated strictly as a build-time implementation detail. Runtime locations are described declaratively by each Ardos package using `mkArdosDerivation`. 

Each package defines a `runtimeLayout` list mapping Nix store outputs to target absolute paths inside Ardos:
```nix
mkArdosDerivation {
  pname = "hellolibrary";
  version = "0.1.0";
  runtimeLayout = [
    { source = "lib/libhellolibrary.so"; target = "/hellolibrary/libhellolibrary.so"; }
  ];
}
```

During the build, this mapping is stored as metadata in the package's output directory (`$out/nix-support/ardos-layout`). The `mkRuntimeTree` helper consumes this metadata to generate a separate derivation containing a materialized tree of symbolic links. 

When the ROM generator constructs the final squashfs, it follows these symlinks to assemble the files at their final target paths, checking for collisions between packages.

Some target packages come directly from nixpkgs and cannot reasonably be
changed just to add Ardos metadata. `ardosPackerLib.init` therefore accepts an
`externalMappings` option: a list (or a function from `crossPkgs` to a list) of
`{ drv, runtimeLayoutScript }` entries. Each script has the same `$out` and
`$stage` interface as `mkArdosDerivation`, but it is evaluated outside the
derivation it describes. At link time, the setup hook only applies an external
mapping if that `drv` is actually present in the discovered dependency closure,
so generic mappings for packages such as libc or compiler runtime libraries do
not leak into unrelated outputs.

```nix
ardosPackerLib.init {
  inherit targetPlatform buildSystem;
  externalMappings = pkgs: [
    {
      drv = pkgs.glibc;
      runtimeLayoutScript = ''
        for so in "$out"/lib/*.so*; do
          [ -e "$so" ] || continue
          mkdir -p "$stage/ardos/lib"
          ln -sfn "$so" "$stage/ardos/lib/$(basename "$so")"
        done
      '';
    }
  ];
}
```

### 2. Linker RUNPATH Translation (`ld-wrapper-hook`)

Because compiled binaries must find their shared library dependencies (like `libc.so` or `libhellolibrary.so`) at runtime in their final Ardos paths (e.g. `/ardos/lib` or `/hellolibrary`), we cannot let them retain Nix store references in their `RUNPATH` headers. At the same time, we must avoid running fragile tools like `patchelf` on final images.

To solve this, we overlay the cross-linker wrapper with a custom hook: [lib/stdenv/hooks/ld-wrapper-hook](file:///lib/stdenv/hooks/ld-wrapper-hook) (injector) + [lib/stdenv/hooks/ld-wrapper-hook-impl](lib/stdenv/hooks/ld-wrapper-hook-impl) (bash wrapper) + [lib/stdenv/hooks/ardos-ld-translate.rs](lib/stdenv/hooks/ardos-ld-translate.rs) (rust script with the actual argument translation).
* During package compilation, an Ardos setup hook aggregates all `runtimeLayout` maps of the package and its dependencies into a single translation file (`$ARDOS_RUNTIME_MAP`).
* The linker wrapper intercepts all `-rpath` flags and translates them:
  * If a path matches a Nix store location in the translation map, it is replaced with the target Ardos path (e.g., `/nix/store/.../lib` ➔ `/ardos/lib`).
  * If an RPATH points to an unmapped Nix store path (like bootstrap paths), it is **stripped** to prevent store leakage.
* The resulting ELF binaries are produced directly pointing to their runtime paths.

The injector + implementation setup is needed so changes to the implementation do not trigger unnecessary rebuilds to other derivations not using `mkArdosDerivation`. `stdenv.mkDerivation` sees a stub, and `mkArdosDerivation` injects the implementation path into the stub through an environment variable.

### 3. Shebang Rewriting (`ardosTranslateShebangs`)

Executable shell scripts in Nix typically have shebangs pointing to `/nix/store/...-bash/bin/bash`. 

To run natively on Ardos, these shebangs must point to target packages that have runtime mappings (e.g., `/ardos/bin/bash`). 
Our setup hook intercepts and parses all shebangs in the `postFixup` phase of target packages. Using the aggregated `$ARDOS_RUNTIME_MAP`, it matches the Nix store hash of the interpreter against declared layouts and rewrites the shebang path to point to the Ardos location (e.g., `#!/nix/store/.../bin/bash` ➔ `#!/ardos/bin/bash`).

---

## Development Workflows

We use `just` as our task runner. The task configuration is split into discoverable submodules:

* **Build recipes** (`justfiles/build.just`):
  * `just build stdenv`: Builds the stdenv toolchain.
  * `just build toolchain <cc/binutils/glibc>`: Builds a specific component of the cross-compilation toolchain.
  * `just build pkg <name>`: Builds a specific Ardos package (e.g. `hello`, `hellolibrary`). Output symlinks are placed under the `build/` directory.
* **Cachix recipes** (`justfiles/cache.just`):
  * `just cache stdenv`: Builds the toolchain and pushes Ardos-specific paths to the Cachix binary cache.
* **Formatting** (`justfiles/fmt.just`):
  * `just fmt`: Formats all Nix files in the repository using `alejandra`.


## AI Usage

We do use a bit of AI, especially because nixpkgs is really complex and we do often run into issues because of something that happens behind the scenes we don't usually notice. Don't see the use of AI here as slop, it is being used to deal with puzzling issues
we just want to quickly get over with and deal with technical debt.

The repository features a local LLM setup you can call with

```
nix run .#start-ai
```

If you have a beefy machine, there's no need to beg billy G for tokens: you can download some local models and use them with
your favorite Agent CLI like codex, claude code and others, but expect to need at least 64GB of RAM and a good dedicated GPU for a
good experience.

If you have a weak machine with no option to host a minimally usable model for coding,
you'll have to use ollama cloud models, which are not bad at all and the plan is not that expensive. Codex works best with `minimax-m3:cloud` model if you use that, the other models tend to think too much or not understand how to work with codex tools well.
