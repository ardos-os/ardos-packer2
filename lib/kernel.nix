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

  outputs = [ "out" "headers" "uapi" ];

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
    buildPkgs.rustc-unwrapped
    buildPkgs.clippy
    buildPkgs.rustfmt
    buildPkgs.rust-bindgen-unwrapped
    buildPkgs.file
    buildPkgs.zlib
  ];
  # Required so scripts/rust_is_available.sh (run by `make olddefconfig`)
  # can locate the Rust standard library sources to build `core`. Without
  # this, CONFIG_RUST_IS_AVAILABLE stays off and CONFIG_RUST=y is dropped
  # during dependency resolution, so no .rmeta/.so artifacts are produced.
  RUST_LIB_SRC = "${buildPkgs.rustPlatform.rustLibSrc}";
  RUST_SRC_PATH = "${buildPkgs.rustPlatform.rustLibSrc}";
  dontCheckForBrokenSymlinks = true;
  dontFixup = true;
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
    cp ${kernelImage.path} $out/${kernelImage.outputName}

    # --- UAPI output: sanitized userspace headers ---
    # `make headers_install` produces clean UAPI headers suitable for
    # userspace compilation.  The raw build tree (headers output) contains
    # kernel-internal macros and must NOT be used by userspace packages.
    make ARCH=${targetCpu} headers_install INSTALL_HDR_PATH=$uapi

    # --- Headers output: build tree for external modules ---
    # Mirrors the Arch linux-headers _package-headers function. Ardos points
    # cargo-nok (NOK_KERNEL_DIR) straight at this output, so the build tree is
    # laid out flat in $headers rather than under /usr/lib/modules/<ver>/build.
    echo "Installing build files..."
    install -Dt $headers -m644 .config Makefile Module.symvers System.map vmlinux
    install -Dt $headers -m644 version 2>/dev/null || true
    install -Dt $headers -m644 localversion.* 2>/dev/null || true
    install -Dt $headers -m644 tools/bpf/bpftool/vmlinux.h 2>/dev/null || true

    install -Dt $headers/kernel -m644 kernel/Makefile
    install -Dt $headers/arch/${karch} -m644 arch/${karch}/Makefile
    cp -at $headers scripts
    ln -sr $headers/scripts/gdb/vmlinux-gdb.py $headers/vmlinux-gdb.py 2>/dev/null || true

    if grep -q "^CONFIG_HAVE_STACK_VALIDATION=y" .config; then
      install -Dt $headers/tools/objtool tools/objtool/objtool
    fi
    if grep -q "^CONFIG_DEBUG_INFO_BTF_MODULES=y" .config; then
      install -Dt $headers/tools/bpf/resolve_btfids tools/bpf/resolve_btfids/resolve_btfids
    fi

    echo "Installing headers..."
    cp -rL include $headers/
    cp -rL arch/${karch}/include $headers/arch/${karch}/
    install -Dt $headers/arch/${karch}/kernel -m644 arch/${karch}/kernel/asm-offsets.s 2>/dev/null || true

    install -Dt $headers/drivers/md -m644 drivers/md/*.h 2>/dev/null || true
    install -Dt $headers/net/mac80211 -m644 net/mac80211/*.h 2>/dev/null || true

    # https://bugs.archlinux.org/task/13146
    install -Dt $headers/drivers/media/i2c -m644 drivers/media/i2c/msp3400-driver.h 2>/dev/null || true

    # https://bugs.archlinux.org/task/20402
    install -Dt $headers/drivers/media/usb/dvb-usb -m644 drivers/media/usb/dvb-usb/*.h 2>/dev/null || true
    install -Dt $headers/drivers/media/dvb-frontends -m644 drivers/media/dvb-frontends/*.h 2>/dev/null || true
    install -Dt $headers/drivers/media/tuners -m644 drivers/media/tuners/*.h 2>/dev/null || true

    # https://bugs.archlinux.org/task/71392
    install -Dt $headers/drivers/iio/common/hid-sensors -m644 drivers/iio/common/hid-sensors/*.h 2>/dev/null || true

    echo "Installing KConfig files..."
    find . -name 'Kconfig*' -exec install -Dm644 {} $headers/{} \;

    if grep -q "^CONFIG_RUST=y" .config 2>/dev/null; then
      echo "Installing Rust files..."
      mkdir -p $headers/rust
      cp rust/*.rmeta $headers/rust/ 2>/dev/null || true
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

    echo "Removing broken symlinks..."
    find -L $headers -type l -delete 2>/dev/null || true

    echo "Removing loose objects..."
    find $headers -type f -name '*.o' -delete 2>/dev/null || true

    echo "Stripping build tools..."
    strip_shared="--strip-unneeded"
    strip_static="--strip-debug"
    strip_binaries="--strip-all"
    find $headers -type f -perm -u+x ! -name vmlinux -print0 2>/dev/null | while IFS= read -r -d $'\0' f; do
      case "$(file -b --mime-type "$f")" in
        application/x-sharedlib)      strip -v $strip_shared "$f" ;;
        application/x-archive)        strip -v $strip_static "$f" ;;
        application/x-executable)     strip -v $strip_binaries "$f" ;;
        application/x-pie-executable) strip -v $strip_shared "$f" ;;
      esac
    done || true

    echo "Stripping vmlinux..."
    strip -v $strip_static $headers/vmlinux 2>/dev/null || true
    rm $headers/scripts/dtc/include-prefixes/dt-bindings
    runHook postInstall
  '';

  enableParallelBuilding = true;

  meta = {
    description = "Ardos OS Linux kernel";
    platforms = lib.platforms.x86_64 ++ lib.platforms.aarch64;
  } // extraMeta;
}
