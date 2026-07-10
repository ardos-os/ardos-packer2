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
    # Nixpkgs glibc already sets install_root=$(out) in its own installFlags.
    # Combined with --prefix=/ardos this produces the correct install path
    # $out/ardos/lib. We must NOT add DESTDIR=$out here because
    # glibc-nolibgcc (glibc.overrideAttrs in nixpkgs) inherits our flags,
    # and DESTDIR prepended to the already-absolute libdir/bindir paths
    # creates double-nested store paths that break the install phase.
    postPatch = cleanedPostPatch;
  });
}
