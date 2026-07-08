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
          targetTriple: ardosPacker: let
            hellolibrary = import ./packages/hellolibrary {
              inherit (ardosPacker) mkArdosDerivation;
            };
            hello = import ./packages/hello {
              inherit (ardosPacker) mkArdosDerivation;
              inherit hellolibrary;
            };
          in {
            "ardos-rom-${targetTriple}" = ardosPacker.ardosRom;
            "cross-${targetTriple}" = ardosPacker.stdenv.crossPkgs;
            "toolchain-${targetTriple}" = ardosPacker.toolchain;
            "stdenv-${targetTriple}" = ardosPacker.stdenv.crossPkgs.stdenv;
            "hellolibrary-${targetTriple}" = hellolibrary;
            "hello-${targetTriple}" = hello;
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

    devShells =
      lib.mapAttrs'
      (
        buildName: buildPlatform: let
          system = mkNixBuildSystem buildPlatform;
          pkgs = import nixpkgs {inherit system;};
          ardosPacker = ardosPackerLib.init {
            targetPlatform = ardosPackerLib.platforms.x86_64;
            buildSystem = system;
            inherit nixpkgs;
          };
          crossPkgs = ardosPacker.stdenv.crossPkgs;
        in
          lib.nameValuePair system {
            default = pkgs.mkShell {
              name = "ardos-packer-devshell";
              packages = with pkgs; [
                just
                alejandra
                nix-output-monitor
                cachix
                git
              ];
              shellHook = ''
                echo "============================================="
                echo "  Ardos Packer Development Shell Active      "
                echo "  Available tools: just, alejandra, nom, git "
                echo "============================================="
              '';
            };
            stdenv = pkgs.mkShell {
              name = "ardos-packer-stdenv-devshell";
              inputsFrom = [crossPkgs.stdenv];
              packages = with pkgs; [
                just
                alejandra
                nix-output-monitor
                cachix
                git
              ];
              shellHook = ''
                echo "============================================="
                echo "  Ardos Cross-Compilation Shell Active       "
                echo "  Target: x86_64-linux-ardos                 "
                echo "  CC: $CC                                    "
                echo "============================================="
              '';
            };
          }
      )
      ardosPackerLib.platforms;
  };
}
