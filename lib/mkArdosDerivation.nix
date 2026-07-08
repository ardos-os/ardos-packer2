# mkArdosDerivation — Exposes the package builder abstraction for Ardos runtime packages.
# Separates target compilation/linking (stdenv) from package runtime layout definition.
{
  stdenv,
  nixpkgs,
}: let
  lib = nixpkgs.lib;

  # Build a runtimeTree (materialized symlink structure of target paths)
  mkRuntimeTree = {
    pname,
    version,
    drv,
  }:
    stdenv.crossPkgs.runCommand "${pname}-runtime-tree-${version}" {
      nativeBuildInputs = [stdenv.crossPkgs.coreutils];
    } ''
      mkdir -p $out
      # Parse the layout of the package and create symlinks at the target paths
      if [ -f "${drv}/nix-support/ardos-layout" ]; then
        while read -r line || [[ -n "$line" ]]; do
          [[ "$line" =~ ^# ]] && continue
          [[ -z "$line" ]] && continue

          # Extract source relative path and absolute destination target path
          src_rel="''${line%% -> *}"
          dest_abs="''${line#* -> }"

          # Compute full source path in the nix store
          src_path="${drv}/''${src_rel}"

          # Strip the leading slash from the destination path to make it a relative path inside $out
          dest_rel="build-root/''${dest_abs#/}"
          dest_path="$out/$dest_rel"

          # Create parent directories of target destination in the output
          mkdir -p "$(dirname "$dest_path")"
          # Create the symlink pointing to the real nix store path
          ln -s "$src_path" "$dest_path"
        done < "${drv}/nix-support/ardos-layout"
      fi
    '';
in rec {
  inherit mkRuntimeTree;

  # The main package builder
  mkArdosDerivation = {
    pname,
    version,
    runtimeLayout ? [], # List of { source, target } mappings
    ...
  } @ args: let
    # Remove runtimeLayout from attributes passed to mkDerivation
    cleanArgs = removeAttrs args ["runtimeLayout"];

    # Format the layout mappings into an environment string for our setup hook
    layoutMetadata = lib.concatStringsSep "\n" (
      map (entry: "${entry.source} -> ${entry.target}") runtimeLayout
    );

    # Build the derivation using our target stdenv
    drv = stdenv.crossPkgs.stdenv.mkDerivation (cleanArgs
      // {
        # Pass the layout mapping to our ardos-setup-hook via env
        ardosLayoutMetadata = layoutMetadata;

        # Automatically install the ardos-layout file in nix-support
        postInstall =
          (args.postInstall or "")
          + ''
            mkdir -p $out/nix-support
            echo "${layoutMetadata}" > $out/nix-support/ardos-layout
          '';
      });
  in
    drv.overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          ardos = {
            inherit runtimeLayout;
            runtimeTree = mkRuntimeTree {
              inherit pname version;
              drv = drv;
            };
          };
        };
    });
}
