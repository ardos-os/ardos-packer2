# Actual Ardos linker translation logic.
# Sourced indirectly via the stable stub in bintools.
# Changes to this file only rebuild Ardos target packages, NOT the toolchain.

if [[ -n "${ARDOS_RUNTIME_MAP:-}" && -f "$ARDOS_RUNTIME_MAP" ]]; then
  ardosTranslateLdArgs() {
    local -n translated_args_out="$1"
    shift

    local translated_args_file
    translated_args_file=$(mktemp -t ardos-ld-translate-XXXXXX)

    "$_ardos_translate" --map "$ARDOS_RUNTIME_MAP" "$@" > "$translated_args_file"
    local translate_status=$?
    if (( translate_status != 0 )); then
      rm -f "$translated_args_file"
      return "$translate_status"
    fi

    translated_args_out=()
    local item
    while IFS= read -r -d '' item; do
      translated_args_out+=("$item")
    done < "$translated_args_file"

    rm -f "$translated_args_file"
  }

  newParams=()
  ardosTranslateLdArgs newParams "${params[@]}"
  translate_status=$?
  if (( translate_status != 0 )); then
    echo "[Ardos Linker Hook] Failed to translate linker params" >&2
    return "$translate_status" 2>/dev/null || exit "$translate_status"
  fi
  params=("${newParams[@]}")

  newExtraAfter=()
  ardosTranslateLdArgs newExtraAfter "${extraAfter[@]}"
  translate_status=$?
  if (( translate_status != 0 )); then
    echo "[Ardos Linker Hook] Failed to translate linker extraAfter params" >&2
    return "$translate_status" 2>/dev/null || exit "$translate_status"
  fi
  extraAfter=("${newExtraAfter[@]}")
fi
