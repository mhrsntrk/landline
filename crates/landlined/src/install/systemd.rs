//! Linux: a systemd user unit under `~/.config/systemd/user`.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

const UNIT: &str = "landlined.service";

/// Render the systemd unit. Kept separate from file writing so the
/// template is testable.
fn unit(exe: &Path) -> String {
    format!(
        r#"[Unit]
Description=Landline host daemon
After=network-online.target tailscaled.service

[Service]
ExecStart="{exe}" serve
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
"#,
        exe = exe.display()
    )
}

fn unit_path() -> Result<PathBuf> {
    let config_dir = match std::env::var_os("XDG_CONFIG_HOME") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => super::home_dir()?.join(".config"),
    };
    Ok(config_dir.join("systemd/user").join(UNIT))
}

pub fn install() -> Result<()> {
    let exe = std::env::current_exe().context("cannot determine current executable path")?;

    let unit_path = unit_path()?;
    if let Some(parent) = unit_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    std::fs::write(&unit_path, unit(&exe))
        .with_context(|| format!("failed to write {}", unit_path.display()))?;
    println!("wrote {}", unit_path.display());

    super::run_checked("systemctl", &["--user", "daemon-reload"])?;
    super::run_checked("systemctl", &["--user", "enable", "--now", "landlined"])?;

    let user = std::env::var("USER").unwrap_or_else(|_| "<user>".to_string());
    println!("installed systemd user unit {UNIT}");
    println!(
        "note: on a headless box, run `loginctl enable-linger {user}` so the daemon starts at boot without a login"
    );
    Ok(())
}

pub fn uninstall() -> Result<()> {
    if let Err(err) = super::run_checked("systemctl", &["--user", "disable", "--now", "landlined"])
    {
        println!("systemctl disable failed ({err:#}); the unit may not have been enabled");
    }

    let unit_path = unit_path()?;
    if unit_path.exists() {
        std::fs::remove_file(&unit_path)
            .with_context(|| format!("failed to remove {}", unit_path.display()))?;
        println!("removed {}", unit_path.display());
    } else {
        println!("{} was not present", unit_path.display());
    }

    super::run_checked("systemctl", &["--user", "daemon-reload"])?;
    println!("uninstalled systemd user unit {UNIT}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unit_template_contains_serve_and_name() {
        let rendered = unit(Path::new("/usr/local/bin/landlined"));
        assert!(rendered.contains("serve"));
        assert!(rendered.contains("Landline host daemon"));
        assert!(rendered.contains("/usr/local/bin/landlined"));
        assert!(UNIT.contains("landlined"));
    }
}
