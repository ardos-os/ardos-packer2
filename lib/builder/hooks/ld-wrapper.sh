# Stable stub sourced by Nixpkgs ld-wrapper.sh.
# Delegates to the actual Ardos translation hook if ARDOS_LD_HOOK is set.
# This file should NEVER change after initial deployment to avoid toolchain rebuilds.

if [[ -n "${ARDOS_LD_HOOK:-}" && -f "${ARDOS_LD_HOOK}" ]]; then
  source "${ARDOS_LD_HOOK}"
fi
