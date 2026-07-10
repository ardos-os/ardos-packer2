{lib, ardosPackerLib, nixpkgs}:
let
  mkNixBuildSystem = ardosPlatform: "${ardosPlatform.cpu}-${ardosPlatform.kernel}";
in
  lib.mapAttrs' (_buildName: buildPlatform: let
    system = mkNixBuildSystem buildPlatform;
    pkgs = import nixpkgs {inherit system;};
    ardosPacker = ardosPackerLib.init {
      targetPlatform = ardosPackerLib.platforms.x86_64;
      buildSystem = system;
      inherit nixpkgs;
    };
    crossPkgs = ardosPacker.crossPkgs;
  in
    lib.nameValuePair system (lib.optionalAttrs buildPlatform.enableDevShell {
      default = pkgs.mkShell {
        name = "ardos-packer-devshell";
        packages = with pkgs; [just alejandra nix-output-monitor cachix git];
      };
      stdenv = pkgs.mkShell {
        name = "ardos-packer-stdenv-devshell";
        inputsFrom = [crossPkgs.stdenv];
        packages = with pkgs; [just alejandra nix-output-monitor cachix git];
        shellHook = ''
          echo "============================================="
          echo "  Ardos Cross-Compilation Shell Active       "
          echo "  Target: x86_64-linux-ardos                 "
          echo "  CC: $CC                                    "
          echo "============================================="
        '';
      };
    })
  ) ardosPackerLib.platforms
