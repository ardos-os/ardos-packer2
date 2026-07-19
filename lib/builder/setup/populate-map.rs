use std::collections::BTreeSet;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

fn dedup_push(mappings: &mut Vec<(String, String)>, key: String, value: String) {
    mappings.retain(|(k, _)| k != &key);
    mappings.push((key, value));
}

/// Validate the raw source and target of a layout line.
/// Source must be relative; target must be absolute.
fn validate_layout_pair(src_rel: &str, dest: &str) -> io::Result<()> {
    if src_rel.starts_with('/') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("layout source must be relative, got absolute path: {src_rel}"),
        ));
    }
    if !dest.starts_with('/') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("layout target must be absolute, got relative path: {dest}"),
        ));
    }
    Ok(())
}

/// Resolve a layout source relative to `base_dir` into an absolute path
/// suitable for the runtime map.  A source of `"."` or `"./"` means the
/// package root itself and resolves to `base_dir/` (folder mapping).
fn resolve_source(base_dir: &str, src_rel: &str) -> String {
    if src_rel == "." || src_rel == "./" {
        format!("{base_dir}/")
    } else {
        Path::new(base_dir).join(src_rel).display().to_string()
    }
}

fn is_debug() -> bool {
    env::var("NIX_DEBUG")
        .unwrap_or_default()
        .parse::<i32>()
        .unwrap_or(0)
        >= 1
}

// Pull every distinct /nix/store/* output path out of a whitespace-separated
// string of NIX-style flags. Paths often appear as -L/nix/store/.../lib or
// -I/nix/store/.../include; normalize them back to the store output root so
// they can match nix-support metadata and external mapping section headers.
fn collect_store_paths(s: &str) -> BTreeSet<PathBuf> {
    let mut out = BTreeSet::new();
    // We tokenize on whitespace, but a path may contain trailing/leading
    // punctuation. The robust trick: scan for `/nix/store/<hash>-` prefixes
    // and extend to the next whitespace.
    let bytes = s.as_bytes();
    let needle = b"/nix/store/";
    let mut i = 0;
    while i + needle.len() < bytes.len() {
        if &bytes[i..i + needle.len()] == needle {
            // Find end of path
            let mut j = i + needle.len();
            while j < bytes.len() && !bytes[j].is_ascii_whitespace() {
                j += 1;
            }
            let p = std::str::from_utf8(&bytes[i..j]).unwrap_or("");
            // Truncate at any trailing punctuation that would not be part
            // of a real path (closing quotes, commas).
            let p = p.trim_end_matches(|c: char| matches!(c, '\'' | '"' | ',' | ';' | ')' | ']'));
            if p.starts_with("/nix/store/") && p.len() > "/nix/store/".len() + 1 {
                let rest = &p["/nix/store/".len()..];
                let store_component = rest.split('/').next().unwrap_or(rest);
                out.insert(PathBuf::from(format!("/nix/store/{store_component}")));
            }
            i = j;
        } else {
            i += 1;
        }
    }
    out
}

fn main() -> io::Result<()> {
    let runtime_map_env = match env::var("ARDOS_RUNTIME_MAP") {
        Ok(v) if !v.is_empty() => v,
        _ => return Ok(()),
    };
    let runtime_map_path = Path::new(&runtime_map_env);
    let out = env::var("out").unwrap_or_default();
    let mut map_file = OpenOptions::new().append(true).open(runtime_map_path)?;

    // Collect all layout mappings in a Vec, preserving insertion order.
    // When two entries map the same source path, the later one wins
    // (last-wins semantics: remove the old entry, append the new one).
    let mut mappings: Vec<(String, String)> = Vec::new();

    // Process a single layout line and collect it into the mappings vec.
    // Lines are raw entries like "lib/ -> /ardos/lib/" or "lib/foo.so -> /ardos/lib/foo.so".
    // Folder mappings (trailing /) are preserved as-is — the ld translator
    // expands them on-the-fly via longest-prefix matching.
    let mut process_layout_line = |line: &str, base_dir: &str| -> io::Result<()> {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            return Ok(());
        }
        if let Some((src_rel, dest_path)) = trimmed.split_once(" -> ") {
            let src_rel = src_rel.trim();
            let dest_raw = dest_path.trim();

            validate_layout_pair(src_rel, dest_raw)?;

            let src_path = resolve_source(base_dir, src_rel);
            let dest_path = Path::new(dest_raw);
            dedup_push(
                &mut mappings,
                src_path,
                dest_path.display().to_string(),
            );
        }
        Ok(())
    };

    // 1. The current package's own layout, passed via env var.
    //    This is set by mkArdosDerivation to the raw runtimeLayout content.
    //    Folder mappings are preserved as-is — the ld translator expands them
    //    on-the-fly via longest-prefix matching at link time.
    //    This enables self-dependency: a package's bin/ can link against its
    //    own lib/ because the folder mapping is in the runtime map before the
    //    linker runs.
    if let Ok(layout) = env::var("ARDOS_CURRENT_PACKAGE_LAYOUT") {
        if !layout.is_empty() {
            if is_debug() {
                eprintln!("[Ardos Setup] Adding current package layout from ARDOS_CURRENT_PACKAGE_LAYOUT");
            }
            for line in layout.lines() {
                process_layout_line(line, &out)?;
            }
        }
    }

    // 2. Every store path the package can see at link time. stdenv has
    //    already aggregated them into NIX_LDFLAGS / NIX_CFLAGS_COMPILE /
    //    NIX_BINTOOLS / NIX_CC (and the *_FOR_BUILD / *_FOR_TARGET
    //    variants). Each of those contains absolute /nix/store/* paths
    //    and -L/-I/-rpath pointers into them.
    let mut store_paths: BTreeSet<PathBuf> = BTreeSet::new();
    for v in [
        "NIX_LDFLAGS",
        "NIX_LDFLAGS_BEFORE",
        "NIX_LDFLAGS_AFTER",
        "NIX_CFLAGS_COMPILE",
        "NIX_CFLAGS_LINK",
        "NIX_HARDENING_ENABLE", // contains no paths but harmless
        "NIX_CC",
        "NIX_BINTOOLS",
        "NIX_CC_FOR_BUILD",
        "NIX_BINTOOLS_FOR_BUILD",
        "NIX_CC_FOR_TARGET",
        "NIX_BINTOOLS_FOR_TARGET",
    ] {
        if let Ok(val) = env::var(v) {
            for p in collect_store_paths(&val) {
                store_paths.insert(p);
            }
        }
    }
    // 3. The explicit inputs the mkDerivation caller provided (rarely set
    //    in a hook context, but harmless to try).
    for v in [
        "buildInputs",
        "nativeBuildInputs",
        "propagatedBuildInputs",
        "hostInputs",
        "targetInputs",
        "NIX_BUILD_INPUTS",
        "NIX_HOST_BUILD_INPUTS",
        "NIX_TARGET_BUILD_INPUTS",
        "NIX_PROPAGATED_BUILD_INPUTS",
        "NIX_HOST_PROPAGATED_BUILD_INPUTS",
        "NIX_TARGET_PROPAGATED_BUILD_INPUTS",
    ] {
        if let Ok(val) = env::var(v) {
            for p in collect_store_paths(&val) {
                store_paths.insert(p);
            }
        }
    }

    eprintln!(
        "[Ardos Setup] populate-map: found {} unique store paths to scan",
        store_paths.len()
    );

    // Also follow propagated-build-inputs and direct nix-store references
    // of each discovered path. This is what reaches glibc and libgcc when
    // the caller only knows about the cross toolchain wrapper.
    let mut visited: BTreeSet<PathBuf> = store_paths.clone();
    let mut queue: Vec<PathBuf> = store_paths.iter().cloned().collect();
    while let Some(p) = queue.pop() {
        // propagated-build-inputs
        let pbi = p.join("nix-support/propagated-build-inputs");
        if pbi.is_file() {
            if let Ok(s) = fs::read_to_string(&pbi) {
                for line in s.lines() {
                    let line = line.trim();
                    if line.is_empty() || line.starts_with('#') {
                        continue;
                    }
                    let q = PathBuf::from(line);
                    if visited.insert(q.clone()) {
                        queue.push(q);
                    }
                }
            }
        }

        // Toolchain wrappers often hide their real target libraries in small
        // nix-support metadata files (for example cc-ldflags containing
        // -L/nix/store/...-glibc/lib). Scan those files too; otherwise libc
        // and compiler runtime mappings may never be considered even though
        // the eventual linker invocation receives them from the wrapper.
        let nix_support = p.join("nix-support");
        if let Ok(entries) = fs::read_dir(&nix_support) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_file() {
                    continue;
                }
                if let Ok(s) = fs::read_to_string(&path) {
                    for q in collect_store_paths(&s) {
                        if visited.insert(q.clone()) {
                            queue.push(q);
                        }
                    }
                }
            }
        }
    }
    eprintln!(
        "[Ardos Setup] populate-map: closure-walk found {} total store paths",
        visited.len()
    );

    // 4. For each store path, check for a nix-support/ardos-layout. If
    //    present, splice every "<rel> -> <abs>" line into our runtime map.
    let mut layouts_seen = 0usize;
    for p in &visited {
        let layout_file = p.join("nix-support/ardos-layout");
        if layout_file.is_file() {
            layouts_seen += 1;
            if is_debug() {
                eprintln!("[Ardos Setup] Found layout metadata for {}", p.display());
            }
            let file = File::open(&layout_file)?;
            let reader = BufReader::new(file);
            for line in reader.lines() {
                process_layout_line(&line?, p.to_str().unwrap_or(""))?;
            }
        }
    }

    // 5. Finally, splice externally supplied layouts for dependencies that do
    //    not carry nix-support/ardos-layout themselves (for example packages
    //    coming straight from nixpkgs). The file is sectioned by base store path:
    //
    //      # ardos-external-mapping /nix/store/...
    //      lib/libfoo.so -> /ardos/lib/libfoo.so
    //
    //    A section only applies if that base store path is in the discovered
    //    link-time closure, so adding global external mappings does not inject
    //    unused runtime paths into unrelated builds.
    let mut external_layouts_seen = 0usize;
    if let Ok(external_mappings) = env::var("ARDOS_EXTERNAL_MAPPINGS") {
        if !external_mappings.is_empty() {
            let external_path = Path::new(&external_mappings);
            if external_path.is_file() {
                if is_debug() {
                    eprintln!(
                        "[Ardos Setup] Reading external runtime mappings from {}",
                        external_path.display()
                    );
                }

                let file = File::open(external_path)?;
                let reader = BufReader::new(file);
                let mut active_base: Option<PathBuf> = None;
                let mut active_applies = false;

                for line in reader.lines() {
                    let line = line?;
                    let trimmed = line.trim();

                    if let Some(base) = trimmed.strip_prefix("# ardos-external-mapping ") {
                        let base_path = PathBuf::from(base.trim());
                        active_applies = visited.contains(&base_path);
                        active_base = Some(base_path);
                        if active_applies {
                            external_layouts_seen += 1;
                            if is_debug() {
                                eprintln!(
                                    "[Ardos Setup] Applying external layout for {}",
                                    base.trim()
                                );
                            }
                        }
                        continue;
                    }

                    if active_applies {
                        if let Some(base) = active_base.as_ref() {
                            process_layout_line(
                                trimmed,
                                base.to_str().unwrap_or(""),
                            )?;
                        }
                    }
                }
            }
        }
    }

    for (src, dest) in &mappings {
        writeln!(map_file, "{src} -> {dest}")?;
    }

    eprintln!("[Ardos Setup] populate-map: ingested ardos-layout from {layouts_seen} dependencies and {external_layouts_seen} external mappings ({} unique mappings written)", mappings.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dedup_push_new_entry() {
        let mut m: Vec<(String, String)> = Vec::new();
        dedup_push(&mut m, "a".into(), "1".into());
        assert_eq!(m, vec![("a".into(), "1".into())]);
    }

    #[test]
    fn dedup_push_overwrites_existing() {
        let mut m: Vec<(String, String)> = Vec::new();
        dedup_push(&mut m, "a".into(), "1".into());
        dedup_push(&mut m, "a".into(), "2".into());
        assert_eq!(m, vec![("a".into(), "2".into())]);
    }

    #[test]
    fn dedup_push_preserves_order_for_different_keys() {
        let mut m: Vec<(String, String)> = Vec::new();
        dedup_push(&mut m, "a".into(), "1".into());
        dedup_push(&mut m, "b".into(), "2".into());
        dedup_push(&mut m, "c".into(), "3".into());
        assert_eq!(
            m,
            vec![
                ("a".into(), "1".into()),
                ("b".into(), "2".into()),
                ("c".into(), "3".into()),
            ]
        );
    }

    #[test]
    fn dedup_push_last_wins_among_duplicates() {
        let mut m: Vec<(String, String)> = Vec::new();
        dedup_push(&mut m, "a".into(), "first".into());
        dedup_push(&mut m, "b".into(), "other".into());
        dedup_push(&mut m, "a".into(), "second".into());
        dedup_push(&mut m, "a".into(), "third".into());
        assert_eq!(
            m,
            vec![
                ("b".into(), "other".into()),
                ("a".into(), "third".into()),
            ]
        );
    }

    #[test]
    fn resolve_source_dot_slash() {
        assert_eq!(resolve_source("/nix/store/abc-pkg", "./"), "/nix/store/abc-pkg/");
    }

    #[test]
    fn resolve_source_dot() {
        assert_eq!(resolve_source("/nix/store/abc-pkg", "."), "/nix/store/abc-pkg/");
    }

    #[test]
    fn resolve_source_lib_slash() {
        assert_eq!(
            resolve_source("/nix/store/abc-pkg", "lib/"),
            "/nix/store/abc-pkg/lib/"
        );
    }

    #[test]
    fn resolve_source_nested_path() {
        assert_eq!(
            resolve_source("/nix/store/abc-pkg", "share/glvnd"),
            "/nix/store/abc-pkg/share/glvnd"
        );
    }

    #[test]
    fn broad_then_specific_resolves_correctly() {
        let base = "/nix/store/abc-mesa-23.1";
        let mut mappings: Vec<(String, String)> = Vec::new();

        dedup_push(&mut mappings, resolve_source(base, "./"), "/ardos/mesa/".into());
        dedup_push(
            &mut mappings,
            resolve_source(base, "share/glvnd/"),
            "/drivers/glvnd/".into(),
        );
        dedup_push(
            &mut mappings,
            resolve_source(base, "include/"),
            "/dev/null".into(),
        );
        dedup_push(
            &mut mappings,
            resolve_source(base, "lib/pkgconfig/"),
            "/dev/null".into(),
        );

        // Broad mapping first, then specifics — order preserved
        assert_eq!(mappings[0].0, "/nix/store/abc-mesa-23.1/");
        assert_eq!(mappings[0].1, "/ardos/mesa/");
        assert_eq!(mappings[1].0, "/nix/store/abc-mesa-23.1/share/glvnd/");
        assert_eq!(mappings[1].1, "/drivers/glvnd/");
        assert_eq!(mappings[2].0, "/nix/store/abc-mesa-23.1/include/");
        assert_eq!(mappings[2].1, "/dev/null");
        assert_eq!(mappings[3].0, "/nix/store/abc-mesa-23.1/lib/pkgconfig/");
        assert_eq!(mappings[3].1, "/dev/null");
    }

    #[test]
    fn external_mapping_overrides_dependency_layout() {
        let base = "/nix/store/yyy-glibc";
        let mut mappings: Vec<(String, String)> = Vec::new();

        // Step 4: dependency's own layout
        dedup_push(
            &mut mappings,
            resolve_source(base, "lib/"),
            "/old/lib/".into(),
        );
        assert_eq!(mappings[0].1, "/old/lib/");

        // Step 5: external mapping overrides the same source path
        dedup_push(
            &mut mappings,
            resolve_source(base, "lib/"),
            "/new/lib/".into(),
        );
        assert_eq!(mappings.len(), 1);
        assert_eq!(mappings[0].1, "/new/lib/");
    }

    #[test]
    fn override_moves_entry_to_end() {
        let mut mappings: Vec<(String, String)> = Vec::new();
        dedup_push(&mut mappings, "a".into(), "1".into());
        dedup_push(&mut mappings, "b".into(), "2".into());
        dedup_push(&mut mappings, "c".into(), "3".into());

        // Override "b" — old entry removed, new one appended at end
        // (last-wins: being last in the Vec means it wins for equal prefix lengths)
        dedup_push(&mut mappings, "b".into(), "2-new".into());
        assert_eq!(
            mappings,
            vec![
                ("a".into(), "1".into()),
                ("c".into(), "3".into()),
                ("b".into(), "2-new".into()),
            ]
        );
    }

    #[test]
    fn validate_accepts_relative_source_absolute_target() {
        assert!(validate_layout_pair("lib/", "/ardos/lib/").is_ok());
        assert!(validate_layout_pair("./", "/ardos/mesa/").is_ok());
        assert!(validate_layout_pair(".", "/dev/null").is_ok());
        assert!(validate_layout_pair("share/glvnd", "/drivers/glvnd/").is_ok());
    }

    #[test]
    fn validate_rejects_absolute_source() {
        let err = validate_layout_pair("/nix/store/foo", "/ardos/lib/").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(err.to_string().contains("must be relative"));
    }

    #[test]
    fn validate_rejects_relative_target() {
        let err = validate_layout_pair("lib/", "ardos/lib/").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(err.to_string().contains("must be absolute"));
    }

    #[test]
    fn validate_rejects_dot_slash_target() {
        assert!(validate_layout_pair("lib/", "./ardos/lib/").is_err());
    }
}
