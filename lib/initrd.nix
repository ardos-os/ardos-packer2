{
  buildPkgs,
  crane ? null,
  crossPkgs ? null,
}:
let
  inherit (buildPkgs) stdenvNoCC cpio gzip;

in {

  __functor = self: {
    src,
    name ? "ardos-initrd",
    compression ? "${gzip}/bin/gzip",
  }:
    stdenvNoCC.mkDerivation {
      inherit name src;

      nativeBuildInputs = [ cpio gzip ];

      buildCommand = ''
        mkdir -p $out
        (
          cd "$src"
          find . -print0 | cpio --null -H newc -o | ${compression} > $out/initrd.img
        )
      '';

      meta = {
        description = "Ardos initramfs cpio archive";
      };
    };

  fromRustBinary =
    if crane == null
    then throw "ardosPacker.initrd.fromRustBinary requires `crane` to be passed to ardosPacker.init ()"
    else src:
    let
      targetCpu = if crossPkgs != null
        then crossPkgs.stdenv.hostPlatform.cpu
        else "x86_64";

      muslCrossTarget = {
        x86_64  = { pkgs = buildPkgs.pkgsCross.musl64;                       rustTarget = "x86_64-unknown-linux-musl"; };
        aarch64 = { pkgs = buildPkgs.pkgsCross.aarch64-multiplatform-musl;     rustTarget = "aarch64-unknown-linux-musl"; };
      };
      mc = muslCrossTarget.${targetCpu}
        or (throw "initrd.nix: unsupported target CPU for musl cross-compilation: ${targetCpu}");

      craneLib = crane.mkLib mc.pkgs;
      rustBin = craneLib.buildPackage {
        src = craneLib.cleanCargoSource src;
        strictDeps = true;
        CARGO_BUILD_TARGET = mc.rustTarget;
        RUSTFLAGS = "-C target-feature=+crt-static";
      };
    in
    stdenvNoCC.mkDerivation {
      name = "ardos-initrd";

      nativeBuildInputs = [ cpio gzip ];

      buildCommand = ''
        mkdir -p $out
        initrdDir=$(mktemp -d)
        cp ${rustBin}/bin/* "$initrdDir/init"
        chmod +x "$initrdDir/init"
        (
          cd "$initrdDir"
          find . -print0 | cpio --null -H newc -o | gzip > $out/initrd.img
        )
        
      '';

      meta = {
        description = "Ardos initramfs built from a Rust crate";
      };
    };
}
