# packages/hellolibrary/default.nix
# A shared library for Ardos, installed at /hellolibrary/ at runtime.
{mkArdosDerivation}:
mkArdosDerivation {
  pname = "hellolibrary";
  version = "0.1.0";
  src = ./src;

  # Declare the runtime layout: the .so will live at /hellolibrary/libhellolibrary.so
  runtimeLayout = [
    {
      source = "lib/libhellolibrary.so";
      target = "/hellolibrary/libhellolibrary.so";
    }
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
