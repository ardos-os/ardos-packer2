{mkArdosDerivation}:
mkArdosDerivation {
  pname = "glibc-test";
  version = "0.1.0";
  src = ./src;

  dontPatchELF = true;
  dontShrinkRpath = true;

  runtimeLayoutScript = ''
    mkdir -p "$stage/glibc-test"
    ln -sfn "$out/bin/glibc-test" "$stage/glibc-test/glibc-test"
  '';

  buildPhase = ''
    runHook preBuild
    $CC -o glibc-test main.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp glibc-test $out/bin/
    runHook postInstall
  '';
}
