use std::env;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

fn is_debug() -> bool {
    std::env::var("NIX_DEBUG")
        .unwrap_or_default()
        .parse::<i32>()
        .unwrap_or(0)
        >= 1
}

fn main() -> io::Result<()> {
    let out_env = match env::var("out") {
        Ok(v) => v,
        _ => return Ok(()),
    };
    let out = Path::new(&out_env);
    let nix_support = out.join("nix-support");
    let layout_file_path = nix_support.join("ardos-layout");

    eprintln!(
        "[Ardos Layout] generate-layout: layout_file_path={} exists={}",
        layout_file_path.display(),
        layout_file_path.is_file()
    );
    if layout_file_path.is_file() {
        if is_debug() {
            eprintln!(
                "[Ardos Layout] Using existing custom layout metadata in {}",
                out.display()
            );
        }
        return Ok(());
    }

    eprintln!(
        "[Ardos Layout] generate-layout invoked: out={}",
        out.display()
    );
    fs::create_dir_all(&nix_support)?;
    let mut layout_file = File::create(&layout_file_path)?;

    if is_debug() {
        eprintln!(
            "[Ardos Layout] Generating default layout mapping for {}",
            out.display()
        );
    }

    let mut map_bin_dir = |dir_name: &str| -> io::Result<()> {
        let dir_path = out.join(dir_name);
        if dir_path.is_dir() {
            for entry in fs::read_dir(dir_path)? {
                let entry = entry?;
                let file_type = entry.file_type()?;
                if file_type.is_file() || file_type.is_symlink() {
                    if let Some(file_name) = entry.file_name().to_str() {
                        if file_name.contains(".so") {
                            writeln!(
                                layout_file,
                                "{dir_name}/{file_name} -> /ardos/bin/{file_name}"
                            )?;
                        }
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
