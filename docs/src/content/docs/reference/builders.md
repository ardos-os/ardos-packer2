---
title: Builders reference
description: Reference for the package builders, runtimeLayout, and the kernel, initrd, limine, rom, and vm builders.
---

The builders turn source code or existing derivations into Ardos packages and system artifacts. This page documents their arguments and outputs. Start with the [instance reference](/ardos-packer2/reference/instance/) for how the builders are reached through `ap2.init`.

## runtimeLayout

Every package builder takes a `runtimeLayout` argument: a list of `{ source, target }` entries.

`source` is relative to the package's `$out`. `target` is an absolute path in the Ardos filesystem.

| Form                                                   | Meaning                                                                                             |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| `{ source = "bin/hello"; target = "/hello/hello"; }`   | File mapping. The single file is copied to the target                                               |
| `{ source = "lib/"; target = "/hellolibrary/"; }`      | Folder mapping. Every file under the source folder is copied under the target, preserving structure |
| `{ source = "lib/pkgconfig/"; target = "/dev/null"; }` | Exclude. The source is not copied anywhere                                                          |
| `{ source = "./"; target = "/kernel/modules/"; }`      | Maps the whole `$out` tree                                                                          |

Rules:

- Folder mappings are expanded by longest-prefix matching when the linker translates paths, and recursively at sysroot assembly time.
- For overlapping targets, the last declared entry wins.
- `source` must be relative, `target` must be absolute.
- The entries are written to `$out/nix-support/ardos-layout`. This file is the single source of truth for the linker wrapper, downstream packages, and the sysroot.

## mkArdosDerivation

Builds a package with `crossPkgs.stdenv.mkDerivation` and records its runtime layout.

| Argument                     | Type   | Default  | Description                                                                       |
| ---------------------------- | ------ | -------- | --------------------------------------------------------------------------------- |
| `pname`                      | string | required | Package name                                                                      |
| `version`                    | string | required | Package version                                                                   |
| `runtimeLayout`              | list   | `[]`     | Runtime layout entries                                                            |
| any `mkDerivation` attribute | varies | `{}`     | Forwarded unchanged, including `src`, `buildInputs`, `buildPhase`, `installPhase` |

It sets `dontPatchELF = true`, `dontShrinkRpath = true`, and `NIX_DEBUG = 1`; injects the linker translation hook and the runtime map; and appends `postInstall` writing `$out/nix-support/ardos-layout`. It attaches `passthru.ardos.runtimeLayout` for downstream tooling.

Example:

```nix
{ mkArdosDerivation }:

mkArdosDerivation {
  pname = "hellolibrary";
  version = "0.1.0";
  src = ./src;

  runtimeLayout = [
    { source = "lib/"; target = "/hellolibrary/"; }
    { source = "include/"; target = "/hellolibrary/include/"; }
  ];

  buildPhase = ''
    runHook preBuild
    $CC -shared -fPIC -o libhellolibrary.so hellolibrary.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include
    cp libhellolibrary.so $out/lib/
    cp hellolibrary.h $out/include/
    runHook postInstall
  '';
}
```

## mkArdosDerivationClang

Same argument shape and behavior as `mkArdosDerivation`, but builds with `crossPkgs.clangStdenv`. Use it when a package needs clang as the cross compiler, for example systemd's BPF compilation that invokes `clang -target bpf` directly.

## wrapDerivation

Takes an existing derivation that has no Ardos metadata and attaches a layout to it.

| Argument        | Type       | Default  | Description                                  |
| --------------- | ---------- | -------- | -------------------------------------------- |
| `drv`           | derivation | required | The derivation to wrap                       |
| `runtimeLayout` | list       | `[]`     | Layout entries (second argument, an attrset) |

It rebuilds the derivation with the same build attributes as `mkArdosDerivation` and records `passthru.ardos`. Use it for nixpkgs derivations that belong in the ROM but were not written for Ardos.

```nix
ap2.wrapDerivation ap2.crossPkgs.pcre2 {
  runtimeLayout = [
    { source = "lib/"; target = "/ardos/inputs/foreign/"; }
    { source = "lib/pkgconfig/"; target = "/dev/null"; }
  ];
};
```

## buildArdosRustPackage

Builds a Rust crate with Cargo and wraps the result.

| Argument                           | Type   | Default | Description                                                                  |
| ---------------------------------- | ------ | ------- | ---------------------------------------------------------------------------- |
| `runtimeLayout`                    | list   | `[]`    | Layout entries                                                               |
| any `crane.buildPackage` attribute | varies | `{}`    | Forwarded, including `src`, `cargoLock`, `cargoExtraArgs`, `cargoBuildFlags` |

It is a wrapper around `crane.buildPackage` followed by `wrapDerivation`. It sets `strictDeps = true` and `doCheck = false`; cross-compiled binaries cannot run on the build host. Requires `crane` to have been passed to `ap2.init`.

```nix
ap2.buildArdosRustPackage {
  src = ../../modules/my-service;
  cargoLock = ../../modules/my-service/Cargo.lock;
  runtimeLayout = [
    { source = "bin/my-service"; target = "/ardos/init/my-service"; }
  ];
}
```

## kernel

Cross-compiles a Linux kernel for the target.

| Argument     | Type               | Default  | Description                                                                             |
| ------------ | ------------------ | -------- | --------------------------------------------------------------------------------------- |
| `src`        | derivation or path | required | Kernel sources. The ardos repository builds its own linux fork                          |
| `version`    | string             | required | Kernel version string                                                                   |
| `configFile` | file               | required | A file of `CONFIG_KEY=value` lines applied over the arch defconfig, then `olddefconfig` |
| `extraMeta`  | attrset            | `{}`     | Merged into the derivation's `meta`                                                     |

Outputs:

- `out`, the kernel image, `bzImage` for `x86_64` or `Image` for `aarch64`.
- `headers`, the kernel build tree for external modules (`.config`, `Makefile`, `Module.symvers`, `System.map`, `vmlinux`, `scripts`, `include`, and Kconfig files).
- `uapi`, sanitized userspace headers from `make headers_install`.

Example:

```nix
ap2.kernel {
  version = "7.2-rc4-ardos";
  src = fetchFromGitHub { owner = "ardos-os"; repo = "linux"; ... };
  configFile = writeText ".config" (builtins.readFile ./kernel.config);
};
```

## initrd

Packs a directory into a compressed initramfs. The exported value is a function, so `initrd` is called positionally for the plain packer and `initrd.fromRustBinary` for the crate builder.

`initrd { src, name, compression } : out/initrd.img`

| Argument      | Type               | Default          | Description            |
| ------------- | ------------------ | ---------------- | ---------------------- |
| `src`         | path or derivation | required         | Directory to pack      |
| `name`        | string             | `"ardos-initrd"` | Derivation name        |
| `compression` | string             | gzip             | Compression executable |

`initrd.fromRustBinary src : out/initrd.img`

Cross-compiles a Cargo crate to a static musl binary for the target CPU and places it at `/init` inside a compressed cpio archive. Requires `crane`. The crate source is usually the whole crate listing, including its `Cargo.lock`.

## limine

Builds the Limine bootloader EFI binary for the instance's target. The result is `BOOTX64.EFI` on `x86_64` and `BOOTAA64.EFI` on `aarch64`.

## vm.ovmf and vm.launch

`vm.ovmf` is the OVMF firmware pair; it symlinks `OVMF_CODE.fd` and `OVMF_VARS.fd` from nixpkgs' OVMF.

`vm.launch` produces the QEMU launch script `bin/ardos-vm-run`. Its arguments and the run-time environment variables are documented in [Run the image in a virtual machine](/ardos-packer2/how-to/run-vm/).

## Related references

- [Instance reference](/ardos-packer2/reference/instance/) for `ap2.init` and where these builders come from.
- [Add a package to an Ardos image](/ardos-packer2/how-to/add-package/) for the workflow around the package builders.
