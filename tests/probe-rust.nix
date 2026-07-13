# Probe: build a Rust crate with crane for the Ardos target.
#
# Run with:
#   nix build .#probe-rust.x86_64.rustCheck

{
  lib,
  nixpkgs,
  ap2,
  crane,
}: let
  probe = buildSystem: targetPlatform: let
    instance = ap2.init {
      inherit nixpkgs buildSystem targetPlatform;
      externalMappings = import ../tests/fixtures/glibcExternalMappings.nix;
    };
    crossPkgs = instance.crossPkgs;
    craneLib = (crane.mkLib crossPkgs.pkgsBuildTarget);
  in {
    rustCheck = instance.wrapDerivation (craneLib.buildPackage {
      src = craneLib.cleanCargoSource ./rust-probe;
      strictDeps = true;
    }) {
      runtimeLayoutScript = ''
        mkdir -p "$stage/rust-probe"
        ln -sfn "$out/bin/rust-probe" "$stage/rust-probe/rust-probe"
      '';
    };
  };
in {
  x86_64 = probe "x86_64-linux" ap2.platforms.x86_64;
}
