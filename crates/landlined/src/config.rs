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
    /// Command every new session opens into, e.g. `tmuxon` to land straight
    /// in a tmux session. Empty means a plain shell. It runs through the
    /// login shell in interactive mode, so aliases and rc files apply; see
    /// [`resolve_command`]. An ATTACH `cmd` from the client overrides it.
    pub default_cmd: String,
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
            default_cmd: String::new(),
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

    /// Resolve what a new session opens into, as `(program, argv)`.
    ///
    /// `cmd` is the ATTACH `cmd` sent by the client. See the free function
    /// [`resolve_command`] for the resolution order and the shell wrapping.
    pub fn resolve_command(&self, cmd: Option<&str>) -> (String, Vec<String>) {
        self::resolve_command(&self.resolve_shell(), &self.default_cmd, cmd)
    }
}

/// Resolve what runs in a session's PTY, as `(program, argv)`.
///
/// Priority, highest first:
///
/// 1. `cmd`, the ATTACH `cmd` from the client,
/// 2. `default_cmd` from the config file,
/// 3. the plain shell.
///
/// A blank (empty or whitespace-only) value counts as absent at every step,
/// so an empty `cmd` falls through to `default_cmd` and an empty
/// `default_cmd` falls through to the shell.
///
/// Pure on purpose: `shell` is the already-resolved shell (see
/// [`Config::resolve_shell`]), so the whole decision is one testable
/// function with no environment lookups of its own.
pub fn resolve_command(shell: &str, default_cmd: &str, cmd: Option<&str>) -> (String, Vec<String>) {
    match cmd.and_then(non_blank).or_else(|| non_blank(default_cmd)) {
        Some(command) => shell_command(shell, command),
        None => plain_shell(shell),
    }
}

/// `value` trimmed, or `None` when it is empty or all whitespace.
fn non_blank(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

/// Run `command` through `shell`.
#[cfg(unix)]
fn shell_command(shell: &str, command: &str) -> (String, Vec<String>) {
    // `-i` is deliberate and load-bearing, not a stray flag. A startup
    // command is written by a human in their own config, so it routinely
    // names an alias, a shell function, or a binary on an rc-file PATH, and
    // none of those exist in a non-interactive shell: `zsh -c 'tmuxon'`
    // fails with "command not found" while `zsh -i -c 'tmuxon'` works,
    // because only interactive mode sources ~/.zshrc. Dropping `-i` here
    // silently breaks every alias-based startup command.
    (
        shell.to_string(),
        vec!["-i".to_string(), "-c".to_string(), command.to_string()],
    )
}

/// Spawn `shell` on its own, with no command.
#[cfg(unix)]
fn plain_shell(shell: &str) -> (String, Vec<String>) {
    // `-l`: the daemon is started by launchd/systemd, whose environment is
    // nothing like a terminal login's, so a login shell is what makes the
    // session's PATH and environment match what the user sees locally.
    (shell.to_string(), vec!["-l".to_string()])
}

/// Run `command` through `shell`.
#[cfg(windows)]
fn shell_command(shell: &str, command: &str) -> (String, Vec<String>) {
    // Same intent as the Unix arm (run the command inside a shell, then
    // leave the user at a prompt), with the flags each Windows shell
    // actually has: PowerShell has no `-i`, and its `-Command` exits when
    // the command finishes unless `-NoExit` keeps the session alive.
    if is_powershell(shell) {
        (
            shell.to_string(),
            vec![
                "-NoExit".to_string(),
                "-Command".to_string(),
                command.to_string(),
            ],
        )
    } else if is_cmd_exe(shell) {
        // cmd.exe: `/K` runs the command and keeps the shell open (`/C`
        // would exit and end the session).
        (
            shell.to_string(),
            vec!["/K".to_string(), command.to_string()],
        )
    } else {
        // Anything else configured as the shell on Windows is almost
        // certainly a Unix-style shell (Git for Windows bash, MSYS2), so
        // use the Unix flags.
        (
            shell.to_string(),
            vec!["-i".to_string(), "-c".to_string(), command.to_string()],
        )
    }
}

/// Spawn `shell` on its own, with no command.
#[cfg(windows)]
fn plain_shell(shell: &str) -> (String, Vec<String>) {
    // No `-l` equivalent: Windows shells have no login-shell mode, and both
    // PowerShell and cmd.exe read their profiles on every start.
    (shell.to_string(), Vec::new())
}

/// Lowercased file name of `shell`, without any `.exe` suffix.
#[cfg(windows)]
fn shell_stem(shell: &str) -> String {
    std::path::Path::new(shell)
        .file_stem()
        .map(|stem| stem.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

#[cfg(windows)]
fn is_powershell(shell: &str) -> bool {
    matches!(shell_stem(shell).as_str(), "pwsh" | "powershell")
}

#[cfg(windows)]
fn is_cmd_exe(shell: &str) -> bool {
    shell_stem(shell) == "cmd"
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
        assert_eq!(config.default_cmd, "");
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
            default_cmd: "tmuxon".to_string(),
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
        assert_eq!(parsed.default_cmd, config.default_cmd);
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
        assert_eq!(config.default_cmd, "");
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
    fn default_cmd_parses_from_toml() {
        let toml = "shell = \"/bin/zsh\"\ndefault_cmd = \"tmuxon\"\n";
        let config: Config = toml::from_str(toml).expect("parse config with default_cmd");
        assert_eq!(config.default_cmd, "tmuxon");
    }

    // ---- command resolution ----

    #[cfg(unix)]
    #[test]
    fn resolve_command_prefers_attach_cmd() {
        let (program, args) = resolve_command("/bin/zsh", "tmuxon", Some("htop"));
        assert_eq!(program, "/bin/zsh");
        assert_eq!(args, ["-i", "-c", "htop"]);
    }

    #[cfg(unix)]
    #[test]
    fn resolve_command_falls_back_to_default_cmd() {
        let (program, args) = resolve_command("/bin/zsh", "tmuxon", None);
        assert_eq!(program, "/bin/zsh");
        assert_eq!(args, ["-i", "-c", "tmuxon"]);
    }

    #[cfg(unix)]
    #[test]
    fn resolve_command_falls_back_to_login_shell() {
        let (program, args) = resolve_command("/bin/zsh", "", None);
        assert_eq!(program, "/bin/zsh");
        assert_eq!(args, ["-l"]);
    }

    #[cfg(unix)]
    #[test]
    fn resolve_command_treats_blank_as_absent() {
        // Blank ATTACH cmd falls through to default_cmd.
        let (_, args) = resolve_command("/bin/zsh", "tmuxon", Some("   "));
        assert_eq!(args, ["-i", "-c", "tmuxon"]);
        // Blank default_cmd falls through to the plain shell.
        let (_, args) = resolve_command("/bin/zsh", "  \t ", None);
        assert_eq!(args, ["-l"]);
        // Surrounding whitespace is trimmed off a real command.
        let (_, args) = resolve_command("/bin/zsh", "", Some(" tmuxon\n"));
        assert_eq!(args, ["-i", "-c", "tmuxon"]);
    }

    #[cfg(unix)]
    #[test]
    fn resolve_command_uses_the_configured_shell() {
        let config = Config {
            shell: "/usr/bin/fish".to_string(),
            default_cmd: "tmuxon".to_string(),
            ..Config::default()
        };
        assert_eq!(
            config.resolve_command(None),
            (
                "/usr/bin/fish".to_string(),
                vec!["-i".to_string(), "-c".to_string(), "tmuxon".to_string()]
            )
        );
    }

    #[cfg(windows)]
    #[test]
    fn resolve_command_windows_shell_flags() {
        let (program, args) = resolve_command("pwsh.exe", "", Some("btop"));
        assert_eq!(program, "pwsh.exe");
        assert_eq!(args, ["-NoExit", "-Command", "btop"]);

        let (_, args) = resolve_command("C:\\Windows\\System32\\cmd.exe", "btop", None);
        assert_eq!(args, ["/K", "btop"]);

        let (_, args) = resolve_command("powershell.exe", "", None);
        assert!(args.is_empty());
    }

    #[test]
    fn config_path_ends_with_config_toml() {
        let path = config_path().expect("config_path should succeed");
        assert!(path.ends_with("config.toml"));
    }
}
