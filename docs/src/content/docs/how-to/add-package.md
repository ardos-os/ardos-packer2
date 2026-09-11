---
title: Add a package to an Ardos image
description: Choose the right builder, declare where the package's files land, and get them into the image.
---

This guide shows you how to add a package to an Ardos image: which builder to use, how to declare where the files land at runtime, and how to map dependencies that were not built for Ardos.

## When to use this guide

Use this when you have source code in C, C++, or Rust, or an existing nixpkgs derivation, and you want it inside an Ardos ROM. It assumes you already have an `ap2` instance, meaning `ap2.init` was called and its result is in scope. Building one is covered in the [instance reference](../reference/instance).

## Before you start

- An `ap2` instance initialized for your target platform.
- Working packages that assemble into an image; see [Assemble the system image](../how-to/assemble-image).
- A rough idea of where each file should end up in the final filesystem.

## Choose a builder

Every package ends up describing where its files go. The builder you pick depends on where the package comes from:

| Package                                                                          | Builder                  |
| -------------------------------------------------------------------------------- | ------------------------ |
| C or C++ source you compile yourself                                             | `mkArdosDerivation`      |
| C or C++ that needs clang as the cross compiler, such as BPF program compilation | `mkArdosDerivationClang` |
| A Rust crate built with Cargo                                                    | `buildArdosRustPackage`  |
| An existing nixpkgs derivation you cannot edit                                   | `wrapDerivation`         |

## Declare where the files go

The `runtimeLayout` option is a list of `{ source, target }` entries. `source` is relative to the package's `$out`; `target` is an absolute path in the Ardos filesystem.

```nix
runtimeLayout = [
  { source = "lib/"; target = "/hellolibrary/"; }
  { source = "bin/hello"; target = "/hello/hello"; }
];
```

A `source` ending in `/` is a folder mapping. Every file under that folder at build time is copied under `target`, preserving the subdirectory structure. A `source` without the trailing slash maps a single file. When two entries produce the same target path, the last entry wins.

The entries are written to `$out/nix-support/ardos-layout`. The linker wrapper reads them while the package links, and the sysroot reads them again at assembly time.

## Build a C program with mkArdosDerivation

```nix
{ mkArdosDerivation, hellolibrary }:

mkArdosDerivation {
  pname = "hello";
  version = "0.1.0";
  src = ./src;

  buildInputs = [ hellolibrary ];

  runtimeLayout = [
    { source = "bin/hello"; target = "/hello/hello"; }
  ];

  buildPhase = ''
    runHook preBuild
    $CC -o hello main.c -I${hellolibrary}/include -L${hellolibrary}/lib -lhellolibrary
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp hello $out/bin/
    runHook postInstall
  '';
}
```

`mkArdosDerivation` accepts the usual `mkDerivation` attributes, with `pname`, `version`, and `runtimeLayout` added. The dependency in `buildInputs` is a target dependency: it runs on Ardos rather than on the build machine. Because `hellolibrary` declares `lib/` and `include/` as folder mappings, the linker knows that `-I${hellolibrary}/include` and `-L${hellolibrary}/lib` correspond to `/hellolibrary/include` and `/hellolibrary`, and it writes those translated paths into the binary.

If your build needs clang as the cross compiler, use `mkArdosDerivationClang` with the same argument shape.

## Wrap a nixpkgs package with wrapDerivation

Some dependencies come straight from nixpkgs and cannot be changed to declare an Ardos layout. `wrapDerivation` attaches a layout to an existing derivation:

```nix
ap2.wrapDerivation ap2.crossPkgs.pcre2 {
  runtimeLayout = [
    { source = "lib/"; target = "/ardos/inputs/foreign/"; }
    { source = "lib/pkgconfig/"; target = "/dev/null"; }
  ];
}
```

A target of `/dev/null` excludes the source from the image. Here it throws away the pkg-config files that carry Nix store paths.

Shared runtime libraries that appear in many packages are usually mapped once at the instance level instead, through `externalMappings`. The libc mappings in the example fixture look like this:

```nix
{ drv = crossPkgs.glibc;
  runtimeLayout = [ { source = "lib/"; target = "/ardos/lib/"; } ]; }
```

Pass the list, or a function from `crossPkgs` to the list, as the `externalMappings` argument of `ap2.init`. The setup hook only applies a mapping when that derivation is actually in the link closure, so unmapped dependencies are not copied.

## Build a Rust crate with buildArdosRustPackage

Rust crates go through Cargo, so they use a wrapper around `crane.buildPackage`:

```nix
ap2.buildArdosRustPackage {
  src = ../../modules/my-service;
  cargoLock = ../../modules/my-service/Cargo.lock;
  runtimeLayout = [
    { source = "bin/my-service"; target = "/ardos/init/my-service"; }
  ];
}
```

The crate is cross-compiled for the Ardos target, so it links against the same runtime libraries as the rest of the image. Map any dynamic dependency it has the same way you would for a C package. Passing `crane` to `ap2.init` is required; the builder throws without it.

## Get the package into the image

Building the package is only half the work. The image contains the closure of the packages you list in the sysroot call. Add yours to `includePackages`:

```nix
ap2.sysroot {
  includePackages = [ myPackage somethingElse ];
}
```

Follow the rest of the assembly steps in [Assemble the system image](../how-to/assemble-image).

## Troubleshooting

**Problem: the linker fails with an unmapped Nix store path in the RPATH or interpreter**
The build aborts with a list of unmapped paths and similar unused mappings. Map the package or library that owns that path. If it is a nixpkgs derivation, map it with `externalMappings` or `wrapDerivation`.

**Problem: the binary works in the build but the image is missing `libc.so.6`**
glibc and libgcc are external to `mkArdosDerivation`. Your instance needs their mappings, usually the `externalMappings` set with glibc, libgcc, and the gcc lib directory each mapped to `/ardos/lib/`.

**Problem: pkg-config files or headers leak Nix store paths into the image**
If the files are not needed, map the offending source to `/dev/null`, as in the `pcre2` example above. If they must end up in the image, keep them and rewrite the store paths with a `postFixup` hook instead.

**Problem: `buildArdosRustPackage` throws about a null crane**
Pass `crane` to `ap2.init`. Without it the Rust builder is unavailable.

## Related guides

- [Assemble the system image](../how-to/assemble-image) to turn `includePackages` into a ROM.
- [Run the image in a virtual machine](../how-to/run-vm) to boot what you built.
- [Instance reference](../reference/instance) for the full `ap2.init` option set.
- [Builders reference](../reference/builders) for the complete `runtimeLayout` rules.
