---
title: Instance reference
description: Reference for ap2.init and the build instance it returns.
---

`ap2.init` builds the cross toolchain for a target platform and returns the instance that carries every builder, package set, and system assembly function.

## Entry point

The library is imported as `ap2 = import ./lib`. It exposes `platforms` and `init`.

Consumers call `init` once per target platform. The ardos repository does this in its `flake.nix`:

```nix
ap2 = inputs.ap2.lib;

instance = ap2.init {
  buildSystem = "x86_64-linux";
  targetPlatform = ap2.platforms.x86_64;
  inherit (inputs) nixpkgs crane;
  toolchainConfig.glibc.runtimePrefix = "/ardos";
  externalMappings = import ./external-mappings.nix;
};
```

The result is the object every later step works with. It can be rebound: each call to `init` is independent of the others.

## Platforms

`ap2.platforms` contains one entry per supported CPU. Both entries produce the triple `<cpu>-ardos-linux-gnu`.

| Attribute | `config`                  | `ardosTriple`             | `linuxTriple`   | `libc`  | `abi` | `kernel` | `vendor` |
| --------- | ------------------------- | ------------------------- | --------------- | ------- | ----- | -------- | -------- |
| `x86_64`  | `x86_64-ardos-linux-gnu`  | `x86_64-ardos-linux-gnu`  | `x86_64-linux`  | `glibc` | `gnu` | `linux`  | `ardos`  |
| `aarch64` | `aarch64-ardos-linux-gnu` | `aarch64-ardos-linux-gnu` | `aarch64-linux` | `glibc` | `gnu` | `linux`  | `ardos`  |

Each entry also carries `llvmTarget` (`X86`, `AArch64`), `rust.rustcTargetSpec`, `isLinux = true`, and `isArdos = true`. The `enableDevShell` flag controls whether a dev shell is generated for that platform.

## init arguments

| Argument           | Type                                                                         | Default  | Description                                                                                           |
| ------------------ | ---------------------------------------------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------- |
| `nixpkgs`          | flake input                                                                  | required | The nixpkgs to build from                                                                             |
| `targetPlatform`   | attrset from `ap2.platforms`                                                 | required | The target the toolchain compiles for                                                                 |
| `buildSystem`      | string                                                                       | required | Host Nix system, for example `"x86_64-linux"`                                                         |
| `crane`            | lib                                                                          | `null`   | Crane lib. Required for `initrd.fromRustBinary` and `buildArdosRustPackage`; both throw if it is null |
| `toolchainConfig`  | attrset                                                                      | `{}`     | Toolchain-level settings. Currently `toolchainConfig.glibc.runtimePrefix`, for example `"/ardos"`     |
| `externalMappings` | list of `{ drv, runtimeLayout }` or function from `crossPkgs` to such a list | `[]`     | Runtime layouts for nixpkgs derivations that do not declare their own                                 |
| `glibcPlugins`     | list or function from `crossPkgs` (plus `toolchainConfig`) to a list         | `[]`     | NSS plugins with `passthru.glibcPlugin` metadata                                                      |

The nixpkgs and crane inputs are passed by the consumer rather than taken from the packer's own pins. The `externalMappings` and `glibcPlugins` functions are called with `crossPkgs`, which is the only way to refer to the target's package set for their contents.

## Instance attributes

The value returned by `init` holds the following:

| Attribute                | Type          | Description                                                                      |
| ------------------------ | ------------- | -------------------------------------------------------------------------------- |
| `buildPkgs`              | nixpkgs       | The build host's nixpkgs (patched)                                               |
| `crossPkgs`              | nixpkgs       | Nixpkgs cross-compiling to the target                                            |
| `stdenv`                 | derivation    | `crossPkgs.stdenv`, patched for Ardos                                            |
| `cc`                     | derivation    | The cross compiler for the target                                                |
| `craneLib`               | lib or `null` | `crane.mkLib buildPkgs` when `crane` was passed                                  |
| `mkArdosDerivation`      | builder       | C/C++ builder for Ardos packages                                                 |
| `mkArdosDerivationClang` | builder       | Clang-based variant                                                              |
| `wrapDerivation`         | builder       | Attach a layout to an existing derivation                                        |
| `buildArdosRustPackage`  | builder       | Cargo-backed Rust builder                                                        |
| `callPackage`            | function      | `path: overrides`, with `crossPkgs`, the builders, and `ap2 = instance` in scope |
| `nssFilesPlugin`         | derivation    | The built-in NSS files plugin                                                    |
| `kernel`                 | builder       | Linux kernel builder                                                             |
| `initrd`                 | builder       | Initramfs packer; also `initrd.fromRustBinary`                                   |
| `limine`                 | derivation    | Limine bootloader binary                                                         |
| `sysroot`                | builder       | `mkSysroot`, assembles the runtime tree                                          |
| `rom`                    | builder       | SquashFS assembly                                                                |
| `vm`                     | attrset       | `vm.ovmf` firmware and `vm.launch` launch script                                 |
| `setExternalMappings`    | function      | Returns a new instance with different mappings                                   |
| `setGlibcPlugins`        | function      | Returns a new instance with different plugins                                    |
| `setToolchainConfig`     | function      | Returns a new instance with a different toolchain config                         |

The `set*` functions re-run `init` with the given argument overridden, which lets tests and downstream code derive a modified instance without rebuilding from scratch.

## callPackage

`instance.callPackage` resolves package files against `crossPkgs` plus the builders and the instance itself. Inside a package file, `mkArdosDerivation`, `mkArdosDerivationClang`, `wrapDerivation`, and `buildArdosRustPackage` are available without qualification, and `ap2` refers to the instance:

```nix
{ mkArdosDerivation, ap2 }:

mkArdosDerivation {
  pname = "zlib";
  version = "1.3.1";
  src = fetchurl { ... };
  runtimeLayout = [
    { source = "lib/"; target = "/ardos/core/"; }
  ];
}
```

## Constraints

- `initrd.fromRustBinary` and `buildArdosRustPackage` require `crane`; call `init` with it if you use either.
- The `set*` functions apply their change to the whole instance, not to individual packages. They re-run `init`, so a changed mapping affects every build that consumes it.

## Related references

- [Builders reference](../builders/) for what `mkArdosDerivation` and the image builders accept.
- [About the build pipeline](../../explanation/build-pipeline/) for what the pipeline does with these settings.
