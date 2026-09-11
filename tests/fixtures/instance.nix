{
  buildSystem,
  targetPlatform,
  nixpkgs,
  ap2,
  crane ? null,
  rust-overlay ? null,
}:
ap2.init {
  inherit targetPlatform buildSystem nixpkgs crane rust-overlay;
  externalMappings = import ./glibcExternalMappings.nix;
}
