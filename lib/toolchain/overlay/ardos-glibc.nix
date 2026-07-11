# Core glibc overlay — strips Nix runtime artifacts from nixpkgs glibc.
#
# Produces a minimal, distro-style glibc with no embedded /nix/store paths,
# no NixOS search paths, and no NSS/locale plugins in the default
# nsswitch.conf.  NSS .so modules are still built by glibc; plugins
# are added declaratively via glibcPlugins at the sysroot level.
#
# The overlay separates compile-time paths from install-time paths:
# runtimePrefix controls the compiled-in PREFIX (--prefix) so binaries
# reference /ardos/lib at runtime, while libdir, slibdir, rtlddir and
# inst_* overrides redirect make install to Nix store outputs.
# The libc.so linker script uses $out/lib paths (build-time valid),
# while default-rpath ensures binaries get /ardos/lib RPATH for runtime.
#
# Every DEFAULT RUNTIME SEARCH PATH that glibc bakes into its binaries
# (gconv modules, compiled locales, message catalogs, timezone data,
# charmaps and getconf) is decoupled the same way as the loader: the
# compiled-in default points at the runtime prefix (/ardos) while the
# matching inst_* variable keeps the install destination at $out (the
# Nix sandbox).  Without this, the ROM image would ship libc.so.6 and
# getconf that look for their data under /nix/store at runtime.
{lib}: {
  glibc,
  runtimePrefix ? null,
}: final: prev: let
  isTarget = prev.stdenv.hostPlatform.vendor == "ardos";

  # Extract a sortable name from a patch value (store path, path, or attrset).
  patchName = p:
    if builtins.isPath p
    then builtins.baseNameOf (builtins.toString p)
    else if builtins.isAttrs p
    then (p.name or (builtins.baseNameOf (p.outPath or "")))
    else builtins.baseNameOf (builtins.toString p);

  # Patches that embed Nix/NixOS-specific paths or behaviour.
  nixPatchNames = [
    "nix-locale-archive.patch"
    "dont-use-system-ld-so-cache.patch"
    "fix_path_attribute_in_getconf.patch"
    "nix-nss-open-files.patch"
  ];
in
  if !isTarget
  then {}
  else {
    glibc = glibc.overrideAttrs (old: let
      # --- Patch filtering ---
      # Remove NixOS-specific patches and add Ardos-specific ones.
      finalPatches =
        (lib.filter (
            p:
              !builtins.elem (patchName p) nixPatchNames
          )
          (old.patches or []))
        ++ lib.optionals (runtimePrefix != null) [
          ./decouple-rtlddir-from-libc-so.patch
        ];
      # --- makeFlags filtering ---
      # Remove flags that embed Nix store paths into compiled binaries.
      # Flatten nested lists first — makeFlags can contain `listOf (either str (list str))`.
      keptMakeFlags = let
        flatFlags = lib.concatMap (
          f:
            if builtins.isList f
            then f
            else [f]
        ) (old.makeFlags or []);
      in
        lib.filter (
          f:
            !(lib.hasPrefix "user-defined-trusted-dirs=" f
              || lib.hasPrefix "BUILD_LDFLAGS=" f)
        )
        flatFlags;

      # --- postPatch ---
      # Remove the LIBIDN2_SONAME substitution that bakes a store path into
      # inet/idna.c.  Without the substitution the upstream default
      # "libidn2.so.0" is used, resolved by standard dlopen at runtime.
      cleanedPostPatch = let
        raw = old.postPatch or "";
        lines = lib.splitString "\n" raw;
        filtered =
          lib.filter (
            line:
              !(lib.hasInfix "LIBIDN2_SONAME" line && lib.hasInfix "/nix/store" line)
          )
          lines;
      in
        lib.concatStringsSep "\n" filtered;

      # --- configureFlags ---
      # --prefix sets the compiled-in PREFIX.  With --prefix=/ardos, the
      # default --libdir=${exec_prefix}/lib resolves to /ardos/lib — the
      # runtime search path compiled into the dynamic linker (ld-linux).
      # We do NOT pass an explicit --libdir.  The build-time paths in
      # libc.so and other linker scripts are controlled by slibdir/rtlddir
      # make variables, which are overridden to $out/lib below.
      prefixFlags = lib.optionals (runtimePrefix != null) [
        "--prefix=${runtimePrefix}"
      ];

      # --- install-time path redirection ---
      # The nixpkgs multi-output hook overrides libdir to $lib/lib (a nix
      # store path).  We must redirect it to $out/lib so that ALL install
      # targets (including iconvdata, nss, login which use $(libdir)
      # directly instead of $(inst_libdir)) write into the sandbox.
      #
      # rtlddir is the RUNTIME path: it drives the self-identification
      # string compiled into ld-linux via -DRTLD (elf/Makefile) and the
      # PT_INTERP of glibc's own binaries (installed-rtld-LDFLAGS in
      # Makeconfig).  We set it to the runtime prefix (/ardos/lib) so the
      # ROM sees the correct absolute loader path.
      #
      # rtlddir-build is the BUILD-TIME path referenced by the libc.so
      # linker script's AS_NEEDED entry (our patch adds this variable,
      # defaulting to rtlddir).  It must point where the loader is
      # actually installed in the Nix sandbox ($out/lib) so the linker
      # can resolve it while building against libc and later consumers
      # such as binutils.  Without it, libc.so would reference
      # /ardos/lib/ld-linux-x86-64.so.2 which does not exist at build
      # time, breaking the cross-toolchain bootstrap.
      #
      # NOTE: sysconfdir is NOT overridden — it must stay as /etc
      # (the configure-time default) so the binary doesn't bake in a
      # nix store path for ld.so.cache.  common.nix's installFlags
      # handles the install destination.
      installRedirects = lib.optionals (runtimePrefix != null) [
        # All install destinations go to $out so everything writes
        # into the Nix sandbox.
        "libdir=$(out)/lib"
        "slibdir=$(out)/lib"
        # rtlddir = runtime loader path (self-id + PT_INTERP).
        "rtlddir=${runtimePrefix}/lib"
        # rtlddir-build = where the loader is installed at build time
        # (libc.so AS_NEEDED reference).  Defaults to rtlddir upstream.
        "rtlddir-build=$(out)/lib"
        # Configure-time cache variable for slibdir (build-time install
        # dir), kept in sync with slibdir above.
        "libc_cv_slibdir=$(out)/lib"
        # Runtime library search path for binaries (RPATH).
        "default-rpath=${runtimePrefix}/lib"

        # --- Runtime DATA search paths (compiled into libc / getconf) ---
        # Each is the DEFAULT lookup dir used at runtime in the ROM.  They
        # must point at the runtime prefix (/ardos), not the Nix store.
        # Each has an inst_* counterpart that redirects the install
        # destination back to $out so the build still installs into the
        # sandbox.  The base libdir/datadir below stay at $(out) because
        # several install rules (iconvdata, nss, login) use them directly
        # instead of the inst_* form; we override the specific
        # runtime-derived variables instead of the base dirs.
        "gconvdir=${runtimePrefix}/lib/gconv"
        "inst_gconvdir=$(out)/lib/gconv"
        "complocaledir=${runtimePrefix}/lib/locale"
        "inst_complocaledir=$(out)/lib/locale"
        "localedir=${runtimePrefix}/lib/locale"
        "inst_localedir=$(out)/lib/locale"
        "zonedir=${runtimePrefix}/share/zoneinfo"
        "inst_zonedir=$(out)/share/zoneinfo"
        "i18ndir=${runtimePrefix}/share/i18n"
        "inst_i18ndir=$(out)/share/i18n"
        # libexecdir is forced to a Nix store path by the nixpkgs
        # multi-output hook; redirect the COMPILED-IN default to /ardos
        # (getconf reads GETCONF_DIR from it) while keeping the install
        # destination at $out.
        "libexecdir=${runtimePrefix}/libexec"

        # inst_* redirect install destinations for libraries.
        # inst_includedir is NOT overridden: the nixpkgs multi-output
        # hook sets --includedir=$dev/include at configure time.
        "inst_libdir=$(out)/lib"
        "inst_slibdir=$(out)/lib"
        "inst_rtlddir=$(out)/lib"
        "inst_libexecdir=$(out)/libexec"
        # Base path variables used directly by nss/Makefile,
        # localedata/Makefile and other install targets.
        "datarootdir=$(out)/share"
        "datadir=$(out)/share"
        "localstatedir=$(out)/var"
        "sharedstatedir=$(out)/com"
        "mandir=$(out)/share/man"
        "infodir=$(out)/share/info"
      ];
    in {
      patches = finalPatches;
      configureFlags = (old.configureFlags or []) ++ prefixFlags;
      makeFlags = keptMakeFlags ++ installRedirects;
      installFlags = old.installFlags or [];
      postPatch = cleanedPostPatch;
      postInstall = old.postInstall or "";
    });
  }
