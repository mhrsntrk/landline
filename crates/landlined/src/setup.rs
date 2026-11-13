//! The parts of first-run setup that used to be left to the reader.
//!
//! A fresh config allows nobody, and `tailscale serve` is per-machine state.
//! Both used to be manual steps, and the allowlist one was not in the app, the
//! Homebrew caveats or `install.sh`, so following any of them ended at a 403.
//! `landlined install` now does both when it safely can, and says exactly what
//! it did, and what it left alone and why.

use std::process::Command;

use crate::config::Config;
use crate::doctor;

/// The login Tailscale reports for a node owned by tags rather than a person.
/// Allowing it would let every tagged device on the tailnet in.
const TAGGED_LOGIN: &str = "tagged-devices";

/// The tailnet login of the person who owns this machine, read from
/// `tailscale status --json`.
///
/// `None` for a tagged node: its owner is the tag, not a person, so there is
/// no login that means "the owner of this machine" and guessing one would be
/// a grant nobody asked for.
pub fn owner_login(status: &serde_json::Value) -> Option<String> {
    let me = &status["Self"];
    let tagged = me["Tags"].as_array().is_some_and(|tags| !tags.is_empty());
    if tagged {
        return None;
    }
    let uid = match &me["UserID"] {
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::String(s) => s.clone(),
        _ => return None,
    };
    let login = status["User"][uid.as_str()]["LoginName"].as_str()?.trim();
    if login.is_empty() || login == TAGGED_LOGIN {
        return None;
    }
    Some(login.to_string())
}

/// Add this machine's owner to an empty allowlist.
///
/// Only when the list is empty: a list someone has written is theirs, and
/// appending to it on every `install` would quietly undo a removal.
pub fn ensure_allowed_login(cfg: &mut Config) -> anyhow::Result<()> {
    if !cfg.allowed_logins.is_empty() {
        println!(
            "allowed_logins already set ({}); left unchanged",
            cfg.allowed_logins.join(", ")
        );
        return Ok(());
    }
    let status = match doctor::tailscale_status_json() {
        Ok(status) => status,
        Err(err) => {
            println!("could not read your tailnet login ({err})");
            println!("  allow yourself once Tailscale is running: landlined allow");
            return Ok(());
        }
    };
    match owner_login(&status) {
        Some(login) => {
            cfg.allowed_logins.push(login.clone());
            cfg.save()?;
            println!("allowed {login}, the tailnet login that owns this machine");
            println!("  someone else: landlined allow <login>");
        }
        None => {
            println!("this machine is tagged, so it has no owner login to allow");
            println!("  allow the login your phone uses: landlined allow <login>");
        }
    }
    Ok(())
}

/// `landlined allow [login]`: add a login, defaulting to this machine's owner.
pub fn allow(login: Option<String>) -> anyhow::Result<()> {
    let mut cfg = Config::load()?;
    let login = match login {
        Some(login) => login.trim().to_string(),
        None => {
            let status = doctor::tailscale_status_json().map_err(|err| anyhow::anyhow!(err))?;
            owner_login(&status).ok_or_else(|| {
                anyhow::anyhow!(
                    "this machine is tagged and has no owner login; name one: landlined allow <login>"
                )
            })?
        }
    };
    anyhow::ensure!(!login.is_empty(), "login is empty");
    anyhow::ensure!(
        login != TAGGED_LOGIN,
        "refusing to allow every tagged device"
    );
    if cfg.allowed_logins.contains(&login) {
        println!("{login} is already allowed");
        return Ok(());
    }
    cfg.allowed_logins.push(login.clone());
    cfg.save()?;
    println!("allowed {login}");
    // The daemon reads its config at start, so a running one has not seen this.
    match crate::install::restart() {
        Ok(true) => println!("restarted the daemon so it takes effect"),
        Ok(false) => println!("takes effect when the daemon starts"),
        Err(err) => println!("restart the daemon for this to take effect ({err:#})"),
    }
    Ok(())
}

/// Point `tailscale serve` at the daemon when nothing is served yet.
///
/// Never touches an existing serve config: port 443 may already front
/// something else on this machine, and replacing it would take that offline.
/// Never fails `install` either; the worst case is printing the command.
pub fn ensure_serve(cfg: &Config) {
    let port = match doctor::listen_port(&cfg.listen) {
        Ok(port) => port,
        Err(err) => {
            println!("{err}");
            return;
        }
    };
    let target = format!("http://127.0.0.1:{port}");
    let manual = format!("tailscale serve --bg --https=443 {target}");
    match doctor::serve_state(port) {
        doctor::ServeState::Ours => {
            println!("tailscale serve already forwards to port {port}");
            return;
        }
        doctor::ServeState::Other => {
            println!("tailscale serve is already in use on this machine; left unchanged");
            println!("  to add Landline on 443 yourself: {manual}");
            return;
        }
        doctor::ServeState::Unavailable(err) => {
            println!("could not check tailscale serve ({err})");
            println!("  then run: {manual}");
            return;
        }
        doctor::ServeState::None => {}
    }
    // Inherit stdio: if Serve is not yet enabled on the tailnet, Tailscale
    // prints the link that enables it and waits, and the person running this
    // needs to see that link rather than a hang.
    println!("running: {manual}");
    let ran = Command::new("tailscale")
        .args(["serve", "--bg", "--https=443", &target])
        .status();
    match ran {
        Ok(status) if status.success() => println!("tailscale serve now forwards to port {port}"),
        _ => {
            println!("tailscale serve did not complete; run it yourself:");
            if cfg!(target_os = "linux") {
                println!("  sudo {manual}");
                println!("  (or once: sudo tailscale set --operator=$USER)");
            } else {
                println!("  {manual}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn owner_login_reads_the_user_table() {
        let status = json!({
            "Self": { "UserID": 42, "Tags": null },
            "User": { "42": { "LoginName": "alice@example.com" } }
        });
        assert_eq!(owner_login(&status).as_deref(), Some("alice@example.com"));
    }

    #[test]
    fn owner_login_refuses_a_tagged_node() {
        let status = json!({
            "Self": { "UserID": 42, "Tags": ["tag:server"] },
            "User": { "42": { "LoginName": "alice@example.com" } }
        });
        assert_eq!(owner_login(&status), None);
    }

    #[test]
    fn owner_login_refuses_the_tagged_devices_pseudo_user() {
        let status = json!({
            "Self": { "UserID": 7 },
            "User": { "7": { "LoginName": "tagged-devices" } }
        });
        assert_eq!(owner_login(&status), None);
    }

    #[test]
    fn owner_login_is_none_when_the_user_is_missing() {
        let status = json!({ "Self": { "UserID": 42 }, "User": {} });
        assert_eq!(owner_login(&status), None);
        assert_eq!(owner_login(&json!({})), None);
    }
}
