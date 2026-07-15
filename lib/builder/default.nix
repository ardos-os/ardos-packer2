# lib/builder — Stage 2: per-package builder.
#
# Exposes:
#   * `rustScript` — a function that compiles inline Rust into a host-side
#     build tool. Used by the toolchain stage to build ardos-setup-tool.
#   * `mkArdosDerivation` — the per-package builder (see mkArdosDerivation.nix).
#   * `wrapDerivation` — turns a normal derivation into an Ardos derivation
#     by attaching runtime layout metadata.
#
# The hooks and setup-hook files in this directory are referenced by both the
# toolchain stage (to inject the ld-wrapper stub and ardos-setup setup-hook)
# and by mkArdosDerivation (which records the resolved layout).
{
  buildPkgs,
  crossPkgs,
  crane ? null,
  externalMappings ? [],
}: rec {
  rustScript = import ./rustScript.nix {inherit buildPkgs;};
  inherit
    (import ./mkArdosDerivation.nix {
      nixpkgs = buildPkgs;
      inherit crossPkgs rustScript crane externalMappings;
    })
    mkArdosDerivation
    wrapDerivation
    buildArdosRustPackage
    ;
}
