# packages/hellolibrary/default.nix
# A shared library for Ardos, installed at /hellolibrary/ at runtime.
#
# Demonstrates the new `runtimeLayoutScript` form: a bash snippet that gets full
# freedom (loops, globs, conditionals) to decide where every file in the package
# should end up in the final Ardos filesystem.
{mkArdosDerivation}:
mkArdosDerivation {
  pname = "hellolibrary";
  version = "0.1.0";
  src = ./src;

  # The script runs with two variables in scope:
  #   $out   — path to the package's Nix store output (read-only for inspection)
  #   $stage — an empty staging directory representing the future Ardos filesystem
  # Use normal `ln -s` calls to declare the final layout.
  runtimeLayoutScript = ''
    # Map every file in $out/lib ending in .so into /hellolibrary/, preserving the
    # basename. This is the kind of glob-driven loop that the previous list-based
    # API could not express.
    for so in "$out"/lib/*.so*; do
      [ -e "$so" ] || continue
      mkdir -p "$stage/hellolibrary"
      ln -sfn "$so" "$stage/hellolibrary/$(basename "$so")"
    done

    # Headers stay colocated with the library on Ardos.
    mkdir -p "$stage/hellolibrary/include"
    for hdr in "$out"/include/*; do
      [ -f "$hdr" ] || continue
      ln -sfn "$hdr" "$stage/hellolibrary/include/$(basename "$hdr")"
    done
  '';

  buildPhase = ''
    runHook preBuild
    $CC -shared -fPIC -o libhellolibrary.so hellolibrary.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include
    cp libhellolibrary.so $out/lib/
    cp hellolibrary.h $out/include/
    runHook postInstall
  '';
}
