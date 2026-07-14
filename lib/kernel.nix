{
  buildPkgs,
  lib,
  crossPkgs,
}:
{
  src,
  version,
  configFile,
  extraMeta ? {},
}:

buildPkgs.stdenv.mkDerivation {
  pname = "linux";
  inherit version src;

  nativeBuildInputs = [
    buildPkgs.gcc
    buildPkgs.binutils
    buildPkgs.gnumake
    buildPkgs.bison
    buildPkgs.flex
    buildPkgs.bc
    buildPkgs.openssl
    buildPkgs.perl
    buildPkgs.elfutils
    buildPkgs.python3
    buildPkgs.cpio
    buildPkgs.rsync
    buildPkgs.gmp
    buildPkgs.mpfr
    buildPkgs.libmpc
  ];

  configurePhase = ''
    runHook preConfigure

    # Start from arch defconfig (establishes Kconfig tree)
    make defconfig

    # Override with user's config via sed (handles both partial and full configs)
    while IFS='=' read -r key value; do
      [[ -z "$key" ]] && continue
      [[ "$key" =~ ^# ]] && continue
      # Normalize key
      key="''${key//[[:space:]]/}"
      key=''${key#CONFIG_}
      key="''${key//-/_}"
      key="''${key//./_}"
      key=''${key^^}
      symbol="CONFIG_$key"

      if [[ "$value" == "y" ]]; then
        replacement="''${symbol}=y"
      elif [[ "$value" == "n" ]]; then
        replacement="''${symbol}=n"
      elif [[ "$value" =~ ^[0-9]+$ ]]; then
        replacement="''${symbol}=$value"
      else
        replacement="''${symbol}=$value"
      fi

      escaped_replacement=$(printf '%s' "$replacement" | sed 's/[&/|]/\\&/g')
      sed -i -e "s|^''${symbol}=.*|$escaped_replacement|" \
             -e "s|^# ''${symbol} is not set|$escaped_replacement|" .config || true
      if ! grep -q -E "^(# ''${symbol} is not set|''${symbol}=)" .config 2>/dev/null; then
        echo "$replacement" >> .config
      fi
    done < ${configFile}

    # Resolve any inconsistencies introduced by the overrides
    make olddefconfig

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j"$NIX_BUILD_CORES" KBUILD_BUILD_TIMEOUT=0
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp arch/x86/boot/bzImage $out/bzImage
    runHook postInstall
  '';

  enableParallelBuilding = true;

  meta = {
    description = "Ardos OS Linux kernel";
    platforms = lib.platforms.x86_64;
  } // extraMeta;
}
