{
  description = "Ardos Packer 2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
    };
  in {
    packages.${system}.default =
      pkgs.runCommand "ardos-test" {} ''
        mkdir -p $out
        echo "Hello Ardos" > $out/test.txt
      '';
  };
}