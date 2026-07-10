use std::env;
use std::fs::OpenOptions;
use std::io::{self, BufRead, BufReader};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn is_debug() -> bool {
    env::var("NIX_DEBUG")
        .unwrap_or_default()
        .parse::<i32>()
        .unwrap_or(0)
        >= 1
}

fn main() -> io::Result<()> {
    let __ardos_ld_hook__ = env::var("__ardosLdHook__").unwrap_or_default();

    let tmp_dir = env::var("TMPDIR").unwrap_or_else(|_| "/tmp".to_string());
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let rand_suffix = format!("{:x}", nanos ^ (pid as u128));
    let suffix_trimmed = if rand_suffix.len() > 6 {
        &rand_suffix[..6]
    } else {
        &rand_suffix
    };

    let mut temp_path = PathBuf::from(tmp_dir);
    temp_path.push(format!("ardos-runtime-map.{}", suffix_trimmed));
    let mut map_file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&temp_path)?;

    if is_debug() {
        eprintln!(
            "[Ardos Setup] Created translation map at {}",
            temp_path.display()
        );
    }

    println!("export ARDOS_LD_HOOK=\"{}\"", __ardos_ld_hook__);
    println!("export ARDOS_RUNTIME_MAP=\"{}\"", temp_path.display());
    eprintln!(
        "[Ardos Setup] early-init exported: ARDOS_LD_HOOK={} ARDOS_RUNTIME_MAP={} ",
        __ardos_ld_hook__,
        temp_path.display()
    );

    Ok(())
}
