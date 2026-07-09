{lib, ardosPackerLib, nixpkgs, packages}:
let
  mkNixBuildSystem = ardosPlatform: "${ardosPlatform.cpu}-${ardosPlatform.kernel}";
  expectedInterpreters = {
    x86_64-linux-ardos = "/ardos/lib/ld-linux-x86-64.so.2";
    aarch64-linux-ardos = "/ardos/lib/ld-linux-aarch64.so.1";
    riscv64-linux-ardos = "/ardos/lib/ld-linux-riscv64-lp64d.so.1";
  };
in
  lib.mapAttrs' (_buildName: buildPlatform: let
    system = mkNixBuildSystem buildPlatform;
    pkgs = packages.${system};
    buildPkgs = import nixpkgs {inherit system;};
  in
    lib.nameValuePair system (
      lib.mapAttrs' (_targetName: targetPlatform: let
        targetTriple = targetPlatform.config;
        hello = pkgs."hello-${targetTriple}";
        expectedInterpreter = expectedInterpreters.${targetTriple};
      in
        lib.nameValuePair "hello-binary-${targetTriple}" (
          buildPkgs.runCommand "check-hello-binary-${targetTriple}" {
            nativeBuildInputs = [buildPkgs.patchelf];
          } ''
            echo "Checking hello binary ELF properties for ${targetTriple}..."
            interp=$(patchelf --print-interpreter ${hello}/bin/hello)
            echo "Interpreter: $interp"
            rpath=$(patchelf --print-rpath ${hello}/bin/hello)
            echo "RPATH: $rpath"

            if [ "$interp" != "${expectedInterpreter}" ]; then
              echo "Error: Interpreter is not ${expectedInterpreter}! Actual: $interp" >&2
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
          ''
        )
      ) ardosPackerLib.platforms
      // lib.optionalAttrs (system == "x86_64-linux") {
        hello-chroot-x86_64-linux-ardos = let
          sysroot = pkgs.ardos-sysroot-x86_64-linux-ardos;
        in
          buildPkgs.runCommand "check-hello-chroot-x86_64-linux-ardos" {
            nativeBuildInputs = [buildPkgs.coreutils];
          } ''
            echo "Running /hello/hello inside ${sysroot} with chroot..."
            actual=$(chroot ${sysroot} /hello/hello)
            expected=$'Hello from hellolibrary!\n2 + 3 = 5'

            if [ "$actual" != "$expected" ]; then
              echo "Unexpected hello output:" >&2
              printf '%s\n' "$actual" >&2
              exit 1
            fi

            touch $out
          '';
      }
    )
  ) ardosPackerLib.platforms
