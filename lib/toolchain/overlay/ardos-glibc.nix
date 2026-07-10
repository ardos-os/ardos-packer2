# Core glibc overlay — strips Nix runtime artifacts from nixpkgs glibc.
#
# Produces a minimal, distro-style glibc with no embedded /nix/store paths,
# no NixOS search paths, and no NSS/locale plugins. Plugins are added
# declaratively via glibcPlugins at the sysroot level.
#
# The overlay is layout-agnostic: runtimePrefix controls the compiled-in
# PREFIX for ld.so.cache/ld.so.conf resolution, but does not dictate
# where files are placed — that is the caller's responsibility.
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

    # --- makeFlags ---
    # Remove user-defined-trusted-dirs (embeds libgcc nix store path).
    keptMakeFlags = lib.filter (f:
      !(builtins.isString f && lib.hasPrefix "user-defined-trusted-dirs=" f)
    ) (old.makeFlags or []);

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
    prefixFlag = lib.optional (runtimePrefix != null)
      "--prefix=${runtimePrefix}";

  in {
    patches = finalPatches;
    configureFlags = (old.configureFlags or []) ++ prefixFlag;
    makeFlags = keptMakeFlags;
    # When --prefix=/ardos is set, glibc's shared library install uses
    # inst_slibdir = $(install_root)$(slibdir) where slibdir = $(prefix)/lib
    # = /ardos/lib. Without install_root, this resolves to /ardos/lib which
    # doesn't exist in the Nix sandbox. Setting install_root=$out redirects
    # to $out/ardos/lib. Unlike DESTDIR, install_root only affects glibc's
    # inst_* prefixed paths — the direct $(libdir) from nixpkgs ($out/lib)
    # is untouched, so static library installs and glibc-nolibgcc work fine.
    installFlags = (old.installFlags or [])
      ++ lib.optional (runtimePrefix != null) "install_root=$out";
    postPatch = cleanedPostPatch;
  });

  # glibc-nolibgcc is derived from glibc in nixpkgs' fixed point, so it
  # inherits our --prefix and install_root overrides.  The combination of
  # install_root=$out with nixpkgs' absolute libdir paths creates double-
  # nested store paths (inst_libdir = $out + /nix/store/xxx/lib).  Pin
  # glibc-nolibgcc to the pre-overlay version to avoid this.
  glibc-nolibgcc = prev.glibc-nolibgcc;
}
