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
{lib}: {
  glibc,
  runtimePrefix ? null,
}:

final: prev:

let
  isTarget = prev.stdenv.hostPlatform.config == prev.stdenv.targetPlatform.config;

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

if !isTarget then {} else {

  glibc = glibc.overrideAttrs (old: let
    # --- Patch filtering ---
    finalPatches = lib.filter (p:
      !builtins.elem (patchName p) nixPatchNames
    ) (old.patches or []);

    # --- makeFlags filtering ---
    # Remove flags that embed Nix store paths into compiled binaries.
    # Flatten nested lists first — makeFlags can contain `listOf (either str (list str))`.
    keptMakeFlags = let
      flatFlags = lib.concatMap (f:
        if builtins.isList f then f else [f]
      ) (old.makeFlags or []);
    in lib.filter (f:
      !(lib.hasPrefix "user-defined-trusted-dirs=" f
        || lib.hasPrefix "BUILD_LDFLAGS=" f)
    ) flatFlags;

    # --- postPatch ---
    # Remove the LIBIDN2_SONAME substitution that bakes a store path into
    # inet/idna.c.  Without the substitution the upstream default
    # "libidn2.so.0" is used, resolved by standard dlopen at runtime.
    cleanedPostPatch =
      let
        raw = old.postPatch or "";
        lines = lib.splitString "\n" raw;
        filtered = lib.filter (line:
          !(lib.hasInfix "LIBIDN2_SONAME" line && lib.hasInfix "/nix/store" line)
        ) lines;
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
    # slibdir and rtlddir use $out/lib (not the runtime prefix) because
    # they control the content of the libc.so LINKER SCRIPT, which is
    # consumed by ld at link time, not by the dynamic linker at runtime.
    # The paths in libc.so must be valid during the build.  Runtime
    # library search paths are handled by default-rpath and the
    # external runtime mappings in the sysroot.
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
      "rtlddir=${runtimePrefix}/lib"
      # Runtime library search path for binaries (RPATH).
      "default-rpath=${runtimePrefix}/lib"
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
      "localedir=$(out)/lib/locale"
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
