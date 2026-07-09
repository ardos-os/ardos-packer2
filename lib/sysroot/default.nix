{
  buildPkgs,
  externalMappings ? [],
}: let
  lib = buildPkgs.lib;

  mappingScriptToLayout = mapping: ''
    echo "# ardos-external-mapping ${mapping.drv}" >> "$out"
    stage=$(mktemp -d -t ardos-external-layout-XXXXXX)
    (
      out=${mapping.drv} stage=$stage bash -c ${lib.escapeShellArg mapping.runtimeLayoutScript}

      while IFS= read -r -d $'\0' entry; do
        rel="''${entry#$stage/}"
        [ "$rel" = "$entry" ] && continue

        target="/$rel"
        if [ -L "$entry" ]; then
          pointed=$(readlink -f -- "$entry" 2>/dev/null || true)
          if [ -n "$pointed" ] && [[ "$pointed" == "${mapping.drv}"/* ]]; then
            src_rel="''${pointed#${mapping.drv}/}"
          else
            src_rel=$(readlink -- "$entry")
          fi
        elif [ -f "$entry" ]; then
          echo "error: runtimeLayoutScript for ${mapping.drv} created a concrete file in ardos-layout: $entry" >&2
          exit 1
        else
          continue
        fi

        printf '%s -> %s\n' "$src_rel" "$target" >> "$out"
      done < <(find "$stage" -mindepth 1 -print0)
    )
    rm -rf "$stage"
  '';

  externalMappingsFile =
    if externalMappings == []
    then null
    else
      buildPkgs.runCommand "ardos-external-runtime-mappings" {
        nativeBuildInputs = [buildPkgs.coreutils buildPkgs.findutils buildPkgs.bash];
      } ''
        : > "$out"
        ${lib.concatMapStringsSep "\n" mappingScriptToLayout externalMappings}
      '';
in {
  mkSysroot = {
    includePackages,
    name ? "ardos-sysroot",
  }: let
    closure = buildPkgs.closureInfo {rootPaths = includePackages;};
  in
    buildPkgs.runCommand name {
      nativeBuildInputs = [
        buildPkgs.coreutils
        buildPkgs.findutils
      ];
    } ''
      mkdir -p "$out"

      copy_mapping() {
        src_path="$1"
        dest_path="$2"

        if [ ! -e "$src_path" ] && [ ! -L "$src_path" ]; then
          echo "error: broken Ardos runtime mapping: $src_path -> ''${dest_path#$out}" >&2
          exit 1
        fi

        # Runtime mappings are represented by a symlink tree. Resolve exactly
        # one symlink level: a link to a directory copies that directory's
        # contents, a link to a file copies the file, and a link to another
        # symlink copies that second symlink verbatim.
        copy_source="$src_path"
        if [ -L "$src_path" ]; then
          link_target=$(readlink -- "$src_path")
          case "$link_target" in
            /*) resolved="$link_target" ;;
            *) resolved="$(dirname "$src_path")/$link_target" ;;
          esac

          if [ ! -e "$resolved" ] && [ ! -L "$resolved" ]; then
            echo "error: broken Ardos runtime mapping symlink: $src_path -> $link_target" >&2
            exit 1
          fi

          copy_source="$resolved"
        fi

        if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
          echo "error: duplicate Ardos runtime path: ''${dest_path#$out}" >&2
          exit 1
        fi

        mkdir -p "$(dirname "$dest_path")"
        if [ -d "$copy_source" ] && [ ! -L "$copy_source" ]; then
          mkdir -p "$dest_path"
          cp -a --no-preserve=ownership "$copy_source"/. "$dest_path"/
        else
          cp -a --no-preserve=ownership "$copy_source" "$dest_path"
        fi
      }

      apply_layout() {
        store_path="$1"
        layout="$2"

        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in ""|\#*) continue ;; esac

          src_rel="''${line%% -> *}"
          dest_abs="''${line#* -> }"
          case "$src_rel" in
            /*) src_path="$src_rel" ;;
            *) src_path="$store_path/$src_rel" ;;
          esac
          dest_path="$out/''${dest_abs#/}"

          copy_mapping "$src_path" "$dest_path"
        done < "$layout"
      }

      while IFS= read -r store_path; do
        layout="$store_path/nix-support/ardos-layout"
        [ -f "$layout" ] || continue
        apply_layout "$store_path" "$layout"
      done < ${closure}/store-paths

      ${lib.optionalString (externalMappingsFile != null) ''
        active_base=""
        active_applies=0
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            "# ardos-external-mapping "*)
              active_base="''${line#\# ardos-external-mapping }"
              if grep -Fxq "$active_base" ${closure}/store-paths; then
                active_applies=1
              else
                active_applies=0
              fi
              continue
              ;;
          esac

          [ "$active_applies" = 1 ] || continue
          [ -n "$active_base" ] || continue
          case "$line" in ""|\#*) continue ;; esac

          tmp_layout=$(mktemp)
          printf '%s\n' "$line" > "$tmp_layout"
          apply_layout "$active_base" "$tmp_layout"
          rm -f "$tmp_layout"
        done < ${externalMappingsFile}
      ''}
    '';
}
