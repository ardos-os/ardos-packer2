{nixpkgs}: let
  lib = nixpkgs.lib;
in rec {
  platforms = import ./platforms.nix {inherit lib;};
  init = args: let
    inherit (args) targetPlatform buildSystem;
    stdenv = import ./stdenv {inherit platforms targetPlatform buildSystem nixpkgs;};
  in {
    inherit stdenv;
    cc = stdenv.crossPkgs.clang;
    ardosRom = import ./ardosRom.nix stdenv;
  };
}
