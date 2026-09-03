//! macOS: a launchd user agent under `~/Library/LaunchAgents`.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};

const LABEL: &str = "dev.landline.daemon";

/// Render the launchd property list. Kept separate from file writing so
/// the template is testable.
fn plist(exe: &Path, log_dir: &Path) -> String {
    let exe = xml_escape(&exe.display().to_string());
    let log_dir = xml_escape(&log_dir.display().to_string());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{exe}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{log_dir}/landlined.out.log</string>
    <key>StandardErrorPath</key>
    <string>{log_dir}/landlined.err.log</string>
</dict>
</plist>
"#
    )
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn plist_path() -> Result<PathBuf> {
    Ok(super::home_dir()?.join(format!("Library/LaunchAgents/{LABEL}.plist")))
}

/// The current user's uid, for the `gui/<uid>` launchd domain.
fn uid() -> Result<String> {
    let out = Command::new("id")
        .arg("-u")
        .output()
        .context("failed to run `id -u`")?;
    anyhow::ensure!(
        out.status.success(),
        "`id -u` failed ({}): {}",
        out.status,
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

pub fn install() -> Result<()> {
    let exe = std::env::current_exe().context("cannot determine current executable path")?;

    let log_dir = super::home_dir()?.join("Library/Logs/landline");
    std::fs::create_dir_all(&log_dir)
        .with_context(|| format!("failed to create {}", log_dir.display()))?;
    println!("created {}", log_dir.display());

    let plist_path = plist_path()?;
    if let Some(parent) = plist_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    std::fs::write(&plist_path, plist(&exe, &log_dir))
        .with_context(|| format!("failed to write {}", plist_path.display()))?;
    println!("wrote {}", plist_path.display());

    let domain = format!("gui/{}", uid()?);
    let plist_str = plist_path.display().to_string();
    if let Err(err) = super::run_checked("launchctl", &["bootstrap", &domain, &plist_str]) {
        println!("launchctl bootstrap failed ({err:#}); falling back to `launchctl load -w`");
        super::run_checked("launchctl", &["load", "-w", &plist_str])?;
    }
    println!("installed launchd agent {LABEL}");
    Ok(())
}

pub fn uninstall() -> Result<()> {
    let plist_path = plist_path()?;
    let plist_str = plist_path.display().to_string();
    let service = format!("gui/{}/{LABEL}", uid()?);

    if let Err(err) = super::run_checked("launchctl", &["bootout", &service]) {
        println!("launchctl bootout failed ({err:#}); falling back to `launchctl unload -w`");
        if let Err(err) = super::run_checked("launchctl", &["unload", "-w", &plist_str]) {
            println!("launchctl unload failed ({err:#}); the agent may not have been loaded");
        }
    }

    if plist_path.exists() {
        std::fs::remove_file(&plist_path)
            .with_context(|| format!("failed to remove {}", plist_path.display()))?;
        println!("removed {}", plist_path.display());
    } else {
        println!("{} was not present", plist_path.display());
    }
    println!("uninstalled launchd agent {LABEL}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_template_contains_serve_and_label() {
        let rendered = plist(
            Path::new("/usr/local/bin/landlined"),
            Path::new("/Users/me/Library/Logs/landline"),
        );
        assert!(rendered.contains("<string>serve</string>"));
        assert!(rendered.contains("dev.landline.daemon"));
        assert!(rendered.contains("/usr/local/bin/landlined"));
    }
}
