## Checks via readelf that the glibc-test binary has the correct
## dynamic interpreter and RPATH, and links against libc.

ctx:

let
  glibcTest = ctx.pkgs.glibcTest;

  expectedInterpreters = {
    x86_64-ardos-linux-gnu = "/ardos/lib/ld-linux-x86-64.so.2";
    aarch64-ardos-linux-gnu = "/ardos/lib/ld-linux-aarch64.so.1";
    riscv64-ardos-linux-gnu = "/ardos/lib/ld-linux-riscv64-lp64d.so.1";
  };

  expectedInterpreter = expectedInterpreters.${ctx.targetTriple};
in {
  name = "glibc-test-binary";

  nativeBuildInputs = [
    ctx.buildPkgs.patchelf
  ];

  script = ''
    echo "Checking glibc-test binary ELF properties for ${ctx.targetTriple}..."

    interp=$(patchelf --print-interpreter ${glibcTest}/bin/glibc-test)
    echo "Interpreter: $interp"

    rpath=$(patchelf --print-rpath ${glibcTest}/bin/glibc-test)
    echo "RPATH: $rpath"

    if [ "$interp" != "${expectedInterpreter}" ]; then
      echo "FAIL: Expected interpreter ${expectedInterpreter}, got $interp"
      exit 1
    fi

    if [ -z "$rpath" ]; then
      echo "FAIL: RPATH is empty"
      exit 1
    fi

    if [[ "$rpath" == *"/nix/store/"* ]]; then
      echo "FAIL: RPATH leaked a Nix store path"
      exit 1
    fi

    touch "$out"
  '';
}
