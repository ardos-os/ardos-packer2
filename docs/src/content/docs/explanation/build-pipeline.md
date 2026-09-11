---
title: About the build pipeline
description: Why Ardos packages declare runtime locations, and how the pipeline translates paths between the Nix store and the final image.
---

This page covers the design: why a build system converts Nix store paths into Ardos runtime paths, and how the pipeline arranges that translation. The exact options and outputs live in the [builders reference](../reference/builders/).

## The pipeline at a glance

![Pipeline diagram: package recipes become Nix store outputs, combined into the /ardos filesystem, then packed into ardos-rom.squashfs](../../../assets/process-whiteboard.svg)

The diagram follows one path from recipes to image. Nix compiles each package recipe into a store output, the Sysroot Materializer combines the outputs into the `/ardos` filesystem, and the ROM Generator packs that tree into `ardos-rom.squashfs`. The rest of this page explains why each step takes the shape it does.

## Background

Nix derivations install their outputs under the Nix store, at a path that exposes the derivation's content hash. That works well for build machines, but the store path is not a location anyone wants to ship as the operating system's filesystem. Ardos is not NixOS: it has its own runtime tree, and the kernel, the initramfs, and the root filesystem all agree on fixed locations for the parts of the OS.

So a package built by this pipeline has two homes. During the build it lives in the store, where the compiler finds its headers and libraries by hash. At runtime it lives somewhere under `/ardos/` or a package path like `/hellolibrary/`, where the booted system looks for it. The pipeline has to make a binary that was linked in one world run in the other.

## The core concept

Each package declares, once, where its files belong in the final tree. That declaration is the `runtimeLayout` list, and it is written into the package output as `$out/nix-support/ardos-layout`. Nothing is copied or transformed at declaration time. The file travels with the package and is read by two later stages.

The linker stage reads it while the package links. Every `-rpath` and `-dynamic-linker` argument that names a Nix store folder is looked up against the declared layouts. A folder mapping with a trailing slash is matched by longest prefix, so a mapping like `lib/ -> /hellolibrary/` absorbs any subdirectory directly under it. Matched paths become their Ardos equivalents; unmatched store paths would leak into the binary, so the linker fails the build and reports them instead of emitting a broken artifact.

The assembly stage reads the same file again while building the sysroot. It walks the closure of the packages that go into the image, expands every folder mapping, and copies the files into one tree mirroring the target paths. That tree becomes the ROM.

One decision shapes the whole design: the layout file is the single source of truth, and each package writes it directly to its output. There is no intermediate symlink tree for the assembler to follow. The linker and the sysroot both consume the same lines, so a package's declared runtime location is the foundation of every later step.

## Why translate at link time

The usual way to fix wrong runtime paths after the fact is to rewrite the ELF with `patchelf`. The pipeline deliberately does not do that on final images. Post-processing is fragile, and it means the artifact you inspect on the build machine is not the artifact that ships. Instead, the linker wrapper translates the flags before they reach the linker, so the produced binary already carries the final paths. The build-time inputs stay Nix store paths, because the compiler needs them, while the emitted binary references Ardos paths, because that is where its libraries will live.

A second reason is principled: a binary whose RPATH or interpreter still names a store path is a symptom of a package that forgot to map one of its dependencies. Raising that as a build error catches the mistake where it happens, while patching a binary afterward would hide it.

## Why external mappings exist

Some dependencies come from nixpkgs and were never written for this pipeline, so they cannot declare a `runtimeLayout`. The glibc and libgcc pair is the main example. `externalMappings` attaches a layout to such a derivation from the outside. The mapping is applied at link time only when the derivation actually appears in the link closure, so a generic glibc mapping does not reach into unrelated outputs.

## Why glibc gets a runtime prefix

Nix cross-builds usually install the libc into the store and let the dynamic linker live in glibc's default build tree. Ardos wants a single libc at a known runtime location, which is what `toolchainConfig.glibc.runtimePrefix` provides. With a prefix of `/ardos`, the overlay compiles glibc so that everything the OS loads at runtime points into `/ardos/lib`, while the build itself still installs into `$out`. The same idea repeats for any package that hardcodes absolute paths, which is also why a package's runtime target is a build-time decision rather than a post-build relocation.

## Keeping the toolchain cheap to rebuild

The link-time hook is split into a stable stub and a replaceable implementation. The stub, a few lines that source an implementation file when an environment variable points at one, is copied into the cross toolchain's bintools and never changes. The implementation is injected per build. The reason is purely rebuild hygiene: a change to the translation logic does not invalidate every derivation built with the toolchain; only builds that actually use the machinery are affected. The setup hooks follow the same rule and stay outside the toolchain patches.

## Trade-offs

The pipeline takes on nixpkgs to get the cross toolchain, the package recipes, and a patched rust compiler with a built-in Ardos target. That is a pragmatic choice during this experimental phase, but it makes Ardos dependent on the same code base NixOS is built on. The plan is to move the toolchain and the packages onto derivations of its own and cut that link. Until then, the interface is what protects the callers: as long as a package only passes `runtimeLayout` and the standard derivation arguments, the internal toolchain can change without the package definitions changing.

## Further reading

- [Build your first Ardos image](../tutorials/first-build/) puts the pipeline to work end to end.
- [Add a package to an Ardos image](../how-to/add-package/) and [Assemble the system image](../how-to/assemble-image/) use the pieces described here.
- [Instance reference](../reference/instance/) and [Builders reference](../reference/builders/) give the exact options.
