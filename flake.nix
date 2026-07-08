{
  description = "Ardos Packer 2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    ardosPackerLib = import ./lib {inherit nixpkgs;};

    mkNixBuildSystem = ardosPlatform: "${ardosPlatform.cpu}-${ardosPlatform.kernel}";

    mkPackagesForBuildPlatform = buildName: buildPlatform: let
      buildSystem = mkNixBuildSystem buildPlatform;

      mkPackagesForArdosTarget = targetName: targetPlatform: let
        ardosPacker = ardosPackerLib.init {
          inherit targetPlatform buildSystem nixpkgs;
        };
      in {
        name = targetPlatform.config;
        value = ardosPacker;
      };

      targetPackagesByTriple =
        lib.mapAttrs' mkPackagesForArdosTarget ardosPackerLib.platforms;

      targetPackages =
        lib.concatMapAttrs (
          targetTriple: ardosPacker: {
            "ardos-rom-${targetTriple}" = ardosPacker.ardosRom;
            "ardos-clang-${targetTriple}" = ardosPacker.cc;
            "ardos-bash-${targetTriple}" = ardosPacker.stdenv.crossPkgs.bash;
            "cross-${targetTriple}" = ardosPacker.stdenv.crossPkgs;
          }
        )
        targetPackagesByTriple;
    in
      targetPackages
      // {
        default = targetPackages.ardos-rom-x86_64-linux-ardos;
      };
  in {
    packages =
      lib.mapAttrs'
      (
        buildName: buildPlatform:
          lib.nameValuePair
          (mkNixBuildSystem buildPlatform)
          (mkPackagesForBuildPlatform buildName buildPlatform)
      )
      ardosPackerLib.platforms;
  };
}
