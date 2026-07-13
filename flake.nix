{
  description = "Declarative and deterministic build system for Ardos OS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
  };

  outputs = {
    self,
    nixpkgs,
    crane,
  }: let
    lib = nixpkgs.lib;
    ap2 = import ./lib;
    packages = import ./packages {inherit lib ap2 nixpkgs;};
    probeRust = import ./tests/probe-rust.nix {inherit lib ap2 nixpkgs crane;};
  in {
    lib = ap2;
    testPackages = packages;

    checks = import ./tests {inherit lib ap2 nixpkgs packages;};
    devShells = import ./devShells {inherit lib ap2 nixpkgs;};

    # Temporary: Rust toolchain probe
    probe-rust = probeRust;
  };
}
