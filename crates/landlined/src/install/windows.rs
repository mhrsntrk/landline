//! Windows: a scheduled task at logon, not a service.
//!
//! A session-0 Windows service has no interactive window station and
//! cannot host ConPTY sanely, so the daemon runs as a scheduled task in
//! the user's logon session instead (SCOPE.md section 11, risk 4).

use std::path::Path;

use anyhow::{Context, Result};

const TASK_NAME: &str = "Landline";

/// The `/TR` value for schtasks. Kept separate so the template is
/// testable; the exe path is quoted in case it contains spaces.
fn task_run_value(exe: &Path) -> String {
    format!("\"{}\" serve", exe.display())
}

pub fn install() -> Result<()> {
    let exe = std::env::current_exe().context("cannot determine current executable path")?;
    let run = task_run_value(&exe);
    super::run_checked(
        "schtasks",
        &[
            "/Create", "/TN", TASK_NAME, "/SC", "ONLOGON", "/RL", "LIMITED", "/TR", &run, "/F",
        ],
    )?;
    println!("installed scheduled task {TASK_NAME} (runs `landlined serve` at logon)");
    Ok(())
}

pub fn uninstall() -> Result<()> {
    super::run_checked("schtasks", &["/Delete", "/TN", TASK_NAME, "/F"])?;
    println!("removed scheduled task {TASK_NAME}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_template_contains_serve_and_name() {
        let run = task_run_value(Path::new("C:\\Program Files\\landline\\landlined.exe"));
        assert!(run.contains("serve"));
        assert!(run.contains("landlined.exe"));
        assert_eq!(TASK_NAME, "Landline");
    }
}
