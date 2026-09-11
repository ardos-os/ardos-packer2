# Probe: build a Rust crate with crane for the Ardos target.
#
# Run with:
#   nix build .#probe-rust.x86_64.rustCheck
{
  lib,
  nixpkgs,
  ap2,
  crane,
  rust-overlay ? null,
}: let
  probe = buildSystem: targetPlatform: let
    instance = ap2.init {
      inherit nixpkgs buildSystem targetPlatform;
      inherit crane;
      inherit rust-overlay;
      externalMappings = import ../tests/fixtures/glibcExternalMappings.nix;
    };
  in {
    rustCheck =
      instance.buildArdosRustPackage {
        src = instance.craneLib.cleanCargoSource ./rust-probe;
        strictDeps = true;
        runtimeLayout = [
          {
            source = "bin/rust-probe";
            target = "/rust-probe/rust-probe";
          }
        ];
      };
  };
in {
  x86_64 = probe "x86_64-linux" ap2.platforms.x86_64;
}
