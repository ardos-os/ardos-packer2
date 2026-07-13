{
  buildPkgs,
  lib,
}:
{
  ovmf-code,
  ovmf-vars,
  kernel-params ? "",
  system-disk-size ? "2G",
  user-disk-size ? "10G",
  memory ? "2G",
  smp ? "4",
  kernel,
  initrd,
  limine,
  rom,
}:
let 

  priv-setup  = import ./priv-setup.nix { inherit buildPkgs kernel initrd limine rom kernel-params; };
in
buildPkgs.writeShellApplication {
  name = "ardos-vm-run";

  runtimeInputs = with buildPkgs; [
    parted
    qemu
    util-linux
    dosfstools
    btrfs-progs
    kmod
    gnutar
    gzip
    gnugrep
    gnused
    gawk
    coreutils
    findutils
    libglvnd
  ];

  text = ''
    set -euo pipefail

    OVMF_CODE="${ovmf-code}/OVMF_CODE.fd"
    OVMF_VARS="${ovmf-vars}/OVMF_VARS.fd"

    MEMORY="''${MEMORY:-${memory}}"
    SMP="''${SMP:-${smp}}"
    SYSTEM_DISK="''${SYSTEM_DISK:-./build/vm/system.qcow2}"
    USER_DISK="''${USER_DISK:-./build/vm/user.qcow2}"
    SYSTEM_DISK_SIZE="''${SYSTEM_DISK_SIZE:-${system-disk-size}}"
    USER_DISK_SIZE="''${USER_DISK_SIZE:-${user-disk-size}}"
    SPICE_SOCK="''${SPICE_SOCK:-/tmp/ardos-spice.sock}"
    MNT="''${ARDOS_MNT:-/mnt/ardos-vm}"

    OVMF_VARS_COPY=$(mktemp /tmp/ardos-ovmf-vars.XXXXXX.fd)
    cp "$OVMF_VARS" "$OVMF_VARS_COPY"

    trap 'rm -f "$SPICE_SOCK" "$OVMF_VARS_COPY"' EXIT

    # --- Privileged setup ---
    echo "=== ardos-vm-run: privileged setup ==="
    sudo env "PATH=$PATH" "SYSTEM_DISK=$SYSTEM_DISK" "SYSTEM_DISK_SIZE=$SYSTEM_DISK_SIZE" "USER_DISK=$USER_DISK" "USER_DISK_SIZE=$USER_DISK_SIZE" "MNT=$MNT" "HOST_UID=$(id -u)" "HOST_GID=$(id -g)" "KERNEL_PARAMS=''${KERNEL_PARAMS:-${kernel-params}}" "${priv-setup}"

    # --- Launch QEMU (non-root) ---

    echo "=== ardos-vm-run: launching QEMU ==="
    echo "  Memory: $MEMORY"
    echo "  SMP:    $SMP"
    echo "  SPICE:  $SPICE_SOCK"

    rm -f "$SPICE_SOCK"


    VIEWER_PID=""
    if command -v remote-viewer &>/dev/null; then
      remote-viewer "spice+unix://$SPICE_SOCK" &
      VIEWER_PID=$!
    fi
    export LIBGL_DRIVERS_PATH="${buildPkgs.mesa}/lib/dri"
    export GBM_DRIVERS_PATH="${buildPkgs.mesa}/lib/gbm"
    export EGL_DRIVERS_PATH="${buildPkgs.mesa}/lib/egl"
    export LD_LIBRARY_PATH="${buildPkgs.mesa}/lib:''${LD_LIBRARY_PATH:-}"

    # shellcheck disable=SC2086
    qemu-system-x86_64 -enable-kvm -cpu host -smp "$SMP" -machine "type=pc-q35-11.0,accel=kvm,memory-backend=pc.ram,usb=off,vmport=off,smm=on,hpet=off,acpi=on" -object "memory-backend-ram,id=pc.ram,size=$MEMORY" -vga none -device virtio-vga-gl,max_outputs=1 -display none -spice "unix=on,addr=$SPICE_SOCK,disable-ticketing=on,image-compression=off,gl=on" -device virtio-net-pci,netdev=net0 -netdev user,id=net0 -drive "if=virtio,file=$SYSTEM_DISK,format=qcow2" -drive "if=virtio,file=$USER_DISK,format=qcow2" -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$OVMF_VARS_COPY" -serial stdio -boot d

    QEMU_EXIT=$?

    if [ -n "$VIEWER_PID" ]; then
      kill "$VIEWER_PID" 2>/dev/null || true
    fi

    echo "=== ardos-vm-run: QEMU exited with code $QEMU_EXIT ==="
    exit $QEMU_EXIT
  '';

  meta = {
    description = "Ardos OS VM runner — builds system disk and launches QEMU";
    platforms = lib.platforms.x86_64;
  };
}
