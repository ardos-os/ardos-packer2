{ buildSystem, targetPlatform, nixpkgs, ap2 }:
ap2.init {
  inherit targetPlatform buildSystem nixpkgs;
  externalMappings = import ./glibcExternalMappings.nix { runtimePrefix = null; };
}