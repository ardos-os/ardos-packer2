# packages/hellolibrary/default.nix
# A shared library for Ardos, installed at /hellolibrary/ at runtime.
#
# Demonstrates the `runtimeLayout` form: a list of { source, target } entries
# where source is relative to $out. Sources ending with "/" are folder mappings.
{mkArdosDerivation}:
mkArdosDerivation {
  pname = "hellolibrary";
  version = "0.1.0";
  src = ./src;

  runtimeLayout = [
    { source = "lib/"; target = "/hellolibrary/"; }
    { source = "include/"; target = "/hellolibrary/include/"; }
  ];

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
