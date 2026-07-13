{
  lib,
  ap2,
  nixpkgs,
  crane ? null,
}: let



  mkPackagesForBuildPlatform = _buildName: buildPlatform: let
    buildSystem = buildPlatform.linuxTriple;

    targetPackagesByTriple =
      lib.mapAttrs' (
        _targetName: targetPlatform:
          lib.nameValuePair targetPlatform.config ((import ../tests/fixtures/instance.nix) { inherit buildSystem targetPlatform nixpkgs ap2 crane; })
      )
      ap2.platforms;

    targetPackages =
      lib.concatMapAttrs (targetTriple: ardosPacker: let
        hellolibrary = ardosPacker.callPackage ./hellolibrary {};
        hello = ardosPacker.callPackage ./hello {inherit hellolibrary;};
        glibcTest = ardosPacker.callPackage ./glibc-test {};
        testEtc = ardosPacker.callPackage ./test-etc {};
        sysroot = ardosPacker.sysroot {
          name = "ardos-sysroot-${targetTriple}";
          includePackages = [hello];
        };
      in {
        "${targetTriple}" = {
          "ardos-sysroot" = sysroot;
          "ardos-rom" = ardosPacker.rom {
            inherit sysroot;
          };
          "stdenv" = ardosPacker.crossPkgs.stdenv;
          "hellolibrary" = hellolibrary;
          "hello" = hello;
          "glibcTest" = glibcTest;
          "testEtc" = testEtc;

          "vm-run" = ardosPacker.vm.launch {
            kernel = ardosPacker.buildPkgs.linuxPackages_latest.kernel;
            initrd = ardosPacker.initrd.fromRustBinary ./vm-initramfs;
            rom = ardosPacker.rom { inherit sysroot; };
            kernel-params = "init=/init";
          };
        };
      })
      targetPackagesByTriple;
  in
    targetPackages
    // {
      default = targetPackages."${buildPlatform.config}".ardos-rom;
    };
in
  lib.mapAttrs' (
    buildName: buildPlatform:
      lib.nameValuePair (buildPlatform.linuxTriple) (mkPackagesForBuildPlatform buildName buildPlatform)
  )
  ap2.platforms
