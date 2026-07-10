# ardos-packer2 — public library entry point.
#
# Thin aggregator over the pipeline stages. Each stage has its own directory
# under `lib/`:
#
#   lib/host/         Stage 0 — host nixpkgs (for devShells, helper builds)
#   lib/toolchain/    Stage 1 — cross-compilation toolchain (crossPkgs)
#   lib/builder/      Stage 2 — per-package builder (mkArdosDerivation)
#   lib/sysroot/      Stage 3 — package merge (Milestone 3, not yet implemented)
#   lib/rom/          Stage 4 — ROM / squashfs assembly (Milestone 3, not yet implemented)
#
# External consumers (e.g. flake.nix) only ever call `init` here. They should
# not import from the per-stage directories directly.
{nixpkgs}: let
  lib = nixpkgs.lib;
  platforms = import ./platforms.nix {inherit lib;};
in rec {
  inherit platforms;

  # Initialise a build context for a specific target platform.
  #
  # Args:
  #   targetPlatform: attrset as produced by ./platforms.nix
  #                   (e.g. { cpu = "x86_64"; kernel = "linux"; abi = "ardos"; ... })
  #   buildSystem:    string identifying the host nix system
  #                   (e.g. "x86_64-linux")
  #   toolchainConfig: optional attrset for toolchain-level concerns
  #                   (e.g. { glibc = { runtimePrefix = "/ardos"; }; })
  init = args: let
    inherit (args) targetPlatform buildSystem;
    externalMappingsArg = args.externalMappings or [];
    toolchainConfig = args.toolchainConfig or {};
    host = import ./host {inherit nixpkgs;};
    toolchain = import ./toolchain {
      inherit nixpkgs targetPlatform buildSystem host toolchainConfig;
      rustScript = import ./builder/rustScript.nix {
        buildPkgs = nixpkgs.legacyPackages.${buildSystem} or
          (throw "lib/default.nix: buildPkgs for ${buildSystem} not available; check that nixpkgs.legacyPackages.${buildSystem} is set");
      };
    };
    inherit (toolchain) crossPkgs buildPkgs;
    externalMappings =
      if builtins.isFunction externalMappingsArg
      then externalMappingsArg crossPkgs
      else externalMappingsArg;
    glibcPluginsArg = args.glibcPlugins or [];
    glibcPlugins =
      if builtins.isFunction glibcPluginsArg
      then glibcPluginsArg crossPkgs
      else glibcPluginsArg;
    builder = import ./builder {
      inherit buildPkgs crossPkgs externalMappings;
    };
    sysrootLib = import ./sysroot {
      inherit buildPkgs externalMappings glibcPlugins;
    };
  in let
    instance = rec {
      inherit buildPkgs crossPkgs;
      inherit (builder) mkArdosDerivation mkRuntimeTree;

      stdenv = crossPkgs.stdenv;
      cc = toolchain.toolchain.cc;

      nssFilesPlugin = import ./plugins/nss-files.nix {
        glibc = crossPkgs.glibc;
        inherit (buildPkgs) runCommand;
      };

      callPackage = path: overrides: let
        scope =
          crossPkgs
          // {
            inherit mkArdosDerivation mkRuntimeTree;
            ap2 = instance;
          };
      in
        lib.callPackageWith scope path overrides;

      sysroot = sysrootLib.mkSysroot;

      rom = {
        sysroot,
        name ? "ardos-rom",
      }:
        buildPkgs.runCommand "${name}.squashfs" {
          nativeBuildInputs = [
            buildPkgs.squashfsTools
          ];
        } ''
          mksquashfs "${sysroot}" "$out" -noappend -all-root -no-progress
        '';
      setExternalMappings = mappings: init (args // {externalMappings = mappings;});
      setGlibcPlugins = plugins: init (args // {glibcPlugins = plugins;});
      setToolchainConfig = config: init (args // {toolchainConfig = config;});
    };
  in
    instance;
}
