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

/// Spawn `program` (already resolved, e.g. "/bin/zsh" or "pwsh.exe") in a new PTY.
pub fn spawn(
    program: &str,
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
    if let Some(dir) = cwd {
        cmd.cwd(dir);
    }
    #[cfg(unix)]
    cmd.env("TERM", "xterm-256color");

    let mut child = pair
        .slave
        .spawn_command(cmd)
        .with_context(|| format!("failed to spawn {program} in pty"))?;
    // Drop the slave end now that the child holds its own copy; keeping it
    // open would prevent the reader from ever seeing EOF.
    drop(pair.slave);

    let master = pair.master;
    let killer = child.clone_killer();

    // Reader thread: blocking 8 KiB reads from a cloned reader, forwarded to
    // an unbounded channel. Ends on EOF (child exit / master closed) or error.
    let mut reader = master
        .try_clone_reader()
        .context("failed to clone pty reader")?;
    let (output_tx, output_rx) = tokio::sync::mpsc::unbounded_channel::<Bytes>();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
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
        let (pty, mut events) = spawn("/bin/sh", None, 80, 24).expect("spawn /bin/sh");

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

    #[tokio::test]
    async fn kill_resolves_exit() {
        let (mut pty, events) = spawn("/bin/sh", None, 80, 24).expect("spawn /bin/sh");

        pty.kill();
        pty.kill(); // idempotent

        let _code = timeout(Duration::from_secs(10), events.exit)
            .await
            .expect("timed out waiting for exit after kill")
            .expect("exit sender dropped");
    }
}
