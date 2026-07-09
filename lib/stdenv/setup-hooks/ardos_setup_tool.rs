use std::collections::HashMap;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use std::io::Read;
fn is_debug() -> bool {
    env::var("NIX_DEBUG")
        .unwrap_or_default()
        .parse::<i32>()
        .unwrap_or(0)
        >= 1
}

fn main() -> io::Result<()> {
    let args: Vec<String> = env::args().collect();
    let subcommand = if args.len() > 1 { args[1].as_str() } else { "early-init" };

    match subcommand {
        "early-init" => ardos_early_init(),
        "populate-map" => ardos_populate_map(),
        "generate-layout" => ardos_generate_default_layout(),
        "translate-shebangs" => ardos_translate_shebangs(),
        _ => {
            eprintln!("[Ardos Script] Unknown subcommand: {}", subcommand);
            std::process::exit(1);
        }
    }
}

/// ─── 1. EARLY INIT & BASH HOOK GENERATION ───
fn ardos_early_init() -> io::Result<()> {
    // 1. Captura as variáveis substituídas em eval-time pelo template do Nix
    let __ardos_ld_hook__ = env::var("__ardosLdHook__").unwrap_or_default();
    let __ardos_map_target_glibc__ = env::var("__ardosMapTargetGlibc__").unwrap_or_default();
    let __ardos_map_target_libgcc__ = env::var("__ardosMapTargetLibgcc__").unwrap_or_default();
    
    // Descobre onde o próprio executável Rust está localizado no nix/store
    let current_exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("ardos-setup-tool"));
    let exe_path = current_exe.to_string_lossy();

    // 2. Cria o ficheiro temporário para o mapa de runtime de forma estrita
    let tmp_dir = env::var("TMPDIR").unwrap_or_else(|_| "/tmp".to_string());
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let pid = std::process::id();
    let rand_suffix = format!("{:x}", nanos ^ (pid as u128));
    let suffix_trimmed = if rand_suffix.len() > 6 { &rand_suffix[..6] } else { &rand_suffix };
    
    let mut temp_path = PathBuf::from(tmp_dir);
    temp_path.push(format!("ardos-runtime-map.{}", suffix_trimmed));
    let runtime_map_str = temp_path.to_string_lossy().into_owned();

    let mut map_file = OpenOptions::new().create(true).truncate(true).write(true).open(&temp_path)?;

    // Injeta os bootstraps iniciais no mapa
    if !__ardos_map_target_glibc__.is_empty() {
        let glibc_lib = Path::new(&__ardos_map_target_glibc__).join("lib");
        if glibc_lib.is_dir() {
            writeln!(map_file, "{} -> /ardos/lib", glibc_lib.display())?;
        }
    }
    if !__ardos_map_target_libgcc__.is_empty() {
        let libgcc_lib = Path::new(&__ardos_map_target_libgcc__).join("lib");
        if libgcc_lib.is_dir() {
            writeln!(map_file, "{} -> /ardos/lib", libgcc_lib.display())?;
        }
    }

    if is_debug() {
        eprintln!("[Ardos Setup] Created translation map at {}", runtime_map_str);
    }

    // 3. EMITE O BASH PARA O EVAL
    // Exporta as variáveis de ambiente necessárias para o linker-wrapper
    println!("export ARDOS_LD_HOOK=\"{}\"", __ardos_ld_hook__);
    println!("export ARDOS_RUNTIME_MAP=\"{}\"", runtime_map_str);
    println!("echo \"{}\";", __ardos_map_target_glibc__);
    println!("echo \"{}\";", __ardos_map_target_libgcc__);

    // Cospe dinamicamente as funções de hook apontando cirurgicamente para este binário
    println!(
        r#"
ardosGenerateDefaultLayout() {{
  "{exe}" generate-layout
}}
ardosPopulateMap() {{
  "{exe}" populate-map
}}
ardosTranslateShebangs() {{
  "{exe}" translate-shebangs
}}

preFixupHooks+=(ardosGenerateDefaultLayout)
preConfigureHooks+=(ardosPopulateMap)
postFixupHooks+=(ardosTranslateShebangs)
"#,
        exe = exe_path
    );

    Ok(())
}

// ─── As restantes funções mantêm a mesma lógica pura em Rust ───
fn ardos_populate_map() -> io::Result<()> {
    let runtime_map_env = match env::var("ARDOS_RUNTIME_MAP") {
        Ok(v) if !v.is_empty() => v,
        _ => return Ok(()),
    };
    let runtime_map_path = Path::new(&runtime_map_env);
    let out = env::var("out").unwrap_or_default();
    let mut map_file = OpenOptions::new().append(true).open(runtime_map_path)?;

    let mut process_layout_line = |line: &str, base_dir: &str| -> io::Result<()> {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            return Ok(());
        }
        if let Some((src_rel, dest_path)) = trimmed.split_once(" -> ") {
            let src_path = Path::new(base_dir).join(src_rel.trim());
            let dest_path = Path::new(dest_path.trim());
            if let (Some(src_dir), Some(dest_dir)) = (src_path.parent(), dest_path.parent()) {
                writeln!(map_file, "{} -> {}", src_dir.display(), dest_dir.display())?;
            }
        }
        Ok(())
    };

    if let Ok(layout_meta) = env::var("ardosLayoutMetadata") {
        if !layout_meta.is_empty() {
            if is_debug() { eprintln!("[Ardos Setup] Adding current package layout metadata"); }
            for line in layout_meta.lines() { process_layout_line(line, &out)?; }
        }
    }

    let mut deps = env::var("buildInputs").unwrap_or_default();
    let propagated = env::var("propagatedBuildInputs").unwrap_or_default();
    if !propagated.is_empty() {
        deps.push(' ');
        deps.push_str(&propagated);
    }

    for dep in deps.split_whitespace() {
        let dep_path = Path::new(dep);
        let layout_meta_file = dep_path.join("nix-support/ardos-layout");
        if layout_meta_file.is_file() {
            if is_debug() { eprintln!("[Ardos Setup] Found layout metadata for {dep}"); }
            let file = File::open(layout_meta_file)?;
            let reader = BufReader::new(file);
            for line in reader.lines() { process_layout_line(&line?, dep)?; }
        }
    }
    Ok(())
}

fn ardos_generate_default_layout() -> io::Result<()> {
    let out_env = match env::var("out") {
        Ok(v) => v,
        _ => return Ok(()),
    };
    let out = Path::new(&out_env);
    let nix_support = out.join("nix-support");
    let layout_file_path = nix_support.join("ardos-layout");

    if layout_file_path.is_file() {
        if is_debug() { eprintln!("[Ardos Layout] Using existing custom layout metadata in {}", out.display()); }
        return Ok(());
    }

    fs::create_dir_all(&nix_support)?;
    let mut layout_file = File::create(&layout_file_path)?;

    if is_debug() { eprintln!("[Ardos Layout] Generating default layout mapping for {}", out.display()); }

    let mut map_bin_dir = |dir_name: &str| -> io::Result<()> {
        let dir_path = out.join(dir_name);
        if dir_path.is_dir() {
            for entry in fs::read_dir(dir_path)? {
                let entry = entry?;
                let file_type = entry.file_type()?;
                if file_type.is_file() || file_type.is_symlink() {
                    if let Some(file_name) = entry.file_name().to_str() {
                        writeln!(layout_file, "{dir_name}/{file_name} -> /ardos/bin/{file_name}")?;
                    }
                }
            }
        }
        Ok(())
    };

    map_bin_dir("bin")?;
    map_bin_dir("sbin")?;

    let lib_path = out.join("lib");
    if lib_path.is_dir() {
        for entry in fs::read_dir(lib_path)? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            if file_type.is_file() || file_type.is_symlink() {
                if let Some(file_name) = entry.file_name().to_str() {
                    if file_name.contains(".so") {
                        writeln!(layout_file, "lib/{file_name} -> /ardos/lib/{file_name}")?;
                    }
                }
            }
        }
    }
    Ok(())
}

fn ardos_translate_shebangs() -> io::Result<()> {
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
                let clean_path = fs::canonicalize(Path::new(interpreter_path)).unwrap_or_else(|_| PathBuf::from(interpreter_path));
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