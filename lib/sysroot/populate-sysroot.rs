use std::collections::HashMap;
use std::fs;
use std::os::unix::fs as unix_fs;
use std::path::{Path, PathBuf};
use std::process;

/// Represents a single file mapping entry.
struct Mapping {
    src: PathBuf,
    dest: PathBuf,
}

/// Reads a layout file and expands all entries into individual file mappings.
fn expand_layout(
    layout_path: &Path,
    store_path: &Path,
    mappings: &mut Vec<Mapping>,
    excludes: &mut Vec<PathBuf>,
) {
    let content = match fs::read_to_string(layout_path) {
        Ok(c) => c,
        Err(_) => return,
    };

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let Some((src_rel, dest_abs)) = line.split_once(" -> ") else {
            continue;
        };

        if dest_abs == "/dev/null" {
            excludes.push(PathBuf::from(dest_abs));
            continue;
        }

        let src_path = if src_rel.starts_with('/') {
            PathBuf::from(src_rel)
        } else {
            store_path.join(src_rel)
        };

        // Skip GNU ld scripts
        if src_path.is_file() && !src_path.is_symlink() {
            if let Ok(content) = fs::read(&src_path) {
                let prefix = String::from_utf8_lossy(&content[..content.len().min(4096)]);
                if prefix.starts_with("/* GNU ld script") {
                    continue;
                }
            }
        }

        if src_rel.ends_with('/') {
            // Folder mapping — expand via recursive walk
            if src_path.is_dir() && !src_path.is_symlink() {
                expand_dir(&src_path, &PathBuf::from(dest_abs), mappings, excludes);
            }
        } else if src_path.exists() || src_path.is_symlink() {
            mappings.push(Mapping {
                src: src_path,
                dest: PathBuf::from(dest_abs),
            });
        }
    }
}

/// Recursively walks a directory and adds file/symlink mappings (skips subdirs).
fn expand_dir(
    src_dir: &Path,
    dest_prefix: &Path,
    mappings: &mut Vec<Mapping>,
    excludes: &mut Vec<PathBuf>,
) {
    let mut stack = vec![src_dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries {
            let Ok(entry) = entry else {
                continue;
            };
            let path = entry.path();
            if path.is_dir() && !path.is_symlink() {
                stack.push(path);
            } else {
                // File or symlink
                let Ok(rel) = path.strip_prefix(src_dir) else {
                    continue;
                };
                let dest = dest_prefix.join(rel);
                mappings.push(Mapping { src: path, dest });
            }
        }
    }
}

/// Parses the external mappings file and applies only those whose drv is in the closure.
fn expand_external_mappings(
    external_file: &Path,
    closure_paths: &HashMap<String, PathBuf>,
    mappings: &mut Vec<Mapping>,
    excludes: &mut Vec<PathBuf>,
) {
    let content = match fs::read_to_string(external_file) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut active_base: Option<PathBuf> = None;
    let mut active_applies = false;

    for line in content.lines() {
        let line = line.trim();
        if let Some(drv) = line.strip_prefix("# ardos-external-mapping ") {
            active_base = Some(PathBuf::from(drv));
            active_applies = closure_paths.contains_key(drv);
            continue;
        }

        if !active_applies || line.is_empty() || line.starts_with('#') {
            continue;
        }

        let Some(base) = &active_base else {
            continue;
        };

        let Some((src_rel, dest_abs)) = line.split_once(" -> ") else {
            continue;
        };

        if dest_abs == "/dev/null" {
            excludes.push(PathBuf::from(dest_abs));
            continue;
        }

        // Create a temporary single-line layout and expand it
        let tmp_layout = PathBuf::from("/tmp/ardos-tmp-layout");
        let _ = fs::write(&tmp_layout, format!("{src_rel} -> {dest_abs}\n"));
        expand_layout(&tmp_layout, base, mappings, excludes);
        let _ = fs::remove_file(&tmp_layout);
    }
}

/// Deduplicates mappings: last wins per destination, respects excludes.
fn deduplicate(
    mappings: Vec<Mapping>,
    excludes: Vec<PathBuf>,
) -> Vec<Mapping> {
    let exclude_set: HashMap<String, ()> = excludes
        .into_iter()
        .map(|p| (p.to_string_lossy().to_string(), ()))
        .collect();

    let mut resolved: HashMap<String, PathBuf> = HashMap::new();

    for m in mappings {
        let dest_key = m.dest.to_string_lossy().to_string();
        if exclude_set.contains_key(&dest_key) {
            resolved.remove(&dest_key);
        } else {
            resolved.insert(dest_key, m.src);
        }
    }

    resolved
        .into_iter()
        .map(|(dest, src)| Mapping {
            src,
            dest: PathBuf::from(dest),
        })
        .collect()
}

/// Copies a single file/symlink to the work directory.
fn copy_item(src: &Path, dest: &Path, work: &Path) {
    let full_dest = work.join(dest.strip_prefix("/").unwrap_or(dest));
    let dest_dir = full_dest.parent().unwrap();
    let _ = fs::create_dir_all(dest_dir);

    if src.is_symlink() {
        if let Ok(target) = fs::read_link(src) {
            let _ = unix_fs::symlink(&target, &full_dest);
        }
    } else {
        let _ = fs::copy(src, &full_dest);
        // Make executable if source is executable
        if let Ok(metadata) = fs::metadata(src) {
            use std::os::unix::fs::PermissionsExt;
            let mode = metadata.permissions().mode();
            if mode & 0o111 != 0 {
                let mut perms = metadata.permissions();
                perms.set_mode(mode | 0o111);
                let _ = fs::set_permissions(&full_dest, perms);
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("Usage: {} <closure-info> <external-mappings|-> <work-dir>", args[0]);
        process::exit(1);
    }

    let closure_info = &args[1];
    let external_mappings_arg = &args[2];
    let work_dir = PathBuf::from(&args[3]);

    // Read closure store paths
    let store_paths_file = Path::new(closure_info).join("store-paths");
    let store_paths_content = match fs::read_to_string(&store_paths_file) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Failed to read store-paths: {e}");
            process::exit(1);
        }
    };

    // Build a map of store path basename -> full path for quick lookup
    let closure_paths: HashMap<String, PathBuf> = store_paths_content
        .lines()
        .map(|l| {
            let p = PathBuf::from(l.trim());
            (l.trim().to_string(), p)
        })
        .collect();

    let mut mappings: Vec<Mapping> = Vec::new();
    let mut excludes: Vec<PathBuf> = Vec::new();

    // Phase 1: Collect from closure
    for line in store_paths_content.lines() {
        let store_path = PathBuf::from(line.trim());
        let layout = store_path.join("nix-support/ardos-layout");
        if layout.is_file() {
            expand_layout(&layout, &store_path, &mut mappings, &mut excludes);
        }
    }

    // Phase 1b: External mappings
    if external_mappings_arg != "-" {
        let external_file = Path::new(external_mappings_arg);
        if external_file.is_file() {
            expand_external_mappings(external_file, &closure_paths, &mut mappings, &mut excludes);
        }
    }

    // Phase 2: Deduplicate
    let resolved = deduplicate(mappings, excludes);

    // Phase 3: Copy
    for m in &resolved {
        copy_item(&m.src, &m.dest, &work_dir);
    }
}
