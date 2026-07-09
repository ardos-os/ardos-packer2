# packages/hello/default.nix
# A hello world binary for Ardos that links against hellolibrary.
{
  mkArdosDerivation,
  hellolibrary,
}:
mkArdosDerivation {
  pname = "hello";
  version = "0.1.0";
  src = ./src;

  # hellolibrary is a target dependency (runs on Ardos)
  buildInputs = [hellolibrary];

  # Enable debug logs for wrapper diagnostics
  NIX_DEBUG = 1;

  # Disable patchelf RPATH shrinking since target paths do not exist on the build host
  dontPatchELF = true;
  dontShrinkRpath = true;

  # Declare the runtime layout as a script. Even a single binary benefits from the
  # script form: it documents intent and is the same shape you'd use for a package
  # with thousands of files.
  runtimeLayoutScript = ''
    mkdir -p "$stage/hello"
    ln -sfn "$out/bin/hello" "$stage/hello/hello"
  '';

  buildPhase = ''
    runHook preBuild
    $CC -o hello main.c -I${hellolibrary}/include -L${hellolibrary}/lib -lhellolibrary
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp hello $out/bin/
    runHook postInstall
  '';
}
