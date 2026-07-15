{mkArdosDerivation}:
mkArdosDerivation {
  pname = "test-etc";
  version = "0.1.0";

  dontUnpack = true;

  runtimeLayout = [
    { source = "etc/passwd"; target = "/etc/passwd"; }
    { source = "etc/group"; target = "/etc/group"; }
  ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/etc
    cat > $out/etc/passwd << 'PWEOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
PWEOF
    cat > $out/etc/group << 'GREOF'
root:x:0:
nobody:x:65534:
GREOF
    runHook postInstall
  '';
}
