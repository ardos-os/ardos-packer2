use std::collections::{BTreeMap, BTreeSet};
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
    path_map: &'a BTreeMap<String, String>,
) -> Vec<(&'a String, &'a String)> {
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
fn translate_rpath(
    path_map: &BTreeMap<String, String>,
    flag: &str,
    val: &str,
    stdout: &mut impl Write,
    unmapped_nix_paths: &mut Vec<UnmappedNixPath>,
    used_mappings: &mut BTreeSet<String>,
) -> io::Result<()> {
    let clean_str = PathBuf::from(val).to_string_lossy().into_owned();
    if let Some(translated) = path_map.get(&clean_str) {
        used_mappings.insert(clean_str.clone());
        eprintln!("Translating library {clean_str} -> {translated}");
        stdout.write_all(flag.as_bytes())?;
        stdout.write_all(b"\0")?;
        stdout.write_all(translated.as_bytes())?;
        stdout.write_all(b"\0")?;

        stdout.write_all(b"-rpath-link")?;
        stdout.write_all(b"\0")?;
        stdout.write_all(val.as_bytes())?;
        stdout.write_all(b"\0")?;
    } else if clean_str.starts_with("/nix/store/") {
        if is_current_output_path(&clean_str) {
            if env::var("NIX_DEBUG").unwrap_or_default() == "1" {
                eprintln!(
                    "[Ardos Linker Hook (Rust)] Stripping current output RPATH before install: {}",
                    clean_str
                );
            }
            return Ok(());
        }

        unmapped_nix_paths.push(UnmappedNixPath {
            kind: "rpath",
            path: clean_str.clone(),
            lookup_path: clean_str,
        });
    } else if is_dir_empty(&clean_str) {
        return Ok(());
    } else {
        eprintln!("other libraries: {flag} {val}");
        stdout.write_all(flag.as_bytes())?;
        stdout.write_all(b"\0")?;
        stdout.write_all(val.as_bytes())?;
        stdout.write_all(b"\0")?;
    }
    Ok(())
}
fn translate_dynamic_linker(
    path_map: &BTreeMap<String, String>,
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
        let linker_dir = canon_val
            .parent()
            .unwrap_or(Path::new(""))
            .to_string_lossy()
            .into_owned();
        let linker_base = canon_val
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();

        if let Some(translated_dir) = path_map.get(&linker_dir) {
            used_mappings.insert(linker_dir.clone());
            let translated = format!("{}/{}", translated_dir, linker_base);
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
                lookup_path: linker_dir,
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

    // Load path mappings
    let mut path_map = BTreeMap::new();
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
                path_map.insert(nix_path, ardos_path);
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
                for (nix_path, ardos_path) in similar {
                    eprintln!("      * {} -> {}", nix_path, ardos_path);
                }
            }
        }
        eprintln!("\n             Runtime mappings that were loaded but not used:");
        let mut unused_count = 0usize;
        for (nix_path, ardos_path) in &path_map {
            if !used_mappings.contains(nix_path) {
                unused_count += 1;
                eprintln!("  - {} -> {}", nix_path, ardos_path);
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
