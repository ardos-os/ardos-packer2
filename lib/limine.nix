{
  buildPkgs,
  lib,
}:
let
  version = "10.2.1-binary";

  # Compute SRI hash from hex:
  #   nix hash to-sri --type sha256 f5039b62e2ba7138cf1dc91fe715f5fe03fc4503eba49441e71894dd7bcbb6f9
  tarballHash = "sha256-9QObYuK6cTjPHckf5xX1/gP8RQPrpJRB5xiU3XvLtvk=";
in
buildPkgs.stdenvNoCC.mkDerivation {
  name = "limine-bootloader-${version}";

  src = buildPkgs.fetchurl {
    url = "https://github.com/limine-bootloader/Limine/archive/refs/tags/v${version}.tar.gz";
    hash = tarballHash;
  };

  sourceRoot = "Limine-${version}";

  buildPhase = "true";

  installPhase = ''
    mkdir -p $out
    cp BOOTX64.EFI $out/
  '';

  meta = {
    description = "Limine x86_64 UEFI bootloader (binary release)";
    homepage = "https://github.com/limine-bootloader/Limine";
    license = lib.licenses.bsd2;
    platforms = lib.platforms.x86_64;
  };
}
