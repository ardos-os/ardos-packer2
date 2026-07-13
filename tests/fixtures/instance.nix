{ buildSystem, targetPlatform, nixpkgs, ap2, crane ? null }:
ap2.init {
  inherit targetPlatform buildSystem nixpkgs crane;
  externalMappings = import ./glibcExternalMappings.nix;
}
