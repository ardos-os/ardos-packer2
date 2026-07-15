{mkArdosDerivation}:
mkArdosDerivation {
  pname = "glibc-test";
  version = "0.1.0";
  src = ./src;

  runtimeLayout = [
    { source = "bin/glibc-test"; target = "/glibc-test/glibc-test"; }
    { source = "lib/"; target = "/glibc-test/lib/"; }
  ];

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
