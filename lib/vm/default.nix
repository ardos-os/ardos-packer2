# ardos-packer2 VM module
#
# Provides derivations for running an Ardos OS VM:
#   - ovmf:       OVMF firmware (Code + Vars)
#   - launch:     QEMU launch script derivation
#
# kernel, initrd and limine live at the instance level (ardosPacker.kernel,
# ardosPacker.initrd, ardosPacker.limine) since they are also used by other
# modes (e.g. ISO).  The vm module receives them as arguments.
{
  buildPkgs,
  lib,
  crossPkgs,
  kernel,
  limine,
  nixgl ? null,
}: let
  ovmf        = import ./ovmf.nix { inherit buildPkgs; };
  launch      = import ./launch-script.nix { inherit buildPkgs lib; };
  nixGLDefault =
    if nixgl != null
    then nixgl.packages.${buildPkgs.system}.nixGLDefault
    else null;
in {
  inherit ovmf kernel limine;

  vmNixGL = nixGLDefault;

  launch = args: launch {
    nixGL = nixGLDefault;
    ovmf-code = args.ovmf-code or ovmf;
    ovmf-vars = args.ovmf-vars or ovmf;
    kernel-params = args.kernel-params or "";
    kernel = args.kernel or kernel;
    initrd = args.initrd;
    limine = args.limine or limine;
    rom = args.rom;
    system-disk-size = args.system-disk-size or "2G";
    user-disk-size = args.user-disk-size or "10G";
    smp = args.smp or "4";
    memory = args.memory or "4G";
  };
}
