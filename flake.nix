{
  description = "Ardos Packer 2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    ardosPackerLib = import ./lib {inherit nixpkgs;};

    mkNixBuildSystem = ardosPlatform: "${ardosPlatform.cpu}-${ardosPlatform.kernel}";

    mkPackagesForBuildPlatform = buildName: buildPlatform: let
      buildSystem = mkNixBuildSystem buildPlatform;

      mkPackagesForArdosTarget = targetName: targetPlatform: let
        ardosPacker = ardosPackerLib.init {
          
          inherit targetPlatform buildSystem nixpkgs;
        };
      in {
        name = targetPlatform.config;
        value = ardosPacker;
      };

      targetPackagesByTriple =
        lib.mapAttrs' mkPackagesForArdosTarget ardosPackerLib.platforms;

      targetPackages =
        lib.concatMapAttrs (
          targetTriple: ardosPacker: let
            hellolibrary = import ./packages/hellolibrary {
              inherit (ardosPacker) mkArdosDerivation;
            };
            hello = import ./packages/hello {
              inherit (ardosPacker) mkArdosDerivation;
              inherit hellolibrary;
            };
          in {
            #"cross-${targetTriple}" = ardosPacker.stdenv.crossPkgs;
            #"toolchain-${targetTriple}" = ardosPacker.toolchain;
            "ardos-rom-${targetTriple}" = ardosPacker.ardosRom;
            "stdenv-${targetTriple}" = ardosPacker.stdenv.crossPkgs.stdenv;
            "hellolibrary-${targetTriple}" = hellolibrary;
            "hello-${targetTriple}" = hello;
          }
        )
        targetPackagesByTriple;
    in
      targetPackages
      // {
        default = targetPackages.ardos-rom-x86_64-linux-ardos;
      };
  in {
    packages =
      lib.mapAttrs'
      (
        buildName: buildPlatform:
          lib.nameValuePair
          (mkNixBuildSystem buildPlatform)
          (mkPackagesForBuildPlatform buildName buildPlatform)
      )
      ardosPackerLib.platforms;
    checks = let
      # Hardcoded platform lookup from your library
      buildPlatform = ardosPackerLib.platforms."x86_64";

      system = "x86_64-linux";
      pkgs = mkPackagesForBuildPlatform "x86_64-linux" buildPlatform;
      buildPkgs = import nixpkgs {inherit system;};
      hello = pkgs."hello-x86_64-linux-ardos";
    in {
      hello-binary =
        buildPkgs.runCommand "check-hello-binary" {
          nativeBuildInputs = [buildPkgs.patchelf];
        } ''
          echo "Checking hello binary ELF properties..."
          interp=$(patchelf --print-interpreter ${hello}/bin/hello)
          echo "Interpreter: $interp"
          rpath=$(patchelf --print-rpath ${hello}/bin/hello)
          echo "RPATH: $rpath"

          if [ "$interp" != "/ardos/lib/ld-linux-x86-64.so.2" ]; then
            echo "Error: Interpreter is not /ardos/lib/ld-linux-x86-64.so.2! Actual: $interp" >&2
            exit 1
          fi

          if [[ "$rpath" != *"/hellolibrary"* ]]; then
            echo "Error: RPATH does not contain /hellolibrary" >&2
            exit 1
          fi

          if [[ "$rpath" == *"/nix/store/"* ]]; then
            echo "Error: RPATH contains /nix/store path" >&2
            exit 1
          fi

          echo "All checks passed!"
          touch $out
        '';
    };

    devShells =
      lib.mapAttrs'
      (
        buildName: buildPlatform: let
          system = mkNixBuildSystem buildPlatform;
          pkgs = import nixpkgs {inherit system;};
          ardosPacker = ardosPackerLib.init {
            targetPlatform = ardosPackerLib.platforms.x86_64;
            buildSystem = system;
            inherit nixpkgs;
          };
          crossPkgs = ardosPacker.stdenv.crossPkgs;
        in
          lib.nameValuePair system {
            default = pkgs.mkShell {
              name = "ardos-packer-devshell";
              packages = with pkgs; [
                just
                alejandra
                nix-output-monitor
                cachix
                git
              ];
            };
            stdenv = pkgs.mkShell {
              name = "ardos-packer-stdenv-devshell";
              inputsFrom = [crossPkgs.stdenv];
              packages = with pkgs; [
                just
                alejandra
                nix-output-monitor
                cachix
                git
              ];
              shellHook = ''
                echo "============================================="
                echo "  Ardos Cross-Compilation Shell Active       "
                echo "  Target: x86_64-linux-ardos                 "
                echo "  CC: $CC                                    "
                echo "============================================="
              '';
            };
          }
      )
      ardosPackerLib.platforms;
    apps =
      lib.mapAttrs'
      (
        buildName: buildPlatform: let
          system = mkNixBuildSystem buildPlatform;
          pkgs = import nixpkgs {inherit system;};

          # The path to your KDL layout. Nix will automatically
          # copy this file to the Nix Store preserving its .kdl extension.
          kdlPath = ./zellij-layouts/local-llm.kdl;

          startAiScript = pkgs.writeShellScriptBin "start-ai" ''
            set -euo pipefail

            if ! command -v zellij &> /dev/null; then
              echo "❌ Error: Zellij is not installed. Please install it to use this app."
              exit 1
            fi
            export PATH=$PATH:${pkgs.codex}/bin:${pkgs.ollama-vulkan}/bin:${pkgs.aider-chat}/bin:${./zellij-layouts/scripts}
            export VK_ICD_FILENAMES="${pkgs.mesa.drivers}/share/vulkan/icd.d/intel_icd.x86_64.json"
            export LD_LIBRARY_PATH="${pkgs.vulkan-loader}/lib:${pkgs.mesa.drivers}/lib:''${LD_LIBRARY_PATH:-}"
            echo "🤖 Initializing Ardos AI development environment inside Zellij..."

            # Point Zellij directly to the immutable Nix store path of the KDL file
            ${pkgs.zellij}/bin/zellij --layout "${kdlPath}"
          '';
        in
          lib.nameValuePair system {
            start-ai = {
              type = "app";
              program = "${startAiScript}/bin/start-ai";
            };
            vk = {
              type = "app";
              program = "${pkgs.vulkan-tools}/bin/vkcube";
            };
          }
      )
      ardosPackerLib.platforms;
  };
}
