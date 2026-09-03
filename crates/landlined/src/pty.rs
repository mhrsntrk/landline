//! Bridge between the blocking portable-pty API and tokio.
//!
//! Each session owns three dedicated OS threads (reader, writer, reaper).
//! We deliberately use `std::thread::spawn` instead of `spawn_blocking`:
//! these threads live for the whole session and would otherwise pin
//! runtime blocking-pool slots.

use std::io::{Read, Write};
use std::path::Path;

use anyhow::Context;
use bytes::Bytes;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use tracing::debug;

/// Handle to a running PTY session.
///
/// Dropping a `Pty` closes the stdin channel (ending the writer thread) and
/// drops the master PTY (EOF-ing the reader thread). The reaper thread ends
/// when the child exits.
pub struct Pty {
    /// Bytes sent here are written to the child's terminal input.
    pub stdin: tokio::sync::mpsc::Sender<Bytes>,
    /// Master side of the PTY. Must stay alive while the child runs;
    /// dropping it while the child lives kills I/O.
    master: Box<dyn MasterPty + Send>,
    /// Best-effort child terminator, cloned before the child moved into the
    /// reaper thread.
    killer: Box<dyn ChildKiller + Send + Sync>,
}

/// Streams produced by a PTY session.
pub struct PtyEvents {
    /// Raw terminal output chunks.
    pub output: tokio::sync::mpsc::UnboundedReceiver<Bytes>,
    /// Resolves with the child's exit code once it terminates.
    pub exit: tokio::sync::oneshot::Receiver<u32>,
}

/// Spawn `program` with `args` (both already resolved, e.g. "/bin/zsh" with
/// `["-l"]`, or "/bin/zsh" with `["-i", "-c", "tmuxon"]`) in a new PTY.
///
/// See `Config::resolve_command` for how the pair is derived from the ATTACH
/// `cmd`, the `default_cmd` config key, and the configured shell.
pub fn spawn(
    program: &str,
    args: &[String],
    cwd: Option<&Path>,
    cols: u16,
    rows: u16,
) -> anyhow::Result<(Pty, PtyEvents)> {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .context("failed to open pty")?;

    let mut cmd = CommandBuilder::new(program);
    cmd.args(args);
    if let Some(dir) = cwd {
        cmd.cwd(dir);
    }
    #[cfg(unix)]
    apply_terminal_env(&mut cmd);

    let mut child = pair
        .slave
        .spawn_command(cmd)
        .with_context(|| format!("failed to spawn {program} in pty"))?;
    // Drop the slave end now that the child holds its own copy; keeping it
    // open would prevent the reader from ever seeing EOF.
    drop(pair.slave);

    let master = pair.master;
    let killer = child.clone_killer();

    // Reader thread: blocking 64 KiB reads from a cloned reader, forwarded to
    // an unbounded channel. Ends on EOF (child exit / master closed) or error.
    //
    // 64 KiB rather than 8 KiB: a fast-scrolling build log or a `cat` of a
    // large file fills the pty buffer faster than 8 KiB reads drain it, so
    // small reads cost one syscall and one channel message per 8 KiB and
    // fragment the output into many tiny WebSocket frames. The buffer is one
    // allocation per session, so the extra memory is irrelevant.
    let mut reader = master
        .try_clone_reader()
        .context("failed to clone pty reader")?;
    let (output_tx, output_rx) = tokio::sync::mpsc::unbounded_channel::<Bytes>();
    std::thread::spawn(move || {
        let mut buf = [0u8; 65536];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if output_tx.send(Bytes::copy_from_slice(&buf[..n])).is_err() {
                        // Receiver gone; nobody cares about output any more.
                        break;
                    }
                }
            }
        }
        debug!("pty reader thread ended");
    });

    // Writer thread: drains the bounded stdin channel into the pty writer.
    // Ends when every stdin sender is dropped or a write fails.
    let mut writer = master.take_writer().context("failed to take pty writer")?;
    let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::channel::<Bytes>(64);
    std::thread::spawn(move || {
        while let Some(chunk) = stdin_rx.blocking_recv() {
            if writer
                .write_all(&chunk)
                .and_then(|_| writer.flush())
                .is_err()
            {
                break;
            }
        }
        debug!("pty writer thread ended");
    });

    // Reaper thread: waits for the child and reports its exit code.
    let (exit_tx, exit_rx) = tokio::sync::oneshot::channel::<u32>();
    std::thread::spawn(move || {
        let code = match child.wait() {
            Ok(status) => status.exit_code(),
            Err(_) => u32::MAX,
        };
        // Receiver may already be gone; that's fine.
        let _ = exit_tx.send(code);
        debug!(code, "pty reaper thread ended");
    });

    Ok((
        Pty {
            stdin: stdin_tx,
            master,
            killer,
        },
        PtyEvents {
            output: output_rx,
            exit: exit_rx,
        },
    ))
}

/// Set up the child's terminal environment.
///
/// The daemon is started by launchd/systemd, not from a terminal, so the
/// environment it hands down describes no terminal at all. Everything here
/// is about making the session behave like the one the user gets locally.
#[cfg(unix)]
fn apply_terminal_env(cmd: &mut CommandBuilder) {
    // What the client renders.
    cmd.env("TERM", "xterm-256color");
    // Without COLORTERM, programs that check it (vim, delta, bat, eza, most
    // modern TUIs) fall back to 256-color approximations of their 24-bit
    // themes, which is visibly wrong rather than merely plainer.
    cmd.env("COLORTERM", "truecolor");

    // Locale: preserve whatever the daemon inherited, and only supply a
    // default when it has neither. A missing UTF-8 locale is the classic
    // cause of broken box-drawing characters (tmux panes and vim splits
    // drawn with `qqqq` and `xxxx`) and of mangled multibyte input.
    let lang = std::env::var_os("LANG");
    let lc_all = std::env::var_os("LC_ALL");
    if lang.is_none() && lc_all.is_none() {
        cmd.env("LANG", "en_US.UTF-8");
    } else {
        if let Some(lang) = lang {
            cmd.env("LANG", lang);
        }
        if let Some(lc_all) = lc_all {
            cmd.env("LC_ALL", lc_all);
        }
    }

    // A daemon that was itself started from inside a tmux session inherits
    // $TMUX, and every child then believes it is already inside tmux:
    // `tmux attach` refuses with "sessions should be nested with care",
    // which is exactly the case landline exists to serve. The session is a
    // fresh terminal, so the variable is a lie either way.
    cmd.env_remove("TMUX");
}

impl Pty {
    /// Resize the terminal.
    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        self.master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("failed to resize pty")
    }

    /// Terminate the child. Idempotent, best-effort.
    pub fn kill(&mut self) {
        if let Err(err) = self.killer.kill() {
            debug!(%err, "pty kill (best-effort) failed");
        }
    }
}

#[cfg(test)]
#[cfg(unix)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::time::timeout;

    async fn collect_until(events: &mut PtyEvents, needle: &str) -> String {
        let mut collected = String::new();
        timeout(Duration::from_secs(10), async {
            while !collected.contains(needle) {
                let chunk = events
                    .output
                    .recv()
                    .await
                    .expect("output channel closed before needle appeared");
                collected.push_str(&String::from_utf8_lossy(&chunk));
            }
        })
        .await
        .unwrap_or_else(|_| panic!("timed out waiting for {needle:?}; got: {collected:?}"));
        collected
    }

    #[tokio::test]
    async fn echo_and_clean_exit() {
        let (pty, mut events) = spawn("/bin/sh", &[], None, 80, 24).expect("spawn /bin/sh");

        pty.stdin
            .send(Bytes::from_static(b"echo hello-pty\n"))
            .await
            .expect("send echo command");
        collect_until(&mut events, "hello-pty").await;

        pty.stdin
            .send(Bytes::from_static(b"exit\n"))
            .await
            .expect("send exit");
        let code = timeout(Duration::from_secs(10), events.exit)
            .await
            .expect("timed out waiting for exit")
            .expect("exit sender dropped");
        assert_eq!(code, 0);
    }

    // argv reaches the child: `sh -c "echo argv-works"` prints and exits.
    #[tokio::test]
    async fn args_are_passed_to_the_child() {
        let args = ["-c".to_string(), "echo argv-works".to_string()];
        let (_pty, mut events) = spawn("/bin/sh", &args, None, 80, 24).expect("spawn /bin/sh -c");

        collect_until(&mut events, "argv-works").await;
        let code = timeout(Duration::from_secs(10), events.exit)
            .await
            .expect("timed out waiting for exit")
            .expect("exit sender dropped");
        assert_eq!(code, 0);
    }

    #[tokio::test]
    async fn kill_resolves_exit() {
        let (mut pty, events) = spawn("/bin/sh", &[], None, 80, 24).expect("spawn /bin/sh");

        pty.kill();
        pty.kill(); // idempotent

        let _code = timeout(Duration::from_secs(10), events.exit)
            .await
            .expect("timed out waiting for exit after kill")
            .expect("exit sender dropped");
    }
}
