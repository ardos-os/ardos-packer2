use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

#[derive(Debug)]
struct UnmappedNixPath {
    kind: &'static str,
    path: String,
    lookup_path: String,
}

fn nix_store_name(path: &str) -> Option<&str> {
    let rest = path.strip_prefix("/nix/store/")?;
    let store_component = rest.split('/').next()?;
    let (_, name) = store_component.split_once('-')?;
    Some(name)
}

fn similar_mappings<'a>(
    unmapped: &UnmappedNixPath,
    path_map: &'a [(String, String)],
) -> Vec<&'a (String, String)> {
    let Some(unmapped_name) = nix_store_name(&unmapped.lookup_path) else {
        return Vec::new();
    };

    path_map
        .iter()
        .filter(|(mapped_path, _)| nix_store_name(mapped_path) == Some(unmapped_name))
        .collect()
}

fn is_current_output_path(path: &str) -> bool {
    let Ok(out) = env::var("out") else {
        return false;
    };

    !out.is_empty() && (path == out || path.starts_with(&format!("{out}/")))
}

fn is_dir_empty<P: AsRef<Path>>(path: P) -> bool {
    let path = path.as_ref();
    if !path.is_dir() {
        return true;
    }

    match fs::read_dir(path) {
        Ok(mut entries) => entries.next().is_none(),
        Err(_) => true,
    }
}

/// Find the best matching mapping for `lookup_path` using longest-prefix matching.
/// When multiple mappings have the same prefix length, the last one wins
/// (insertion order is preserved in the Vec).
fn translate_mapped_path(
    path_map: &[(String, String)],
    lookup_path: &str,
) -> Option<(String, String)> {
    let mut best: Option<(usize, &str, &str)> = None;

    for (nix_path, ardos_path) in path_map {
        let matched_len = if lookup_path == nix_path {
            nix_path.len()
        } else {
            // Try the prefix as-is. If it ends with / (folder mapping),
            // also try without the trailing / to match the directory path
            // itself (e.g. rpath ".../lib" against mapping ".../lib/").
            let trimmed = nix_path.trim_end_matches('/');
            let candidates: &[&str] = if trimmed != nix_path {
                &[nix_path.as_str(), trimmed]
            } else {
                &[nix_path.as_str()]
            };

            let mut found_len = None;
            for &prefix in candidates {
                if let Some(suffix) = lookup_path.strip_prefix(prefix) {
                    if suffix.is_empty() || suffix.starts_with('/') {
                        found_len = Some(prefix.len());
                        break;
                    }
                }
            }

            match found_len {
                Some(len) => len,
                None => continue,
            }
        };

        // Last longest-prefix match wins: replace if strictly longer, or if
        // equal length (last-wins semantics).
        match best {
            Some((prev_len, _, _)) if prev_len > matched_len => {}
            _ => best = Some((matched_len, nix_path.as_str(), ardos_path.as_str())),
        }
    }

    let (best_prefix_len, nix_path, ardos_path) = best?;

    let suffix = if lookup_path.len() <= best_prefix_len {
        ""
    } else {
        &lookup_path[best_prefix_len + 1..]
    };
    let translated = if suffix.is_empty() {
        ardos_path.to_string()
    } else {
        format!("{}/{}", ardos_path.trim_end_matches('/'), suffix)
    };
    Some((nix_path.to_string(), translated))
}

fn translate_rpath(
    path_map: &[(String, String)],
    flag: &str,
    val: &str,
    stdout: &mut impl Write,
    unmapped_nix_paths: &mut Vec<UnmappedNixPath>,
    used_mappings: &mut BTreeSet<String>,
) -> io::Result<()> {
    // RPATH entries are colon-separated (e.g. -rpath dir1:dir2:).
    // Translate each component independently, join back with colons.
    let mut translated_components: Vec<String> = Vec::new();
    let mut had_unmapped = false;
    for component in val.split(':') {
        if component.is_empty() {
            translated_components.push(String::new());
            continue;
        }
        let clean_str = PathBuf::from(component).to_string_lossy().into_owned();
        if let Some((matched_path, translated)) = translate_mapped_path(path_map, &clean_str) {
            used_mappings.insert(matched_path);
            eprintln!("Translating library {clean_str} -> {translated}");
            translated_components.push(translated);
        } else if clean_str.starts_with("/nix/store/")
            && !is_dir_empty(&clean_str)
        {
            unmapped_nix_paths.push(UnmappedNixPath {
                kind: "rpath",
                path: clean_str.clone(),
                lookup_path: clean_str,
            });
            had_unmapped = true;
            translated_components.push(component.to_string());
        } else if clean_str.contains("$ORIGIN")
            || clean_str.contains("$LIB")
            || clean_str.contains("$PLATFORM")
        {
            // ELF dynamic string tokens (e.g. $ORIGIN/../lib) are not real
            // filesystem paths — always pass them through unchanged.
            translated_components.push(component.to_string());
        } else if is_dir_empty(&clean_str) {
            continue;
        } else {
            translated_components.push(component.to_string());
        }
    }

    if !translated_components.is_empty() && !had_unmapped {
        let joined = translated_components.join(":");
        stdout.write_all(flag.as_bytes())?;
        stdout.write_all(b"\0")?;
        stdout.write_all(joined.as_bytes())?;
        stdout.write_all(b"\0")?;
        stdout.write_all(b"-rpath-link")?;
        stdout.write_all(b"\0")?;
        stdout.write_all(val.as_bytes())?;
        stdout.write_all(b"\0")?;
    }
    Ok(())
}

fn translate_dynamic_linker(
    path_map: &[(String, String)],
    flag: &str,
    val: &str,
    stdout: &mut impl Write,
    unmapped_nix_paths: &mut Vec<UnmappedNixPath>,
    used_mappings: &mut BTreeSet<String>,
) -> io::Result<()> {
    if val.starts_with("/nix/store/") {
        // Canonicalize to resolve lib64/lib32 symlinks -> /lib
        let canon_val = Path::new(val)
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(val));
        let linker_path = canon_val.to_string_lossy().into_owned();

        if let Some((matched_path, translated)) = translate_mapped_path(path_map, &linker_path) {
            used_mappings.insert(matched_path);
            if env::var("NIX_DEBUG").unwrap_or_default() == "1" {
                eprintln!(
                    "[Ardos Linker Hook (Rust)] Translating dynamic linker: {} -> {}",
                    val, translated
                );
            }
            stdout.write_all(flag.as_bytes())?;
            stdout.write_all(b"\0")?;
            stdout.write_all(translated.as_bytes())?;
            stdout.write_all(b"\0")?;
        } else {
            unmapped_nix_paths.push(UnmappedNixPath {
                kind: "interpreter",
                path: val.to_string(),
                lookup_path: linker_path,
            });
        }
    } else {
        stdout.write_all(flag.as_bytes())?;
        stdout.write_all(b"\0")?;
        stdout.write_all(val.as_bytes())?;
        stdout.write_all(b"\0")?;
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 || args[1] != "--map" {
        eprintln!("Usage: ardos-ld-translate --map <map_path> [args...]");
        std::process::exit(1);
    }

    let map_path = &args[2];
    let input_args = &args[3..];

    // Load path mappings. Vec preserves insertion order so that later entries
    // (which override earlier ones for the same prefix length) win.
    let mut path_map: Vec<(String, String)> = Vec::new();
    if let Ok(file) = File::open(map_path) {
        let reader = BufReader::new(file);
        for line in reader.lines() {
            let line = line?;
            if line.starts_with('#') || line.trim().is_empty() {
                continue;
            }
            if let Some(pos) = line.find(" -> ") {
                let nix_path = line[..pos].trim().to_string();
                let ardos_path = line[pos + 4..].trim().to_string();
                // Remove any earlier entry with the same nix_path (last wins).
                path_map.retain(|(k, _)| k != &nix_path);
                path_map.push((nix_path, ardos_path));
            }
        }
    }

    let mut stdout = io::stdout();
    stdout.write_all(b"--copy-dt-needed-entries")?;
    stdout.write_all(b"\0")?;
    let mut unmapped_nix_paths = Vec::new();
    let mut used_mappings = BTreeSet::new();
    let mut i = 0;
    while i < input_args.len() {
        let arg = &input_args[i];

        // Handle "-rpath /path" (two-arg form)
        if arg == "-rpath" && i + 1 < input_args.len() {
            translate_rpath(
                &path_map,
                "-rpath",
                &input_args[i + 1],
                &mut stdout,
                &mut unmapped_nix_paths,
                &mut used_mappings,
            )?;
            i += 2;
        // Handle "-rpath=/path" (combined form)
        } else if let Some(val) = arg.strip_prefix("-rpath=") {
            translate_rpath(
                &path_map,
                "-rpath",
                val,
                &mut stdout,
                &mut unmapped_nix_paths,
                &mut used_mappings,
            )?;
            i += 1;
        // Handle "-dynamic-linker /path" or "--dynamic-linker /path" (two-arg)
        } else if (arg == "-dynamic-linker" || arg == "--dynamic-linker")
            && i + 1 < input_args.len()
        {
            translate_dynamic_linker(
                &path_map,
                arg,
                &input_args[i + 1],
                &mut stdout,
                &mut unmapped_nix_paths,
                &mut used_mappings,
            )?;
            i += 2;
        // Handle "-dynamic-linker=/path" or "--dynamic-linker=/path" (combined form)
        } else if let Some(val) = arg
            .strip_prefix("-dynamic-linker=")
            .or_else(|| arg.strip_prefix("--dynamic-linker="))
        {
            let flag = if arg.starts_with("--") {
                "--dynamic-linker"
            } else {
                "-dynamic-linker"
            };
            translate_dynamic_linker(
                &path_map,
                flag,
                val,
                &mut stdout,
                &mut unmapped_nix_paths,
                &mut used_mappings,
            )?;
            i += 1;
        } else {
            stdout.write_all(arg.as_bytes())?;
            stdout.write_all(b"\0")?;
            i += 1;
        }
    }

    if !unmapped_nix_paths.is_empty() {
        eprintln!(
            "\n========================================================================\n\
             [Ardos Linker Error] Unmapped Nix store runtime paths remained\n\
             in linker RPATH/interpreter arguments.\n\n\
             Reason: every runtime dependency must have an Ardos runtime mapping.\n\
             Unmapped paths:"
        );
        for unmapped in &unmapped_nix_paths {
            eprintln!("  - {}: {}", unmapped.kind, unmapped.path);
            let similar = similar_mappings(unmapped, &path_map);
            if !similar.is_empty() {
                eprintln!("    similar mappings with the same package name:");
                for (nix_path, ardos_path) in &similar {
                    eprintln!("      * {} -> {}", nix_path, ardos_path);
                }
            }
        }
        eprintln!("\n             Runtime mappings that were loaded but not used:");
        let mut unused_count = 0usize;
        for (nix_path, _) in &path_map {
            if !used_mappings.contains(nix_path) {
                unused_count += 1;
                // Find the ardos_path for display
                if let Some((_, ardos_path)) = path_map.iter().find(|(k, _)| k == nix_path) {
                    eprintln!("  - {} -> {}", nix_path, ardos_path);
                }
            }
        }
        if unused_count == 0 {
            eprintln!("  (none)");
        }
        eprintln!("========================================================================");
        std::process::exit(1);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(entries: &[(&str, &str)]) -> Vec<(String, String)> {
        entries
            .iter()
            .map(|(from, to)| ((*from).to_string(), (*to).to_string()))
            .collect()
    }

    #[test]
    fn translates_exact_mapping() {
        let mappings = map(&[("/nix/store/hash-pkg/lib", "/ardos/lib")]);
        assert_eq!(
            translate_mapped_path(&mappings, "/nix/store/hash-pkg/lib"),
            Some((
                "/nix/store/hash-pkg/lib".to_string(),
                "/ardos/lib".to_string()
            ))
        );
    }

    #[test]
    fn translates_file_inside_mapped_folder() {
        let mappings = map(&[("/nix/store/hash-pkg/lib", "/ardos/lib")]);
        assert_eq!(
            translate_mapped_path(&mappings, "/nix/store/hash-pkg/lib/ld.so"),
            Some((
                "/nix/store/hash-pkg/lib".to_string(),
                "/ardos/lib/ld.so".to_string()
            ))
        );
    }

    #[test]
    fn does_not_match_partial_path_component() {
        let mappings = map(&[("/nix/store/hash-pkg/lib", "/ardos/lib")]);
        assert_eq!(
            translate_mapped_path(&mappings, "/nix/store/hash-pkg/lib64/ld.so"),
            None
        );
    }

    #[test]
    fn prefers_longest_mapping() {
        let mappings = map(&[
            ("/nix/store/hash-pkg", "/ardos/pkg"),
            ("/nix/store/hash-pkg/lib", "/ardos/lib"),
        ]);
        assert_eq!(
            translate_mapped_path(&mappings, "/nix/store/hash-pkg/lib/ld.so"),
            Some((
                "/nix/store/hash-pkg/lib".to_string(),
                "/ardos/lib/ld.so".to_string()
            ))
        );
    }

    #[test]
    fn last_wins_for_same_length_prefix() {
        let mappings = map(&[
            ("/nix/store/hash-pkg/lib", "/old/lib"),
            ("/nix/store/hash-pkg/lib", "/ardos/lib"),
        ]);
        assert_eq!(
            translate_mapped_path(&mappings, "/nix/store/hash-pkg/lib/ld.so"),
            Some((
                "/nix/store/hash-pkg/lib".to_string(),
                "/ardos/lib/ld.so".to_string()
            ))
        );
    }

    #[test]
    fn folder_mapping_expands_via_prefix() {
        let mappings = map(&[("/nix/store/hash-pkg/lib/", "/ardos/lib/")]);
        assert_eq!(
            translate_mapped_path(&mappings, "/nix/store/hash-pkg/lib/libfoo.so"),
            Some((
                "/nix/store/hash-pkg/lib/".to_string(),
                "/ardos/lib/libfoo.so".to_string()
            ))
        );
    }
}
