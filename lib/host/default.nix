# lib/host — Stage 0: host nixpkgs.
#
# Patches the upstream nixpkgs with the ardos-ABI additions (lib/systems/parse.nix,
# gcc/libgcc, gcc/common/builder) and configures the cachix substituter so
# build artefacts that come from this repo's cache short-circuit rebuilds.
#
# The toolchain stage (Stage 1) re-imports the result of this stage. It does
# not need to know about the patches; it just gets `hostPatchedNixpkgs` back.
{nixpkgs}: let
  beforePatchBuildPkgs = import nixpkgs {
    system = "x86_64-linux"; # placeholder; the toolchain stage re-imports per buildSystem
  };

  patchedNixpkgs = beforePatchBuildPkgs.applyPatches {
    name = "nixpkgs-ardos";
    src = nixpkgs;
    patches = [./patches/nixpkgs.patch];
  };
in {
  inherit patchedNixpkgs;
}
