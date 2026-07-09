use std::collections::BTreeSet;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

fn is_debug() -> bool {
    env::var("NIX_DEBUG")
        .unwrap_or_default()
        .parse::<i32>()
        .unwrap_or(0)
        >= 1
}

// Pull every distinct /nix/store/* path out of a whitespace-separated string
// of NIX-style flags. Stops at the first non-store, non-flag token.
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
                out.insert(PathBuf::from(p));
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

    let mut process_layout_line = |line: &str, base_dir: &str, w: &mut File| -> io::Result<()> {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            return Ok(());
        }
        if let Some((src_rel, dest_path)) = trimmed.split_once(" -> ") {
            let src_path = Path::new(base_dir).join(src_rel.trim());
            let dest_path = Path::new(dest_path.trim());
            if let (Some(src_dir), Some(dest_dir)) = (src_path.parent(), dest_path.parent()) {
                writeln!(w, "{} -> {}", src_dir.display(), dest_dir.display())?;
            }
        }
        Ok(())
    };

    // 1. The package's own layout, if it was declared inline.
    if let Ok(layout_meta) = env::var("ardosLayoutMetadata") {
        if !layout_meta.is_empty() {
            if is_debug() { eprintln!("[Ardos Setup] Adding current package layout metadata"); }
            for line in layout_meta.lines() { process_layout_line(&line, &out, &mut map_file)?; }
        }
    }

    // 2. Every store path the package can see at link time. stdenv has
    //    already aggregated them into NIX_LDFLAGS / NIX_CFLAGS_COMPILE /
    //    NIX_BINTOOLS / NIX_CC (and the *_FOR_BUILD / *_FOR_TARGET
    //    variants). Each of those contains absolute /nix/store/* paths
    //    and -L/-I/-rpath pointers into them.
    let mut store_paths: BTreeSet<PathBuf> = BTreeSet::new();
    for v in [
        "NIX_LDFLAGS", "NIX_LDFLAGS_BEFORE", "NIX_LDFLAGS_AFTER",
        "NIX_CFLAGS_COMPILE", "NIX_CFLAGS_LINK",
        "NIX_HARDENING_ENABLE", // contains no paths but harmless
        "NIX_CC", "NIX_BINTOOLS", "NIX_CC_FOR_BUILD", "NIX_BINTOOLS_FOR_BUILD",
        "NIX_CC_FOR_TARGET", "NIX_BINTOOLS_FOR_TARGET",
    ] {
        if let Ok(val) = env::var(v) {
            for p in collect_store_paths(&val) {
                store_paths.insert(p);
            }
        }
    }
    // 3. The explicit inputs the mkDerivation caller provided (rarely set
    //    in a hook context, but harmless to try).
    for v in ["buildInputs", "nativeBuildInputs", "propagatedBuildInputs",
              "hostInputs", "targetInputs", "NIX_BUILD_INPUTS",
              "NIX_HOST_BUILD_INPUTS", "NIX_TARGET_BUILD_INPUTS",
              "NIX_PROPAGATED_BUILD_INPUTS", "NIX_HOST_PROPAGATED_BUILD_INPUTS",
              "NIX_TARGET_PROPAGATED_BUILD_INPUTS"] {
        if let Ok(val) = env::var(v) {
            for p in collect_store_paths(&val) {
                store_paths.insert(p);
            }
        }
    }

    eprintln!("[Ardos Setup] populate-map: found {} unique store paths to scan", store_paths.len());

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
                    if line.is_empty() || line.starts_with('#') { continue; }
                    let q = PathBuf::from(line);
                    if visited.insert(q.clone()) { queue.push(q); }
                }
            }
        }
    }
    eprintln!("[Ardos Setup] populate-map: closure-walk found {} total store paths", visited.len());

    // 4. For each store path, check for a nix-support/ardos-layout. If
    //    present, splice every "<rel> -> <abs>" line into our runtime map.
    let mut layouts_seen = 0usize;
    for p in &visited {
        let layout_file = p.join("nix-support/ardos-layout");
        if layout_file.is_file() {
            layouts_seen += 1;
            if is_debug() { eprintln!("[Ardos Setup] Found layout metadata for {}", p.display()); }
            let file = File::open(&layout_file)?;
            let reader = BufReader::new(file);
            for line in reader.lines() {
                process_layout_line(&line?, p.to_str().unwrap_or(""), &mut map_file)?;
            }
        }
    }
    eprintln!("[Ardos Setup] populate-map: ingested ardos-layout from {layouts_seen} dependencies");
    Ok(())
}
