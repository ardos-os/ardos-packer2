{lib, ardosPackerLib, nixpkgs}:
let
  mkNixBuildSystem = ardosPlatform: "${ardosPlatform.cpu}-${ardosPlatform.kernel}";

  defaultExternalMappings = pkgs: let
    libgcc = pkgs.gcc.cc.libgcc;
    glibc = pkgs.glibc;
  in [
    {
      drv = glibc;
      runtimeLayoutScript = ''
        for so in "$out"/lib/*.so*; do
          [ -e "$so" ] || continue
          mkdir -p "$stage/ardos/lib"
          ln -sfn "$so" "$stage/ardos/lib/$(basename "$so")"
        done
      '';
    }
    {
      drv = libgcc;
      runtimeLayoutScript = ''
        for so in "$out"/lib/*.so*; do
          [ -e "$so" ] || continue
          mkdir -p "$stage/ardos/lib"
          ln -sfn "$so" "$stage/ardos/lib/$(basename "$so")"
        done
      '';
    }
  ];

  mkArdosPacker = buildSystem: targetPlatform:
    ardosPackerLib.init {
      inherit targetPlatform buildSystem nixpkgs;
      externalMappings = defaultExternalMappings;
    };

  mkPackagesForBuildPlatform = _buildName: buildPlatform: let
    buildSystem = mkNixBuildSystem buildPlatform;

    targetPackagesByTriple = lib.mapAttrs' (_targetName: targetPlatform:
      lib.nameValuePair targetPlatform.config (mkArdosPacker buildSystem targetPlatform)
    ) ardosPackerLib.platforms;

    targetPackages = lib.concatMapAttrs (targetTriple: ardosPacker: let
      hellolibrary = ardosPacker.callPackage ./hellolibrary {};
      hello = ardosPacker.callPackage ./hello {inherit hellolibrary;};
    in {
      "ardos-rom-${targetTriple}" = ardosPacker.rom {
        includePackages = [hello];
      };
      "stdenv-${targetTriple}" = ardosPacker.crossPkgs.stdenv;
      "hellolibrary-${targetTriple}" = hellolibrary;
      "hello-${targetTriple}" = hello;
    }) targetPackagesByTriple;
  in targetPackages // {
    default = targetPackages.ardos-rom-x86_64-linux-ardos;
  };
in
  lib.mapAttrs' (buildName: buildPlatform:
    lib.nameValuePair (mkNixBuildSystem buildPlatform) (mkPackagesForBuildPlatform buildName buildPlatform)
  ) ardosPackerLib.platforms
