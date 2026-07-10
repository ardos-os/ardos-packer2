{
  description = "Declarative and deterministic build system for Ardos OS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    ap2 = import ./lib {inherit nixpkgs;};
    packages = import ./packages {inherit lib ap2 nixpkgs;};
  in {
    lib = ap2;
    testPackages = packages;

    checks = import ./tests {inherit lib ap2 nixpkgs packages;};
    devShells = import ./devShells {inherit lib ap2 nixpkgs;};
  };
}
