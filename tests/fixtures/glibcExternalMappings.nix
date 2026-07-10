# glibcExternalMappings.nix — external mappings for glibc + libgcc.
#
# runtimePrefix: optional, e.g. "/ardos". When set, glibc is built with
# DESTDIR=$out --prefix=<runtimePrefix>, so libraries install to
# $out/<runtimePrefix>/lib instead of $out/lib.
{
  runtimePrefix ? null,
}:

crossPkgs: let
  libgcc = crossPkgs.gcc.cc.libgcc;
  glibc = crossPkgs.glibc;

  # When glibc is built with --prefix=/ardos and DESTDIR=$out, the
  # install path is $out/ardos/lib.  Otherwise it is $out/lib.
  glibcLibDir =
    if runtimePrefix != null
    then "${glibc}/${runtimePrefix}/lib"
    else "${glibc}/lib";
in [
  {
    drv = glibc;
    runtimeLayoutScript = ''
      for so in ${glibcLibDir}/*.so*; do
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
