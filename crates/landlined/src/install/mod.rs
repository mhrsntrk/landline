//! Service unit installation: launchd (macOS), systemd user unit (Linux),
//! scheduled task (Windows).

#[cfg(target_os = "macos")]
pub mod launchd;
#[cfg(target_os = "linux")]
pub mod systemd;
#[cfg(windows)]
pub mod windows;

use anyhow::{Context, Result};

pub fn install() -> Result<()> {
    platform_install()
}

pub fn uninstall() -> Result<()> {
    platform_uninstall()
}

#[cfg(target_os = "macos")]
use launchd::{install as platform_install, uninstall as platform_uninstall};
#[cfg(target_os = "linux")]
use systemd::{install as platform_install, uninstall as platform_uninstall};
#[cfg(windows)]
use windows::{install as platform_install, uninstall as platform_uninstall};

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn platform_install() -> Result<()> {
    anyhow::bail!("service installation is not supported on this platform")
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn platform_uninstall() -> Result<()> {
    anyhow::bail!("service removal is not supported on this platform")
}

/// The current user's home directory.
#[allow(dead_code)] // referenced only by the platform modules that use it
pub(crate) fn home_dir() -> Result<std::path::PathBuf> {
    directories::BaseDirs::new()
        .map(|dirs| dirs.home_dir().to_path_buf())
        .context("could not determine the home directory")
}

/// Run an external command, failing with its stderr if it exits non-zero.
#[allow(dead_code)] // referenced only by the platform modules that use it
pub(crate) fn run_checked(program: &str, args: &[&str]) -> Result<()> {
    let output = std::process::Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("failed to run {program}"))?;
    anyhow::ensure!(
        output.status.success(),
        "{program} {} failed ({}): {}",
        args.join(" "),
        output.status,
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(())
}
