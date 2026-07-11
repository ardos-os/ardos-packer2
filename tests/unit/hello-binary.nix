## Checks via `readelf` command that the binary requests libraries from the right 
## paths at runtime.

ctx:

let
  hello =
    ctx.pkgs.hello;

  expectedInterpreters = {
    x86_64-ardos-linux-gnu = "/ardos/lib/ld-linux-x86-64.so.2";
    aarch64-ardos-linux-gnu = "/ardos/lib/ld-linux-aarch64.so.1";
    riscv64-ardos-linux-gnu = "/ardos/lib/ld-linux-riscv64-lp64d.so.1";
  };

  expectedInterpreter =
    expectedInterpreters.${ctx.targetTriple};

in {
  name = "hello-binary";

  nativeBuildInputs = [
    ctx.buildPkgs.patchelf
  ];

  script = ''
    echo "Checking hello binary ELF properties for ${ctx.targetTriple}..."

    interp=$(patchelf --print-interpreter ${hello}/bin/hello)
    echo "Interpreter: $interp"

    rpath=$(patchelf --print-rpath ${hello}/bin/hello)
    echo "RPATH: $rpath"

    if [ "$interp" != "${expectedInterpreter}" ]; then
      echo "Expected interpreter: ${expectedInterpreter}"
      exit 1
    fi

    if [[ "$rpath" != *"/hellolibrary"* ]]; then
      echo "Missing /hellolibrary in RPATH"
      exit 1
    fi

    if [[ "$rpath" == *"/nix/store/"* ]]; then
      echo "RPATH leaked a Nix store path"
      exit 1
    fi

    touch "$out"
  '';
}