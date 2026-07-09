{nixpkgs}: let
  lib = nixpkgs.lib;
in rec {
  platforms = import ./platforms.nix {inherit lib;};
  init = args: let
    inherit (args) targetPlatform buildSystem;
    rustScript = import ./rustScript.nix {buildPkgs = stdenv.buildPkgs;};
    stdenv = import ./stdenv {inherit platforms targetPlatform buildSystem nixpkgs rustScript;};
    ardosDerivations = import ./mkArdosDerivation.nix {inherit stdenv nixpkgs rustScript;};
  in {
    inherit stdenv;
    inherit (stdenv) toolchain;
    inherit (ardosDerivations) mkArdosDerivation mkRuntimeTree;
    inherit rustScript;
    cc = stdenv.toolchain.cc;
    ardosRom = import ./ardosRom.nix stdenv;
  };
}
