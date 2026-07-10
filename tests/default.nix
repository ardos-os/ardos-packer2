## Ardos Packer 2 Test Runner/Loader

{
  lib,
  ap2,
  nixpkgs,
  packages,
}: let
  ##########################################################################
  ## Common helpers
  ##########################################################################

  importTests = dir:
    let
      files =
        builtins.filter
        (
          file:
            file != "default.nix"
            && builtins.match ".*\\.nix" file != null
        )
        (builtins.attrNames (builtins.readDir dir));
    in
      map (file: import (dir + "/${file}")) files;

  unitTests = importTests ./unit;
  integrationTests = importTests ./integration;

  ## Instantiates the ctx parameter for tests
  mkTestBaseContext =
    buildPlatform:
    targetPlatform:
    let
      system = buildPlatform.linuxTriple;
      target = targetPlatform.ardosTriple;
      ap2Instance = import ./fixtures/instance.nix { buildSystem = buildPlatform.linuxTriple; inherit targetPlatform; inherit nixpkgs; inherit ap2; };
      
    in {
      inherit
        lib
        ap2
        nixpkgs
        packages
        system
        buildPlatform
        targetPlatform
        ap2Instance;

      targetTriple = targetPlatform.config;

      pkgsAllArchs = packages.${system};
      pkgs = packages.${system}.${target};

      buildPkgs = import nixpkgs {
        inherit system;
      };
    };

  ##########################################################################
  ## Unit runner
  ##
  ## Unit tests are scripts that validate the outputs come out right and are
  ## ran in the context of the build system.
  ##########################################################################

  mkUnitCheck =
    ctx:
    test:
    type:
    let
      spec = test ctx;

      skip =
        if builtins.hasAttr "skipIf" spec
        then spec.skipIf
        else false;
    in
      lib.optionalAttrs (!skip) {
        "${ctx.targetTriple}-${type}-${spec.name}" 
          = ctx.buildPkgs.runCommand
            "${type}-test-${spec.name}-${ctx.targetTriple}"
            {
              nativeBuildInputs =
                if builtins.hasAttr "nativeBuildInputs" spec
                then spec.nativeBuildInputs
                else [ ];
            }
            spec.script;
      };

  runUnitTestsForTarget =
    buildPlatform:
    targetPlatform:
    let
      ctx = mkTestBaseContext buildPlatform targetPlatform;
    in
      lib.foldl'
        lib.recursiveUpdate
        { }
        (map (test: mkUnitCheck ctx test "unit") unitTests);

  runUnitTests =
    buildPlatform:
      lib.foldl'
        lib.recursiveUpdate
        { }
        (
          lib.mapAttrsToList
            (_: targetPlatform:

    
              runUnitTestsForTarget
                buildPlatform
                targetPlatform )
            ap2.platforms
        );
  ################################################################################
  ## Integration runner
  ## --------------------
  ## 
  ## Sometimes running scripts in the build system context is not enough to
  ## validate something is working correctly and entering the OS environment
  ## becomes necessary.
  ## 
  ## Integration tests become in handy because the test runner chroots
  ## inside a sysroot with some packages you include and allows you to run
  ## a command and assert its outcome.
  ##
  ## Since integration tests assume binaries are runnable from the build
  ## system's cpu architecture, they are not runnable if the cpu of the system
  ## running them doesn't match the target cpu the packages were compiled to.
  ## 
  ##   NOTE: This chroot is rootless similar to podman and is implemented
  ##   using `proot`.
  ## 
  ################################################################################

mkIntegrationTest =
  ctx:
  test:
  let
    externalMappings =
      if builtins.hasAttr "externalMappings" test
      then test.externalMappings ctx
      else [ ];

    ctx' =
      ctx
      // {
        ap2Instance =
          ctx.ap2Instance.setExternalMappings externalMappings;
      };

    spec =
      test.build ctx';

    skip =
      (spec.skipIf or false)
      || ctx'.buildPlatform.cpu != ctx'.targetPlatform.cpu;

    sysroot =
      ctx'.ap2Instance.sysroot {
        name = "integration-${spec.name}-${ctx'.targetTriple}";
        includePackages = spec.includePackages;
      };

    quotedArgs =
      lib.concatStringsSep " "
        (map lib.escapeShellArg spec.args);
    expectedStdout = ctx.buildPkgs.writeText "expected-stdout" spec.expected.stdout;
    expectedStderr = ctx.buildPkgs.writeText "expected-stderr" spec.expected.stderr;
  in {
      inherit (spec)
        name;

      inherit skip;

      nativeBuildInputs = [
        ctx'.buildPkgs.proot
        ctx'.buildPkgs.coreutils
      ];

      script = ''
        set -x
        cd /
        stdout="$TMPDIR/stdout"
        stderr="$TMPDIR/stderr"

        exitCode=0
        proot -R ${sysroot} ${spec.command} ${quotedArgs} >"$stdout" 2>"$stderr" || exitCode=$?
        failed=false
        diff -u "${expectedStdout}" "$stdout" || failed=true
        diff -u "${expectedStderr}" "$stderr" || failed=true
        expectedExitCode=${toString spec.expected.exitCode}
        if ! test "$exitCode" -eq $expectedExitCode; then 
          echo exit code mismatch
          echo "   expected : $expectedExitCode"
          echo "   actual   : $exitCode"
          failed=true
        fi
        set +x
        if [[ $failed == true ]]; then
          echo "error: Test failed";
          exit 1;
        fi
        touch "$out"
      '';
    };

  runIntegrationTestsForTarget =
    buildPlatform:
    targetPlatform:
    let
      ctx =
        mkTestBaseContext
          buildPlatform
          targetPlatform;

    in
      lib.foldl'
        lib.recursiveUpdate
        { }
        (
          map
            (test:
              mkUnitCheck
                ctx
                (_: mkIntegrationTest ctx test)
                "integration")
            integrationTests
        );

  runIntegrationTests =
    buildPlatform:
      lib.foldl'
        lib.recursiveUpdate
        { }
        (
          lib.mapAttrsToList
            (_: targetPlatform:
              runIntegrationTestsForTarget
                buildPlatform
                targetPlatform)
            ap2.platforms
        );
in

lib.mapAttrs'
  (_: buildPlatform:
    lib.nameValuePair
      (buildPlatform.linuxTriple)
      (
        (runUnitTests buildPlatform) // (runIntegrationTests buildPlatform)
      ))
  ap2.platforms