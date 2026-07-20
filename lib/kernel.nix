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

let
  targetCpu = crossPkgs.stdenv.hostPlatform.cpu;

  archToKarch = {
    x86_64  = "x86";
    aarch64 = "arm64";
  };
  karch = archToKarch.${targetCpu}
    or (throw "kernel.nix: unsupported target CPU ${targetCpu}");

  kernelImageByArch = {
    x86_64  = { path = "arch/x86/boot/bzImage"; outputName = "bzImage"; };
    aarch64 = { path = "arch/arm64/boot/Image";   outputName = "Image"; };
  };
  kernelImage = kernelImageByArch.${targetCpu}
    or (throw "kernel.nix: unsupported target CPU ${targetCpu}");
in
buildPkgs.stdenv.mkDerivation {
  pname = "linux";
  inherit version src;

  outputs = [ "out" "headers" ];

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
    buildPkgs.zstd
    buildPkgs.gmp
    buildPkgs.mpfr
    buildPkgs.libmpc
    buildPkgs.rustc
    buildPkgs.rust-bindgen
    buildPkgs.rustPlatform.rustcSrc
  ];

  configurePhase = ''
    runHook preConfigure

    # Start from arch defconfig (establishes Kconfig tree)
    make ARCH=${targetCpu} defconfig

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
    make ARCH=${targetCpu} olddefconfig

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make ARCH=${targetCpu} -j"$NIX_BUILD_CORES" KBUILD_BUILD_TIMEOUT=0
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # --- Main output: kernel image ---
    mkdir -p $out
    cp ${kernelImage.path} $out/bzImage

    # --- Headers output: build tree for external modules ---
    # Mirrors the Arch linux-headers _package-headers function.
    mkdir -p $headers

    echo "Installing build files..."
    cp .config Makefile Module.symvers System.map vmlinux $headers/
    cp version $headers/ 2>/dev/null || true
    cp localversion* $headers/ 2>/dev/null || true
    [ -f tools/bpf/bpftool/vmlinux.h ] && cp tools/bpf/bpftool/vmlinux.h $headers/

    mkdir -p $headers/kernel
    cp kernel/Makefile $headers/kernel/
    mkdir -p $headers/arch/${karch}
    cp arch/${karch}/Makefile $headers/arch/${karch}/

    cp -r scripts $headers/
    ln -s scripts/gdb/vmlinux-gdb.py $headers/vmlinux-gdb.py 2>/dev/null || true

    if grep -q "CONFIG_HAVE_STACK_VALIDATION=y" .config 2>/dev/null; then
      mkdir -p $headers/tools/objtool
      cp tools/objtool/objtool $headers/tools/objtool/
    fi
    if grep -q "CONFIG_DEBUG_INFO_BTF_MODULES=y" .config 2>/dev/null; then
      mkdir -p $headers/tools/bpf/resolve_btfids
      cp tools/bpf/resolve_btfids/resolve_btfids $headers/tools/bpf/resolve_btfids/
    fi

    echo "Installing headers..."
    cp -r include $headers/
    cp -r arch/${karch}/include $headers/arch/${karch}/
    install -Dt $headers/arch/${karch}/kernel -m644 arch/${karch}/kernel/asm-offsets.s 2>/dev/null || true

    install -Dt $headers/drivers/md -m644 drivers/md/*.h 2>/dev/null || true
    install -Dt $headers/net/mac80211 -m644 net/mac80211/*.h 2>/dev/null || true
    install -Dt $headers/drivers/media/i2c -m644 drivers/media/i2c/msp3400-driver.h 2>/dev/null || true
    install -Dt $headers/drivers/media/usb/dvb-usb -m644 drivers/media/usb/dvb-usb/*.h 2>/dev/null || true
    install -Dt $headers/drivers/media/dvb-frontends -m644 drivers/media/dvb-frontends/*.h 2>/dev/null || true
    install -Dt $headers/drivers/media/tuners -m644 drivers/media/tuners/*.h 2>/dev/null || true
    install -Dt $headers/drivers/iio/common/hid-sensors -m644 drivers/iio/common/hid-sensors/*.h 2>/dev/null || true

    echo "Installing KConfig files..."
    find . -name 'Kconfig*' -exec install -Dm644 {} "$headers/{}" \;

    if grep -q "CONFIG_RUST=y" .config 2>/dev/null; then
      echo "Installing Rust files..."
      mkdir -p $headers/rust
      cp rust/*.rmeta $headers/rust/
      cp rust/*.so $headers/rust/ 2>/dev/null || true
    fi

    echo "Installing unstripped VDSO..."
    make INSTALL_MOD_PATH=$headers vdso_install link= 2>/dev/null || true

    echo "Removing unneeded architectures..."
    for arch_dir in $headers/arch/*/; do
      [[ $arch_dir = */${karch}/ ]] && continue
      rm -r "$arch_dir"
    done

    echo "Removing documentation..."
    rm -rf $headers/Documentation

    echo "Removing unneeded directories..."
    rm -rf $headers/scripts/dtc

    echo "Removing broken symlinks..."
    find $headers -type l -exec test ! -e {} \; -delete 2>/dev/null || true

    echo "Removing loose objects..."
    find $headers -type f -name '*.o' -delete

    echo "Stripping build tools..."
    find $headers -type f -perm -u+x ! -name vmlinux -print0 2>/dev/null | \
      xargs -0 -I{} sh -c 'case "$(file -Sib "{}")" in
        application/x-sharedlib*)  strip -v {} ;;
        application/x-archive*)    strip -v {} ;;
        application/x-executable*) strip -v {} ;;
        application/x-pie*)        strip -v {} ;;
      esac' || true

    echo "Stripping vmlinux..."
    strip -v $headers/vmlinux 2>/dev/null || true

    runHook postInstall
  '';

  enableParallelBuilding = true;

  meta = {
    description = "Ardos OS Linux kernel";
    platforms = lib.platforms.x86_64 ++ lib.platforms.aarch64;
  } // extraMeta;
}
