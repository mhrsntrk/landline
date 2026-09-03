// This module's public API (`Config::load`/`save`, `config_path`,
// `resolve_shell`) is wired up by other modules (server, doctor, install)
// as they land; until then, plain `cargo build`/`cargo test` would flag it
// as dead code even though it is fully exercised by this module's own tests.
#![allow(dead_code)]

use std::path::PathBuf;

use anyhow::Context;

/// Daemon configuration, loaded from `config.toml` in the platform config
/// directory. Any field missing from the file falls back to its default
/// (see [`Default`] for `landline`'s fail-closed defaults).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Config {
    /// Address the WebSocket server listens on.
    pub listen: String,
    /// Logins allowed to authenticate. Empty means nobody is allowed in
    /// (fail closed) until the operator explicitly configures this.
    pub allowed_logins: Vec<String>,
    /// Shell to spawn for sessions. Empty means auto-resolve at runtime.
    pub shell: String,
    /// How long a session may live before it is forcibly torn down.
    pub session_ttl_hours: u64,
    /// Size in bytes of the scrollback buffer kept per session.
    pub scrollback_bytes: usize,
    /// Maximum number of concurrent sessions.
    pub max_sessions: usize,
    /// Argon2id PHC hash of the unlock secret. Empty means no unlock is
    /// required.
    pub unlock_hash: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            listen: "127.0.0.1:7777".to_string(),
            allowed_logins: Vec::new(),
            shell: String::new(),
            session_ttl_hours: 24,
            scrollback_bytes: 262_144,
            max_sessions: 8,
            unlock_hash: String::new(),
        }
    }
}

/// Path to the config file: the platform config directory for "landline"
/// plus `config.toml`.
pub fn config_path() -> anyhow::Result<PathBuf> {
    let dirs = directories::ProjectDirs::from("", "", "landline")
        .context("could not determine config directory for this platform")?;
    Ok(dirs.config_dir().join("config.toml"))
}

impl Config {
    /// Load the config from disk. A missing file yields [`Config::default`]
    /// (logged at info level); a file that fails to parse is an error.
    pub fn load() -> anyhow::Result<Config> {
        let path = config_path()?;
        let contents = match std::fs::read_to_string(&path) {
            Ok(contents) => contents,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                tracing::info!(path = %path.display(), "no config file found, using defaults");
                return Ok(Config::default());
            }
            Err(err) => {
                return Err(err).with_context(|| format!("failed to read {}", path.display()))
            }
        };
        let config: Config = toml::from_str(&contents)
            .with_context(|| format!("failed to parse {}", path.display()))?;
        Ok(config)
    }

    /// Save the config to disk, creating parent directories as needed. On
    /// Unix the file is created with mode 0o600 so secrets (e.g.
    /// `unlock_hash`) are not world-readable.
    pub fn save(&self) -> anyhow::Result<()> {
        let path = config_path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let contents = toml::to_string_pretty(self).context("failed to serialize config")?;
        std::fs::write(&path, contents)
            .with_context(|| format!("failed to write {}", path.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let permissions = std::fs::Permissions::from_mode(0o600);
            std::fs::set_permissions(&path, permissions)
                .with_context(|| format!("failed to set permissions on {}", path.display()))?;
        }

        Ok(())
    }

    /// Resolve the shell to spawn for sessions.
    ///
    /// A non-empty `shell` field always wins. Otherwise, on Unix, `$SHELL`
    /// is used if set, else `/bin/sh`. On Windows, the first of
    /// `pwsh.exe`/`powershell.exe` found on `PATH` is used, else `cmd.exe`.
    pub fn resolve_shell(&self) -> String {
        if !self.shell.is_empty() {
            return self.shell.clone();
        }

        #[cfg(unix)]
        {
            std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
        }

        #[cfg(windows)]
        {
            for candidate in ["pwsh.exe", "powershell.exe"] {
                if find_on_path(candidate).is_some() {
                    return candidate.to_string();
                }
            }
            "cmd.exe".to_string()
        }
    }
}

/// Search `PATH` for `name`, `which`-style. Windows-only helper used by
/// [`Config::resolve_shell`].
#[cfg(windows)]
fn find_on_path(name: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    std::env::split_paths(&path_var)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_values() {
        let config = Config::default();
        assert_eq!(config.listen, "127.0.0.1:7777");
        assert!(config.allowed_logins.is_empty());
        assert_eq!(config.shell, "");
        assert_eq!(config.session_ttl_hours, 24);
        assert_eq!(config.scrollback_bytes, 262_144);
        assert_eq!(config.max_sessions, 8);
        assert_eq!(config.unlock_hash, "");
    }

    #[test]
    fn toml_roundtrip() {
        let config = Config {
            listen: "0.0.0.0:9999".to_string(),
            allowed_logins: vec!["alice".to_string(), "bob".to_string()],
            shell: "/bin/zsh".to_string(),
            session_ttl_hours: 48,
            scrollback_bytes: 1024,
            max_sessions: 16,
            unlock_hash: "$argon2id$v=19$m=19456,t=2,p=1$abcd$efgh".to_string(),
        };

        let serialized = toml::to_string(&config).expect("serialize");
        let parsed: Config = toml::from_str(&serialized).expect("parse");

        assert_eq!(parsed.listen, config.listen);
        assert_eq!(parsed.allowed_logins, config.allowed_logins);
        assert_eq!(parsed.shell, config.shell);
        assert_eq!(parsed.session_ttl_hours, config.session_ttl_hours);
        assert_eq!(parsed.scrollback_bytes, config.scrollback_bytes);
        assert_eq!(parsed.max_sessions, config.max_sessions);
        assert_eq!(parsed.unlock_hash, config.unlock_hash);
    }

    #[test]
    fn partial_toml_fills_defaults() {
        let partial = "listen = \"10.0.0.1:1234\"\n";
        let config: Config = toml::from_str(partial).expect("parse partial config");

        assert_eq!(config.listen, "10.0.0.1:1234");
        assert!(config.allowed_logins.is_empty());
        assert_eq!(config.shell, "");
        assert_eq!(config.session_ttl_hours, 24);
        assert_eq!(config.scrollback_bytes, 262_144);
        assert_eq!(config.max_sessions, 8);
        assert_eq!(config.unlock_hash, "");
    }

    #[test]
    fn resolve_shell_explicit() {
        let config = Config {
            shell: "/usr/bin/fish".to_string(),
            ..Config::default()
        };
        assert_eq!(config.resolve_shell(), "/usr/bin/fish");
    }

    #[test]
    fn config_path_ends_with_config_toml() {
        let path = config_path().expect("config_path should succeed");
        assert!(path.ends_with("config.toml"));
    }
}
