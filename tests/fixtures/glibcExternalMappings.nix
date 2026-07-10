
crossPkgs: let
  libgcc = crossPkgs.gcc.cc.libgcc;
  glibc = crossPkgs.glibc;
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
]