use std::collections::HashMap;
use std::env;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::fs;

fn is_dir_empty<P: AsRef<Path>>(path: P) -> bool {
    // Se a pasta nem existe ou não é diretoria, consideramos "vazia/irrelevante" para o RPATH
    let path = path.as_ref();
    if !path.is_dir() {
        return true;
    }

    // Lê o conteúdo da diretoria. Se falhar ou o primeiro elemento for None, está vazia.
    match fs::read_dir(path) {
        Ok(mut entries) => entries.next().is_none(),
        Err(_) => true, // Se não conseguir ler (permissão, etc), trata como vazia para evitar pânico
    }
}
fn translate_rpath(
    path_map: &HashMap<String, String>,
    flag: &str,
    val: &str,
    stdout: &mut impl Write,
) -> io::Result<()> {
    let clean_str = PathBuf::from(val).to_string_lossy().into_owned();
    if is_dir_empty(&clean_str) {
        return Ok(());
    }
    if let Some(translated) = path_map.get(&clean_str) {
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
        eprintln!(
            "\n========================================================================\n\
             [Ardos Linker Error] RPATH points to an unmapped Nix store path:\n  {}\n\n\
             Reason: The dependency has no Ardos runtime mapping.\n\
             ========================================================================",
            val
        );
        std::process::exit(1);
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
    path_map: &HashMap<String, String>,
    flag: &str,
    val: &str,
    stdout: &mut impl Write,
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
            if env::var("NIX_DEBUG").unwrap_or_default() == "1" {
                eprintln!(
                    "[Ardos Linker Hook (Rust)] WARNING: Could not translate dynamic linker path: {}",
                    val
                );
            }
            stdout.write_all(flag.as_bytes())?;
            stdout.write_all(b"\0")?;
            stdout.write_all(val.as_bytes())?;
            stdout.write_all(b"\0")?;
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
    // Expecting: ardos-ld-translate --map <map-file> [args...]
    if args.len() < 3 || args[1] != "--map" {
        eprintln!("Usage: ardos-ld-translate --map <map_path> [args...]");
        std::process::exit(1);
    }

    let map_path = &args[2];
    let input_args = &args[3..];

    // Load path mappings
    let mut path_map = HashMap::new();
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
    let mut i = 0;
    while i < input_args.len() {
        let arg = &input_args[i];

        // Handle "-rpath /path" (two-arg form)
        if arg == "-rpath" && i + 1 < input_args.len() {
            translate_rpath(&path_map, "-rpath", &input_args[i + 1], &mut stdout)?;
            i += 2;
        // Handle "-rpath=/path" (combined form)
        } else if let Some(val) = arg.strip_prefix("-rpath=") {
            translate_rpath(&path_map, "-rpath", val, &mut stdout)?;
            i += 1;
        // Handle "-dynamic-linker /path" or "--dynamic-linker /path" (two-arg)
        } else if (arg == "-dynamic-linker" || arg == "--dynamic-linker")
            && i + 1 < input_args.len()
        {
            translate_dynamic_linker(&path_map, arg, &input_args[i + 1], &mut stdout)?;
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
            translate_dynamic_linker(&path_map, flag, val, &mut stdout)?;
            i += 1;
        } else {
            stdout.write_all(arg.as_bytes())?;
            stdout.write_all(b"\0")?;
            i += 1;
        }
    }
    Ok(())
}
