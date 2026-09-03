mod auth;
mod config;
mod doctor;
mod install;
mod pty;
mod ring;
mod server;
mod session;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "landlined",
    about = "Landline host daemon: your terminal, on your tailnet"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the daemon in the foreground
    Serve,
    /// Install the service unit for this platform (launchd / systemd / scheduled task)
    Install,
    /// Remove the service unit
    Uninstall,
    /// Show daemon and tailscale health
    Status,
    /// Diagnose connectivity: tailscaled, MagicDNS, HTTPS certs, serve mapping, listener
    Doctor,
    /// Manage detached sessions
    Sessions {
        #[command(subcommand)]
        cmd: SessionsCmd,
    },
    /// Print the config file path
    ConfigPath,
    /// Set or clear the unlock secret (argon2id hashed into the config)
    SetUnlock {
        /// Remove the unlock secret instead of setting one
        #[arg(long)]
        clear: bool,
    },
}

#[derive(Subcommand)]
enum SessionsCmd {
    List,
    Kill { id: String },
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "landlined=info".into()),
        )
        .init();
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Serve => {
            let cfg = config::Config::load()?;
            tokio::runtime::Runtime::new()?.block_on(server::run(cfg))
        }
        Cmd::Install => install::install(),
        Cmd::Uninstall => install::uninstall(),
        Cmd::Status => {
            let cfg = config::Config::load()?;
            doctor::status(&cfg)
        }
        Cmd::Doctor => {
            let cfg = config::Config::load()?;
            doctor::run(&cfg)
        }
        Cmd::Sessions { cmd } => {
            let cfg = config::Config::load()?;
            let op = match cmd {
                SessionsCmd::List => r#"{"op":"list"}"#.to_string(),
                SessionsCmd::Kill { id } => format!(r#"{{"op":"kill","id":"{id}"}}"#),
            };
            let resp = admin_request(&cfg, &op)?;
            println!("{resp}");
            Ok(())
        }
        Cmd::ConfigPath => {
            println!("{}", config::config_path()?.display());
            Ok(())
        }
        Cmd::SetUnlock { clear } => set_unlock(clear),
    }
}

/// One-line JSON request/response over the daemon's admin unix socket.
#[cfg(unix)]
fn admin_request(_cfg: &config::Config, op: &str) -> Result<String> {
    use std::io::{BufRead, BufReader, Write};
    let path = server::admin_socket_path()?;
    let mut stream = std::os::unix::net::UnixStream::connect(&path).map_err(|e| {
        anyhow::anyhow!(
            "cannot reach daemon at {} ({e}); is `landlined serve` running?",
            path.display()
        )
    })?;
    stream.write_all(op.as_bytes())?;
    stream.write_all(b"\n")?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    Ok(line.trim_end().to_string())
}

#[cfg(windows)]
fn admin_request(_cfg: &config::Config, _op: &str) -> Result<String> {
    anyhow::bail!("`sessions` is not supported on Windows yet")
}

fn set_unlock(clear: bool) -> Result<()> {
    use argon2::password_hash::{rand_core::OsRng, PasswordHasher, SaltString};
    let mut cfg = config::Config::load()?;
    if clear {
        cfg.unlock_hash = String::new();
        cfg.save()?;
        println!("unlock secret cleared");
        return Ok(());
    }
    let secret = rpassword::prompt_password("new unlock secret: ")?;
    let again = rpassword::prompt_password("repeat: ")?;
    anyhow::ensure!(secret == again, "secrets do not match");
    anyhow::ensure!(secret.len() >= 6, "use at least 6 characters");
    let salt = SaltString::generate(&mut OsRng);
    cfg.unlock_hash = argon2::Argon2::default()
        .hash_password(secret.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!("hash failed: {e}"))?
        .to_string();
    cfg.save()?;
    println!("unlock secret set");
    Ok(())
}
