//! `landlined doctor` and `landlined status`.
//!
//! Serve configuration is per-machine state that drifts; "why can I not
//! reach this machine" needs a one-command answer (SCOPE.md section 7).

use std::net::{TcpStream, ToSocketAddrs};
use std::process::Command;
use std::time::Duration;

use crate::config::Config;

/// Column width for the aligned check names printed by [`run`].
const NAME_WIDTH: usize = 16;

/// Full diagnosis: one aligned line per check. Returns `Err` if any check
/// failed so the process exits nonzero.
pub fn run(cfg: &Config) -> anyhow::Result<()> {
    let mut ok = true;
    let status = tailscale_status_json();

    // 1. tailscale binary on PATH.
    report("tailscale", tailscale_on_path(), &mut ok);

    // 2. tailscaled backend actually running.
    report("backend", backend_check(&status), &mut ok);

    // 3. MagicDNS enabled, otherwise the ts.net name never resolves.
    report("magicdns", magicdns_check(&status), &mut ok);

    // 4. `tailscale serve` forwards to our port.
    report("serve", serve_check(&cfg.listen), &mut ok);

    // 5. The daemon itself is listening.
    report("listener", listener_check(&cfg.listen), &mut ok);

    // 6. Admin socket present (unix only; Windows has no admin socket yet).
    #[cfg(unix)]
    report("admin socket", admin_socket_check(), &mut ok);

    // 7. Somebody is actually allowed in.
    report("allowed_logins", allowed_logins_check(cfg), &mut ok);

    // 8. The URL to enter in the app.
    report("app url", app_url(&status), &mut ok);

    if ok {
        Ok(())
    } else {
        anyhow::bail!("one or more checks failed")
    }
}

/// Short form: daemon reachable, session summary, tailscale backend state.
/// Never returns `Err` just because the daemon is down.
pub fn status(cfg: &Config) -> anyhow::Result<()> {
    match listener_check(&cfg.listen) {
        Ok(_) => println!("{:<10} running (listening at {})", "daemon", cfg.listen),
        Err(_) => println!("{:<10} not running", "daemon"),
    }

    #[cfg(unix)]
    match list_sessions() {
        Ok(lines) => {
            println!("{:<10} {}", "sessions", lines.len());
            for line in lines {
                println!("  {line}");
            }
        }
        Err(reason) => println!("{:<10} unavailable ({reason})", "sessions"),
    }
    #[cfg(windows)]
    println!("{:<10} not supported on Windows yet", "sessions");

    let backend = match tailscale_status_json() {
        Ok(v) => v["BackendState"].as_str().unwrap_or("unknown").to_string(),
        Err(reason) => reason,
    };
    println!("{:<10} {backend}", "tailscale");

    Ok(())
}

/// Print one aligned check line and fold the outcome into `ok`.
fn report(name: &str, result: Result<String, String>, ok: &mut bool) {
    match result {
        Ok(detail) if detail.is_empty() => println!("{name:<NAME_WIDTH$} ok"),
        Ok(detail) => println!("{name:<NAME_WIDTH$} ok ({detail})"),
        Err(reason) => {
            *ok = false;
            println!("{name:<NAME_WIDTH$} FAIL: {reason}");
        }
    }
}

/// Check 1: the tailscale CLI resolves via PATH.
fn tailscale_on_path() -> Result<String, String> {
    match Command::new("tailscale").arg("version").output() {
        Ok(out) if out.status.success() => {
            let version = String::from_utf8_lossy(&out.stdout)
                .lines()
                .next()
                .unwrap_or_default()
                .trim()
                .to_string();
            Ok(version)
        }
        Ok(out) => Err(format!(
            "`tailscale version` exited with {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        )),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            Err("tailscale binary not found on PATH".to_string())
        }
        Err(err) => Err(format!("could not run tailscale: {err}")),
    }
}

/// Run `tailscale status --json` and parse it. Shared by checks 2, 3 and 8.
fn tailscale_status_json() -> Result<serde_json::Value, String> {
    let out = Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .map_err(|err| format!("could not run `tailscale status --json`: {err}"))?;
    if !out.status.success() {
        return Err(format!(
            "`tailscale status --json` exited with {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    serde_json::from_slice(&out.stdout)
        .map_err(|err| format!("could not parse `tailscale status --json`: {err}"))
}

/// Check 2: tailscaled backend state is `Running`.
fn backend_check(status: &Result<serde_json::Value, String>) -> Result<String, String> {
    let status = status.as_ref().map_err(Clone::clone)?;
    match status["BackendState"].as_str() {
        Some("Running") => Ok(String::new()),
        Some(state) => Err(format!("backend state is {state}; run `tailscale up`")),
        None => Err("no BackendState in `tailscale status --json`".to_string()),
    }
}

/// Check 3: MagicDNS is on, so the machine has a ts.net name.
fn magicdns_check(status: &Result<serde_json::Value, String>) -> Result<String, String> {
    let status = status.as_ref().map_err(Clone::clone)?;
    match status["CurrentTailnet"]["MagicDNSSuffix"].as_str() {
        Some(suffix) if !suffix.is_empty() => Ok(suffix.to_string()),
        _ => Err("MagicDNS is disabled; enable it in the tailnet DNS settings".to_string()),
    }
}

/// Check 4: `tailscale serve` is configured and mentions our port.
fn serve_check(listen: &str) -> Result<String, String> {
    let port = listen_port(listen)?;
    let fix = format!("run: tailscale serve --bg --https=443 http://127.0.0.1:{port}");
    let out = Command::new("tailscale")
        .args(["serve", "status"])
        .output()
        .map_err(|err| format!("could not run `tailscale serve status`: {err}"))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    if !out.status.success()
        || text.to_ascii_lowercase().contains("no serve config")
        || text.trim().is_empty()
    {
        return Err(format!("no serve config; {fix}"));
    }
    if text.contains(&port.to_string()) {
        Ok(String::new())
    } else {
        Err(format!("serve config does not mention port {port}; {fix}"))
    }
}

/// Check 5: something (the daemon, hopefully) accepts TCP on `cfg.listen`.
fn listener_check(listen: &str) -> Result<String, String> {
    let addr = listen
        .to_socket_addrs()
        .map_err(|err| format!("cannot resolve listen address {listen:?}: {err}"))?
        .next()
        .ok_or_else(|| format!("listen address {listen:?} resolves to nothing"))?;
    TcpStream::connect_timeout(&addr, Duration::from_secs(2))
        .map(|_| String::new())
        .map_err(|err| {
            format!("nothing listening at {listen} ({err}); is `landlined serve` running?")
        })
}

/// Check 6 (unix): the admin socket file exists.
#[cfg(unix)]
fn admin_socket_check() -> Result<String, String> {
    let path = admin_socket_path().map_err(|err| err.to_string())?;
    if path.exists() {
        Ok(String::new())
    } else {
        Err(format!(
            "{} does not exist; is `landlined serve` running?",
            path.display()
        ))
    }
}

/// Check 7: an empty allowlist means the daemon rejects everyone.
fn allowed_logins_check(cfg: &Config) -> Result<String, String> {
    if cfg.allowed_logins.is_empty() {
        Err("config allows nobody; add your login to allowed_logins".to_string())
    } else {
        Ok(format!("{} login(s)", cfg.allowed_logins.len()))
    }
}

/// Check 8: this machine's ts.net name, as the URL to enter in the app.
fn app_url(status: &Result<serde_json::Value, String>) -> Result<String, String> {
    let status = status.as_ref().map_err(Clone::clone)?;
    match status["Self"]["DNSName"].as_str() {
        Some(name) if !name.is_empty() => {
            Ok(format!("wss://{}/v1/shell", name.trim_end_matches('.')))
        }
        _ => Err("no DNSName in `tailscale status --json`".to_string()),
    }
}

/// Parse the TCP port out of a `host:port` listen address.
fn listen_port(listen: &str) -> Result<u16, String> {
    listen
        .rsplit(':')
        .next()
        .and_then(|port| port.parse().ok())
        .ok_or_else(|| format!("cannot parse a port out of listen address {listen:?}"))
}

/// The daemon's admin socket lives next to the config file.
#[cfg(unix)]
fn admin_socket_path() -> anyhow::Result<std::path::PathBuf> {
    use anyhow::Context as _;
    let config_path = crate::config::config_path()?;
    let dir = config_path
        .parent()
        .context("config path has no parent directory")?;
    Ok(dir.join("admin.sock"))
}

/// Ask the daemon for its sessions over the admin socket; one formatted
/// line per session.
#[cfg(unix)]
fn list_sessions() -> Result<Vec<String>, String> {
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::os::unix::net::UnixStream;

    let path = admin_socket_path().map_err(|err| err.to_string())?;
    let mut stream = UnixStream::connect(&path)
        .map_err(|err| format!("cannot reach admin socket at {} ({err})", path.display()))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    stream
        .write_all(b"{\"op\":\"list\"}\n")
        .map_err(|err| format!("admin socket write failed: {err}"))?;
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .map_err(|err| format!("admin socket read failed: {err}"))?;

    let value: serde_json::Value =
        serde_json::from_str(line.trim()).map_err(|err| format!("bad admin response: {err}"))?;
    let sessions = value
        .get("sessions")
        .and_then(|v| v.as_array())
        .cloned()
        .or_else(|| value.as_array().cloned())
        .ok_or_else(|| format!("unexpected admin response: {}", line.trim()))?;
    Ok(sessions.iter().map(session_line).collect())
}

/// Render one session as `id  shell  attached/detached  idle`.
#[cfg(unix)]
fn session_line(session: &serde_json::Value) -> String {
    let id = session.get("id").and_then(|v| v.as_str()).unwrap_or("?");
    let short: String = id.chars().take(8).collect();
    let shell = session.get("shell").and_then(|v| v.as_str()).unwrap_or("?");
    let attached = match session.get("attached").and_then(|v| v.as_bool()) {
        Some(true) => "attached",
        Some(false) => "detached",
        None => "attached=?",
    };
    let idle = session
        .get("idle_secs")
        .or_else(|| session.get("idle"))
        .map(|v| match v {
            serde_json::Value::Number(n) => humanize_secs(n.as_u64().unwrap_or(0)),
            other => other.as_str().unwrap_or("?").to_string(),
        })
        .unwrap_or_else(|| "?".to_string());
    format!("{short}  shell={shell}  {attached}  idle={idle}")
}

#[cfg(unix)]
fn humanize_secs(secs: u64) -> String {
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m", secs / 60)
    } else {
        format!("{}h", secs / 3600)
    }
}
