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
    packages = import ./packages {inherit lib ardosPackerLib nixpkgs;};
  in {
    lib = ardosPackerLib;
    inherit packages;

    checks = import ./tests {inherit lib ardosPackerLib nixpkgs packages;};
    devShells = import ./devShells {inherit lib ardosPackerLib nixpkgs;};
  };
}
