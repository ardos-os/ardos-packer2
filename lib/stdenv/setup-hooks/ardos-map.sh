# setup hook to aggregate ardos-layout files into a single map file
# and translate shebangs during the post-fixup phase.

# 1. Automatically generate a default layout mapping if the package hasn't declared one
ardosGenerateDefaultLayout() {
  # If the layout metadata file already exists (custom mapping), don't overwrite it
  if [ -f "$out/nix-support/ardos-layout" ]; then
    if (( "${NIX_DEBUG:-0}" >= 1 )); then
      echo "[Ardos Layout] Using existing custom layout metadata in $out" >&2
    fi
    return
  fi

  mkdir -p "$out/nix-support"
  touch "$out/nix-support/ardos-layout"

  if (( "${NIX_DEBUG:-0}" >= 1 )); then
    echo "[Ardos Layout] Generating default layout mapping for $out" >&2
  fi

  # Map bin directory (default: /ardos/bin/<name>)
  if [ -d "$out/bin" ]; then
    find "$out/bin" -type f -o -type l | while read -r f; do
      relPath="bin/$(basename "$f")"
      echo "$relPath -> /ardos/bin/$(basename "$f")" >> "$out/nix-support/ardos-layout"
    done
  fi

  # Map sbin directory (default: /ardos/bin/<name>)
  if [ -d "$out/sbin" ]; then
    find "$out/sbin" -type f -o -type l | while read -r f; do
      relPath="sbin/$(basename "$f")"
      echo "$relPath -> /ardos/bin/$(basename "$f")" >> "$out/nix-support/ardos-layout"
    done
  fi

  # Map lib directory (only shared libraries, default: /ardos/lib/<name>)
  if [ -d "$out/lib" ]; then
    find "$out/lib" -maxdepth 1 \( -type f -o -type l \) -name "*.so*" | while read -r f; do
      relPath="lib/$(basename "$f")"
      echo "$relPath -> /ardos/lib/$(basename "$f")" >> "$out/nix-support/ardos-layout"
    done
  fi
}

ardosSetupHook() {
  # Generate a temporary file for the translation map
  export ARDOS_RUNTIME_MAP=$(mktemp "${TMPDIR:-/tmp}/ardos-runtime-map.XXXXXX")
  
  if (( "${NIX_DEBUG:-0}" >= 1 )); then
    echo "[Ardos Setup] Generating translation map at $ARDOS_RUNTIME_MAP" >&2
  fi
  
  # Add current package's own layout mapping if declared in environment
  if [[ -n "${ardosLayoutMetadata:-}" ]]; then
    if (( "${NIX_DEBUG:-0}" >= 1 )); then
      echo "[Ardos Setup] Adding current package layout metadata" >&2
    fi
    while read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^# ]] && continue
      [[ -z "$line" ]] && continue
      
      srcPath="$out/${line%% -> *}"
      destPath="${line#* -> }"
      srcDir=$(dirname "$srcPath")
      destDir=$(dirname "$destPath")
      
      echo "$srcDir -> $destDir" >> "$ARDOS_RUNTIME_MAP"
    done <<< "$ardosLayoutMetadata"
  fi
  
  # Iterate over all dependencies in buildInputs and propagatedBuildInputs
  for dep in $buildInputs $propagatedBuildInputs; do
    if [ -f "$dep/nix-support/ardos-layout" ]; then
      if (( "${NIX_DEBUG:-0}" >= 1 )); then
        echo "[Ardos Setup] Found layout metadata for $dep" >&2
      fi
      while read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        
        srcPath="$dep/${line%% -> *}"
        destPath="${line#* -> }"
        srcDir=$(dirname "$srcPath")
        destDir=$(dirname "$destPath")
        
        echo "$srcDir -> $destDir" >> "$ARDOS_RUNTIME_MAP"
      done < "$dep/nix-support/ardos-layout"
    fi
  done
}

ardosTranslateShebangs() {
  if [[ -z "${ARDOS_RUNTIME_MAP:-}" || ! -f "$ARDOS_RUNTIME_MAP" ]]; then
    return
  fi
  
  echo "[Ardos Fixup] Translating script shebangs in $out..." >&2
  
  # Load the mapping into memory
  declare -A shebangMap
  while read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^# ]] && continue
    [[ -z "$line" ]] && continue
    nixPath="${line%% -> *}"
    ardosPath="${line#* -> }"
    
    # Strip leading/trailing whitespace in pure Bash
    nixPath="${nixPath#"${nixPath%%[![:space:]]*}"}"
    nixPath="${nixPath%"${nixPath##*[![:space:]]}"}"
    ardosPath="${ardosPath#"${ardosPath%%[![:space:]]*}"}"
    ardosPath="${ardosPath%"${ardosPath##*[![:space:]]}"}"
    
    shebangMap["$nixPath"]="$ardosPath"
  done < "$ARDOS_RUNTIME_MAP"

  # Find all files in $out
  find "$out" -type f | while read -r f; do
    # Read the first line of the file to check for shebang
    firstLine=$(head -n 1 "$f" 2>/dev/null || true)
    if [[ "$firstLine" =~ ^#\! ]]; then
      # Extract interpreter path and optional arguments
      interpreter="${firstLine#\#!}"
      
      # Strip leading/trailing whitespace in pure Bash
      interpreter="${interpreter#"${interpreter%%[![:space:]]*}"}"
      interpreter="${interpreter%"${interpreter##*[![:space:]]}"}"
      
      interpreterPath="${interpreter%% *}"
      interpreterArgs="${interpreter#$interpreterPath}"
      
      if [[ "$interpreterPath" == /nix/store/* ]]; then
        cleanPath=$(realpath -s "$interpreterPath" 2>/dev/null || echo "$interpreterPath")
        cleanDir=$(dirname "$cleanPath")
        baseName=$(basename "$cleanPath")
        
        if [[ -n "${shebangMap[$cleanDir]:-}" ]]; then
          translatedDir="${shebangMap[$cleanDir]}"
          translatedInterpreter="$translatedDir/$baseName"
          
          echo "[Ardos Fixup] Translating shebang in $f: $interpreterPath -> $translatedInterpreter" >&2
          sed -i "1s|^#\!.*|#\!$translatedInterpreter$interpreterArgs|" "$f"
        else
          # Warn if we find a Nix store interpreter that isn't mapped
          echo "[Ardos Fixup] WARNING: No Ardos mapping found for interpreter path: $interpreterPath in $f" >&2
        fi
      fi
    fi
  done
}

preFixupHooks+=(ardosGenerateDefaultLayout)
postHooks+=(ardosSetupHook)
postFixupHooks+=(ardosTranslateShebangs)
