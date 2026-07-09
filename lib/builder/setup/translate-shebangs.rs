use std::collections::HashMap;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};

fn is_debug() -> bool {
    env::var("NIX_DEBUG")
        .unwrap_or_default()
        .parse::<i32>()
        .unwrap_or(0)
        >= 1
}

fn main() -> io::Result<()> {
    let runtime_map_env = match env::var("ARDOS_RUNTIME_MAP") {
        Ok(v) if !v.is_empty() => v,
        _ => return Ok(()),
    };
    let runtime_map_path = Path::new(&runtime_map_env);
    if !runtime_map_path.is_file() { return Ok(()); }

    let out_env = env::var("out").unwrap_or_default();
    if out_env.is_empty() { return Ok(()); }
    eprintln!("[Ardos Fixup] Translating script shebangs in {out_env}...");

    let mut shebang_map = HashMap::new();
    let map_file = File::open(runtime_map_path)?;
    let reader = BufReader::new(map_file);

    for line in reader.lines() {
        let line = line?;
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') { continue; }
        if let Some((nix_path, ardos_path)) = trimmed.split_once(" -> ") {
            shebang_map.insert(nix_path.trim().to_string(), ardos_path.trim().to_string());
        }
    }

    fn visit_dirs(dir: &Path, shebang_map: &HashMap<String, String>) -> io::Result<()> {
        if dir.is_dir() {
            for entry in fs::read_dir(dir)? {
                let entry = entry?;
                let path = entry.path();
                if path.is_dir() { visit_dirs(&path, shebang_map)?; }
                else if path.is_file() { process_file(&path, shebang_map)?; }
            }
        }
        Ok(())
    }

    fn process_file(file_path: &Path, shebang_map: &HashMap<String, String>) -> io::Result<()> {
        let file = File::open(file_path)?;
        let mut reader = BufReader::new(file);
        let mut first_line = String::new();
        if matches!(reader.read_line(&mut first_line), Ok(0) | Err(_)) { return Ok(()); }

        let trimmed_first = first_line.trim_end();
        if trimmed_first.starts_with("#!") {
            let interpreter_part = trimmed_first[2..].trim();
            let (interpreter_path, interpreter_args) = match interpreter_part.split_once(' ') {
                Some((path, args)) => (path.trim(), format!(" {}", args.trim())),
                None => (interpreter_part, String::new()),
            };

            if interpreter_path.starts_with("/nix/store/") {
                let clean_path = std::fs::canonicalize(Path::new(interpreter_path))
                    .unwrap_or_else(|_| PathBuf::from(interpreter_path));
                let clean_dir = clean_path.parent().unwrap_or(Path::new("")).to_string_lossy().into_owned();
                let base_name = clean_path.file_name().unwrap_or_default().to_string_lossy().into_owned();

                if let Some(translated_dir) = shebang_map.get(&clean_dir) {
                    let translated_interpreter = format!("{translated_dir}/{base_name}");
                    eprintln!("[Ardos Fixup] Translating shebang in {}: {interpreter_path} -> {translated_interpreter}", file_path.display());

                    let mut content = format!("#!{translated_interpreter}{interpreter_args}\n");
                    let mut rest_of_file = String::new();
                    reader.read_to_string(&mut rest_of_file)?;
                    content.push_str(&rest_of_file);

                    let mut out_file = File::create(file_path)?;
                    out_file.write_all(content.as_bytes())?;
                } else {
                    eprintln!("[Ardos Fixup] WARNING: No Ardos mapping found for interpreter path: {interpreter_path} in {}", file_path.display());
                }
            }
        }
        Ok(())
    }

    visit_dirs(Path::new(&out_env), &shebang_map)
}
