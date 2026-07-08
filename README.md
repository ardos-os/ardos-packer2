# Ardos Packer 2

This is a rewrite of [ardos-packer](https.//github.com/ardos-os/ardos-packer) in the Nix language, prioritizing reproducibility, 
isolated package builds and better support for cross compiling.

> WARNING: This is still experimental and unfinished so don't judge too soon.


## How is this even possible?

It might seem impossible, nix is highly tied to the nix store and nix os. But actually nix is the perfect tool for building 
reproducible artifacts in a declarative manner. It gives you lots of features such as a full blown functional programming language
made specifically for building packages, remote caching, reproducible builds, build sandboxing (cuts off internet and other
things that may be source of impurities), explicit dependencies and isolated builds. All one needs to build an Ardos OS image is just
nix and it does everything.

We can use the host's nixpkgs to build a cross compiling toolchain targetting Ardos OS with all the libraries in the right
places as it is implemented in [here](./lib/stdenv/default.nix).

The Ardos OS stdenv is built on top of the nixpkgs stdenv frameworks, however, the toolchain is patched and overlayed
to make sure everything is building correct Ardos OS binaries and libraries. Not only that, but [nixpkgs itself is patched](./lib/stdenv/patches/nixpkgs.patch) to make nixpkgs also recognize Ardos OS as a valid target.

This answers the building story, but how do we go from `/nix/store/gibberish` to nice Ardos OS paths inside the squashfs?

### Symbolic Link Mapping

Nix paths are only an implementation detail of the build process. Runtime paths are described separately by each Ardos package. The package declares where each file should exist inside the final filesystem, and a runtime tree derivation materializes this mapping using symbolic links.

So instead of the `ardosPacker.makeRom` function accepting any derivation from nixpkgs, first you need to wrap into a Ardos OS derivation, which creates a package containing symbolic links to files in the original derivation. Ardos packer will then read
those symlinks and create the final squashfs by copying the original files into the squashfs, checking by any collisions (such as 2 packages mapping to the same runtime paths).