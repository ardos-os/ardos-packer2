# Actual Ardos linker translation logic.
# Sourced indirectly via the stable stub in bintools.
# Changes to this file only rebuild Ardos target packages, NOT the toolchain.

if [[ -n "${ARDOS_RUNTIME_MAP:-}" && -f "$ARDOS_RUNTIME_MAP" ]]; then
  newParams=()
  while IFS= read -r -d '' item; do
    newParams+=("$item")
  done < <("$_ardos_translate" --map "$ARDOS_RUNTIME_MAP" "${params[@]}")
  params=("${newParams[@]}")

  newExtraAfter=()
  while IFS= read -r -d '' item; do
    newExtraAfter+=("$item")
  done < <("$_ardos_translate" --map "$ARDOS_RUNTIME_MAP" "${extraAfter[@]}")
  extraAfter=("${newExtraAfter[@]}")
fi
