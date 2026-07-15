# Ardos Packer 2

This is a rewrite of [ardos-packer](https://github.com/ardos-os/ardos-packer) in the Nix language, prioritizing reproducibility,
isolated package builds, and better support for cross-compiling.

> WARNING: This is still experimental and unfinished so don't judge too soon.

## How is this even possible?

It might seem impossible since Nix is highly tied to the Nix store and NixOS runtime models. However, Nix is the perfect tool for building reproducible artifacts in a declarative manner. It gives you a full-blown functional programming language made specifically for package management, remote caching, reproducible builds, build sandboxing (cutting off internet and other impurities), explicit dependencies, and isolated builds. All one needs to build an Ardos OS image is Nix.

We can use the host's `nixpkgs` to build a cross-compiling toolchain targeting Ardos OS with all the libraries in the right places as it is implemented in [lib/toolchain/default.nix](lib/toolchain/default.nix).

The Ardos OS `stdenv` is built on top of the Nixpkgs `stdenv` frameworks; however, the toolchain is patched and overlayed to ensure everything is building correct Ardos OS binaries and libraries. In addition, [nixpkgs itself is patched](lib/host/patches/nixpkgs.patch) to make the generic builder recognize Ardos OS as a valid target.

This answers the building story, but how do we go from `/nix/store/gibberish` to clean Ardos OS paths inside the squashfs?

______________________________________________________________________

## Technical Architecture

The transition from the Nix store model to the final Ardos FHS runtime model relies on three key mechanisms: **Runtime Layout Mapping**, **Linker RUNPATH Translation**, and **Shebang Rewriting**.

![diagram of the process](./docs/process-whiteboard.svg)


### 1. Runtime Layout Mapping (`mkArdosDerivation`)

Nix store paths are treated strictly as a build-time implementation detail. Runtime locations are described declaratively by each Ardos package using `mkArdosDerivation`.

Each package defines a `runtimeLayout` list mapping Nix store outputs to target absolute paths inside Ardos:

```nix
{ mkArdosDerivation }:
mkArdosDerivation {
  pname = "hellolibrary";
  version = "0.1.0";
  runtimeLayout = [
    { source = "lib/"; target = "/hellolibrary/"; }
    { source = "include/"; target = "/hellolibrary/include/"; }
  ];
}
```

Sources ending with `/` are **folder mappings** — all files inside the directory are automatically mapped, preserving subdirectory structure. The ld wrapper expands folder mappings on-the-fly via longest-prefix matching at link time.

The layout entries are written directly to `$out/nix-support/ardos-layout` without an intermediate symlink tree. This file is the single source of truth consumed by the linker wrapper, downstream packages, and the ROM generator.

When multiple packages map to the same target path, the **last entry wins** (later entries in the layout override earlier ones).

------

#### Adding external non-ardos derivations


Some target packages come directly from nixpkgs and cannot reasonably be
changed just to add Ardos metadata.

![unknown mapping diagram](./docs/unknown-mapping.svg)

`ap2.init` therefore accepts an
`externalMappings` option: a list (or a function from `crossPkgs` to a list) of
`{ drv, runtimeLayout }` entries. Each entry's `runtimeLayout` is written as
`ardos-layout` lines. At link time, the setup hook only applies an external
mapping if that `drv` is actually present in the discovered dependency closure,
so generic mappings for packages such as libc or compiler runtime libraries do
not leak into unrelated outputs.

```nix
ap2.init {
  inherit targetPlatform buildSystem nixpkgs;
  externalMappings = pkgs: [
    {
      drv = pkgs.glibc;
      runtimeLayout = [{ source = "lib/"; target = "/ardos/lib/"; }];
    }
  ];
}
```

### 2. Linker RUNPATH Translation (`ld-wrapper-hook`)

Because compiled binaries must find their shared library dependencies (like `libc.so` or `libskia.so`) at runtime in their final Ardos paths (e.g. `/ardos/lib` or `/ardos/graphics`), we cannot let them retain Nix store references in their `RUNPATH` headers. At the same time, we must avoid running fragile tools like `patchelf` on final images.

To solve this, we overlay the cross-linker wrapper with a custom hook: [lib/builder/hooks/ld-wrapper.sh](/lib/builder/hooks/ld-wrapper.sh) (injector) + [lib/builder/hooks/ld-wrapper-impl.sh](lib/builder/hooks/ld-wrapper-impl.sh) (bash wrapper) + [lib/builder/hooks/ardos_ld_translate.rs](lib/builder/hooks/ardos_ld_translate.rs) (rust script with the actual argument translation).

- During package compilation, an Ardos setup hook aggregates all `runtimeLayout` maps of the package and its dependencies into a single translation file (`$ARDOS_RUNTIME_MAP`). Folder mappings are preserved as-is — the ld translator expands them on-the-fly via longest-prefix matching.
- The linker wrapper intercepts all `-rpath` flags and translates them:
  - If a path matches a Nix store location in the translation map, it is replaced with the target Ardos path (e.g., `/nix/store/.../lib` ➔ `/ardos/lib`).
  - If an RPATH points to an unmapped Nix store path (like bootstrap paths), it is **stripped** to prevent store leakage.
- The resulting ELF binaries are produced directly pointing to their runtime paths.

The injector + implementation setup is needed so changes to the implementation do not trigger unnecessary rebuilds to other derivations not using `mkArdosDerivation`. `stdenv.mkDerivation` sees a stub, and `mkArdosDerivation` injects the implementation path into the stub through an environment variable.

### 3. Shebang Rewriting (`ardosTranslateShebangs`)

Executable shell scripts in Nix typically have shebangs pointing to `/nix/store/...-bash/bin/bash`.

To run natively on Ardos, these shebangs must point to target packages that have runtime mappings (e.g., `/ardos/bin/bash`).
Our setup hook intercepts and parses all shebangs in the `postFixup` phase of target packages. Using the aggregated `$ARDOS_RUNTIME_MAP`, it matches the Nix store hash of the interpreter against declared layouts and rewrites the shebang path to point to the Ardos location (e.g., `#!/nix/store/.../bin/bash` → `#!/ardos/bin/bash`).


### Boot and Kernel

Ardos packer also brings some utilities to configure the kernel, initrd and a bootloader called [limine](https://github.com/limine-bootloader/limine).
```nix
# Linux kernel via buildLinux (cross-compiled for ardos target)
ardosPacker.kernel {
  src = fetchurl { ... };
  version = "6.14";
  structuredExtraConfig = { ... };
}

# Initramfs from a directory
ardosPacker.initrd { src = ./initramfs; }

# Initramfs from a Rust crate — builds a fully static musl binary
# and places it at /init inside a cpio.gz archive.
# Requires `crane` to be passed to `ap2.init`.
ardosPacker.initrd.fromRustBinary ./init-rust-crate/

# Limine UEFI bootloader binary
ardosPacker.limine
```

### Why Limine?

Limine is famous amongst hobby OS developers for its simplicity and developer experience with it's own special protocol with the same name (formerly called stivale). But limine also supports booting linux, the ability for it to work without systemd and without bringing all of bloat of grub is what caught my attention to use it in ardos. Limine is self contained in one UEFI binary and it only requires a limine.conf which is a super easy human readable format and configurations don't go past 5 lines usually.

It's the perfect bootloader for the case you don't want the user to even care what a bootloader is, it just goes past it without seeing anything, it is super fast and
slick.

## VM / QEMU

Ardos-packer2 just like the original ardos-packer, provides utilities for spinning up a virtual machine for development.

### VM-specific

```nix
# OVMF firmware (Code + Vars)
ardosPacker.vm.ovmf

# QEMU launch script — prepares disks, copies boot assets, launches VM
# The script is at bin/ardos-vm-run inside the package after compiled
#
# Suggestion: You can make your own wrapper script or a job in your Justfile
# that builds this derivation and runs the script inside automatically.
ardosPacker.vm.launch {
  kernel = ardosPacker.buildPkgs.linuxPackages_latest.kernel;
  initrd = ardosPacker.initrd { src = ...; };
  rom    = ardosPacker.rom { sysroot = ...; };
  # optional:
  kernel-params = "init=/bin/sh";        # extra kernel cmdline args
  memory = "4G";
  smp = "8";
  system-disk-size = "4G";
  user-disk-size = "20G";
}
```

The `vm.launch` wrapper fills in sensible defaults for `limine`, `ovmf-code`, and `ovmf-vars` so you only need to provide `kernel`, `initrd`, and `rom`.

## Development Workflows

We use `just` as our task runner. The task configuration is split into discoverable submodules:
```
[tiago@tiago-hp ardos-packer2]$ just
Available recipes:
    default              # Show all available recipes including submodules
    env target="default" # Enter development shell (default: toolset, or pass 'stdenv' for cross-compilers)
    build:
        check type name arch="x86_64" target=arch # Runs a nix check exported from the flake outputs by name [alias: test]
        pkg name arch="x86_64" target=arch        # Build an package exported from the flake outputs by name

    fmt:
        md       # [alias: markdown]
        nix      # Format all Nix files in the repository using alejandra
        rs       # [alias: rust]
        sh       # [aliases: script, shell]
```
## Reliance on nixpkgs

You might say because we currently rely on nixpkgs recipes that Ardos OS is not fully independent from Nix OS, you're not
that far off. Even thought the structure of Ardos OS and Nix OS look nothing alike, it still feels wrong depending
on the same code Nix OS is built on.

We do have a plan to migrate over to our own derivations instead and completely break free from nixpkgs to manage the toolchain
and build packages targetting Ardos OS, but that's not just viable right now during this experimental phase.

