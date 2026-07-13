{
  buildPkgs,
}:
# OVMF firmware for UEFI boot.
# Uses the edk2-ovmf package from nixpkgs (patched, from Stage 0).
# Exposes OVMF_CODE.fd (read-only firmware) and OVMF_VARS.fd (writable vars).
buildPkgs.stdenvNoCC.mkDerivation {
  name = "ovmf-firmware";

  buildCommand = ''
    mkdir -p $out
    ln -s ${buildPkgs.OVMF.fd}/FV/OVMF_CODE.fd $out/OVMF_CODE.fd
    ln -s ${buildPkgs.OVMF.fd}/FV/OVMF_VARS.fd $out/OVMF_VARS.fd
  '';

  meta = {
    description = "OVMF UEFI firmware (Code + Vars)";
    platforms = buildPkgs.OVMF.fd.meta.platforms or buildPkgs.lib.platforms.x86_64;
  };
}
