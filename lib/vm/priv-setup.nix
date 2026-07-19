{
  buildPkgs,
  kernel,
  initrd,
  limine,
  rom,
  kernel-params ? "",
  targetCpu ? "x86_64",
}:

let
  efiBinaryName = {
    x86_64  = "BOOTX64.EFI";
    aarch64 = "BOOTAA64.EFI";
  }.${targetCpu}
    or (throw "priv-setup.nix: unsupported target CPU ${targetCpu}");
in
buildPkgs.writeShellScript "ardos-vm-priv-setup" ''
  set -xeuo pipefail

  # Baked at build time
  KERNEL="${kernel}/bzImage"
  INITRD="${initrd}/initrd.img"
  LIMINE="${limine}/${efiBinaryName}"
  ROM="${rom}"

  # Passed via environment by ardos-vm-run
  MNT="''${MNT:-/mnt/ardos-vm}"
  SYSTEM_DISK="''${SYSTEM_DISK}"
  SYSTEM_DISK_SIZE="''${SYSTEM_DISK_SIZE:-2G}"
  USER_DISK="''${USER_DISK}"
  USER_DISK_SIZE="''${USER_DISK_SIZE:-10G}"
  HOST_UID="''${HOST_UID}"
  HOST_GID="''${HOST_GID}"
  EXTRA_KERNEL_PARAMS="''${KERNEL_PARAMS:-${kernel-params}}"

  # Clean up any stale connections
  qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
  qemu-nbd --disconnect /dev/nbd1 2>/dev/null || true
  umount "$MNT" 2>/dev/null || true
  modprobe -r nbd 2>/dev/null || true
  sleep 0.1
  modprobe nbd max_part=8

  # --- System disk ---
  mkdir -p "$(dirname "$SYSTEM_DISK")"
  qemu-img create -f qcow2 "$SYSTEM_DISK" "$SYSTEM_DISK_SIZE"

  qemu-nbd --connect /dev/nbd0 "$SYSTEM_DISK"
  sleep 0.2

  parted -s /dev/nbd0 mklabel gpt
  parted -s /dev/nbd0 mkpart EFI fat32 1MiB 300MiB
  parted -s /dev/nbd0 set 1 esp on
  parted -s /dev/nbd0 mkpart SYSTEM btrfs 300MiB 100%
  sleep 0.2

  mkfs.vfat -F32 /dev/nbd0p1
  mkfs.btrfs -f /dev/nbd0p2

  SYSTEM_PARTUUID=$(blkid -s PARTUUID -o value /dev/nbd0p2)

  mkdir -p "$MNT"
  mount /dev/nbd0p1 "$MNT"
  mkdir -p "$MNT/EFI/BOOT"
  cp "$KERNEL" "$MNT/vmlinuz"
  cp "$INITRD" "$MNT/initramfs.img"
  cp "$LIMINE" "$MNT/EFI/BOOT/${efiBinaryName}"

  USER_PARTUUID=$(blkid -s PARTUUID -o value /dev/nbd1p1 2>/dev/null || echo "")
  if [ -n "$USER_PARTUUID" ]; then
    USER_LINE="user_partition=UUID=$USER_PARTUUID"
  else
    USER_LINE=""
  fi

  cat > "$MNT/limine.conf" << LIMINEEOF
  timeout: 0
  /Ardos
      protocol: linux
      path: boot():/vmlinuz
      cmdline: console=ttyS0 system_partition=UUID=$SYSTEM_PARTUUID $USER_LINE $EXTRA_KERNEL_PARAMS
      module_path: boot():/initramfs.img
  LIMINEEOF

  umount "$MNT"

  mount /dev/nbd0p2 "$MNT"
  cp "$ROM" "$MNT/system.squashfs"
  umount "$MNT"

  qemu-nbd --disconnect /dev/nbd0
  sleep 0.2

  # --- User disk ---
  if [ ! -f "$USER_DISK" ]; then
    qemu-img create -f qcow2 "$USER_DISK" "$USER_DISK_SIZE"
    qemu-nbd --connect /dev/nbd1 "$USER_DISK"
    sleep 0.2
    parted -s /dev/nbd1 mklabel gpt
    parted -s /dev/nbd1 mkpart primary btrfs 0% 100%
    mkfs.btrfs -f /dev/nbd1p1
    qemu-nbd --disconnect /dev/nbd1
    sleep 0.2
  fi

  # Hand ownership back to the calling user so QEMU (non-root) can access
  chown "$HOST_UID:$HOST_GID" "$SYSTEM_DISK" "$USER_DISK"
''
