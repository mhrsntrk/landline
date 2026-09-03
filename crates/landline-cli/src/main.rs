//! Interactive terminal test client for the Landline daemon.
//!
//! Connects to `GET /v1/shell`, attaches (or resumes) a session, puts the
//! local terminal into raw mode, and shuttles bytes both ways per
//! `docs/PROTOCOL.md`. Exit codes: the remote child's code on EXIT, 1 on
//! errors, 2 on SESSION_REPLACED, 3 on an unexpected server-side close.

use std::io::{Read, Write};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use landline_proto::frame::{
    AttachReq, AttachedResp, ClientFrame, ErrCode, ServerFrame, PROTO_VERSION,
};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

type Ws = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;
type WsTx = SplitSink<Ws, Message>;
type WsRx = SplitStream<Ws>;

/// Terminal test client for the Landline daemon.
#[derive(Parser, Debug)]
#[command(name = "landline-cli", version, about)]
struct Args {
    /// WebSocket URL of the daemon (ws:// or wss://).
    #[arg(default_value = "ws://127.0.0.1:7777/v1/shell")]
    url: String,

    /// Session id to resume; omit to create a new session.
    #[arg(long)]
    session: Option<String>,

    /// Value for the `Tailscale-User-Login` upgrade header (local testing
    /// without tailscale serve in front).
    #[arg(long)]
    login: Option<String>,

    /// Unlock secret; falls back to the LANDLINE_UNLOCK environment variable.
    #[arg(long)]
    unlock: Option<String>,
}

/// Restores the terminal on every exit path, including unwinding.
struct RawGuard {
    active: bool,
}

impl RawGuard {
    fn enable() -> Result<Self> {
        // A piped stdin (CI, smoke tests) has no termios to configure; run cooked.
        if !crossterm::tty::IsTty::is_tty(&std::io::stdin()) {
            return Ok(RawGuard { active: false });
        }
        crossterm::terminal::enable_raw_mode().context("failed to enable raw mode")?;
        Ok(RawGuard { active: true })
    }
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        let _ = crossterm::terminal::disable_raw_mode();
    }
}

/// How the main loop ended; reported after the terminal is restored.
enum Outcome {
    /// Server sent EXIT with this code.
    Exited(u32),
    /// Server sent an ERR frame.
    ServerErr(ErrCode, String),
    /// Transport dropped, server closed, or a send failed.
    Disconnected,
    /// The server violated the protocol, or local I/O failed.
    Fatal(String),
}

fn err_code_name(code: ErrCode) -> &'static str {
    match code {
        ErrCode::SessionGone => "SESSION_GONE",
        ErrCode::SessionReplaced => "SESSION_REPLACED",
        ErrCode::Unauthorized => "UNAUTHORIZED",
        ErrCode::LockedOut => "LOCKED_OUT",
        ErrCode::TooManySessions => "TOO_MANY_SESSIONS",
        ErrCode::SpawnFailed => "SPAWN_FAILED",
        ErrCode::ProtocolVersion => "PROTOCOL_VERSION",
        ErrCode::ClientTooSlow => "CLIENT_TOO_SLOW",
    }
}

fn exit_code_for(code: ErrCode) -> i32 {
    if code == ErrCode::SessionReplaced {
        2
    } else {
        1
    }
}

async fn send_frame(tx: &mut WsTx, frame: &ClientFrame) -> Result<()> {
    tx.send(Message::Binary(frame.encode()))
        .await
        .map_err(|e| anyhow!("send failed: {e}"))
}

fn write_stdout(data: &[u8]) -> std::io::Result<()> {
    let mut out = std::io::stdout().lock();
    out.write_all(data)?;
    out.flush()
}

async fn connect(args: &Args) -> Result<Ws> {
    let url = url::Url::parse(&args.url).context("invalid URL")?;
    match url.scheme() {
        "ws" | "wss" => {}
        other => bail!("unsupported URL scheme {other:?} (use ws:// or wss://)"),
    }

    let mut request = args
        .url
        .as_str()
        .into_client_request()
        .context("could not build upgrade request")?;
    if let Some(login) = &args.login {
        let value =
            HeaderValue::from_str(login).context("--login value is not a valid header value")?;
        request.headers_mut().insert("tailscale-user-login", value);
    }

    let (ws, _response) = tokio_tungstenite::connect_async(request)
        .await
        .with_context(|| format!("could not connect to {}", args.url))?;
    Ok(ws)
}

/// Drives ATTACH → (NEED_UNLOCK/UNLOCK)* → ATTACHED. Runs before raw mode,
/// so failures here may freely print to stderr and bail.
async fn handshake(
    tx: &mut WsTx,
    rx: &mut WsRx,
    args: &Args,
    cols: u16,
    rows: u16,
) -> Result<Result<AttachedResp, i32>> {
    let attach = AttachReq {
        proto_version: PROTO_VERSION,
        session_id: args.session.clone(),
        cmd: None,
        cwd: None,
        cols,
        rows,
    };
    send_frame(tx, &ClientFrame::Attach(attach)).await?;

    let unlock = args
        .unlock
        .clone()
        .or_else(|| std::env::var("LANDLINE_UNLOCK").ok());
    let mut unlock_sent = false;

    loop {
        let msg = rx
            .next()
            .await
            .ok_or_else(|| anyhow!("connection closed during handshake"))?
            .context("transport error during handshake")?;
        let data = match msg {
            Message::Binary(data) => data,
            Message::Close(_) => bail!("server closed the connection during handshake"),
            Message::Text(_) => bail!("protocol error: text message from server"),
            _ => continue,
        };
        match ServerFrame::decode(&data).context("bad frame from server")? {
            ServerFrame::Attached(resp) => return Ok(Ok(resp)),
            ServerFrame::NeedUnlock { attempts_left } => {
                if unlock_sent {
                    bail!("unlock secret rejected ({attempts_left} attempts left)");
                }
                let Some(secret) = unlock.as_ref() else {
                    bail!(
                        "server requires an unlock secret; pass --unlock <secret> \
                         or set LANDLINE_UNLOCK"
                    );
                };
                send_frame(tx, &ClientFrame::Unlock(secret.clone())).await?;
                unlock_sent = true;
            }
            ServerFrame::Err { code, message } => {
                eprintln!("error: {}: {}", err_code_name(code), message);
                return Ok(Err(exit_code_for(code)));
            }
            ServerFrame::Exit(code) => {
                eprintln!("exited: {code}");
                return Ok(Err(code as i32));
            }
            // Not expected before ATTACHED, but harmless.
            ServerFrame::Stdout(bytes) => {
                write_stdout(&bytes).context("stdout write failed")?;
            }
            ServerFrame::Pong(_) => {}
        }
    }
}

/// Raw-mode shuttle loop. The caller restores the terminal before reporting
/// the returned outcome.
async fn shuttle(tx: &mut WsTx, rx: &mut WsRx, initial_size: (u16, u16)) -> Outcome {
    // Dedicated thread instead of spawn_blocking: the runtime would otherwise
    // wait on a stdin read that never finishes when it shuts down.
    let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut buf = [0u8; 4096];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if stdin_tx.blocking_send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });

    let mut resize_timer = tokio::time::interval(Duration::from_millis(500));
    let ping_period = Duration::from_secs(30);
    let mut ping_timer =
        tokio::time::interval_at(tokio::time::Instant::now() + ping_period, ping_period);
    let mut last_size = initial_size;
    let mut ping_counter: u64 = 0;
    let mut stdin_open = true;

    loop {
        tokio::select! {
            chunk = stdin_rx.recv(), if stdin_open => {
                match chunk {
                    Some(data) => {
                        if send_frame(tx, &ClientFrame::Stdin(data.into())).await.is_err() {
                            return Outcome::Disconnected;
                        }
                    }
                    None => stdin_open = false,
                }
            }
            _ = resize_timer.tick() => {
                if let Ok(size) = crossterm::terminal::size() {
                    if size != last_size {
                        last_size = size;
                        let frame = ClientFrame::Resize { cols: size.0, rows: size.1 };
                        if send_frame(tx, &frame).await.is_err() {
                            return Outcome::Disconnected;
                        }
                    }
                }
            }
            _ = ping_timer.tick() => {
                ping_counter = ping_counter.wrapping_add(1);
                let frame = ClientFrame::Ping(ping_counter.to_be_bytes());
                if send_frame(tx, &frame).await.is_err() {
                    return Outcome::Disconnected;
                }
            }
            msg = rx.next() => {
                let data = match msg {
                    None | Some(Err(_)) | Some(Ok(Message::Close(_))) => {
                        return Outcome::Disconnected;
                    }
                    Some(Ok(Message::Binary(data))) => data,
                    Some(Ok(Message::Text(_))) => {
                        return Outcome::Fatal(
                            "protocol error: text message from server".into(),
                        );
                    }
                    // WebSocket-level ping/pong; tungstenite answers these.
                    Some(Ok(_)) => continue,
                };
                match ServerFrame::decode(&data) {
                    Ok(ServerFrame::Stdout(bytes)) => {
                        if write_stdout(&bytes).is_err() {
                            return Outcome::Fatal("stdout write failed".into());
                        }
                    }
                    Ok(ServerFrame::Exit(code)) => return Outcome::Exited(code),
                    Ok(ServerFrame::Err { code, message }) => {
                        return Outcome::ServerErr(code, message);
                    }
                    Ok(ServerFrame::Pong(_)) => {}
                    Ok(ServerFrame::Attached(_)) => {
                        return Outcome::Fatal("protocol error: ATTACHED after attach".into());
                    }
                    Ok(ServerFrame::NeedUnlock { .. }) => {
                        return Outcome::Fatal(
                            "protocol error: NEED_UNLOCK after attach".into(),
                        );
                    }
                    Err(e) => return Outcome::Fatal(format!("bad frame from server: {e}")),
                }
            }
        }
    }
}

async fn run(args: Args) -> Result<i32> {
    let ws = connect(&args).await?;
    let (mut tx, mut rx) = ws.split();

    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    let attached = match handshake(&mut tx, &mut rx, &args, cols, rows).await? {
        Ok(attached) => attached,
        Err(exit_code) => return Ok(exit_code),
    };

    let session_id = attached.session_id.clone();
    eprintln!(
        "session {} on {} ({})",
        session_id, attached.host, attached.shell
    );
    eprintln!("all keys pass through; resume later with --session {session_id}");

    let raw = RawGuard::enable()?;
    let outcome = shuttle(&mut tx, &mut rx, (cols, rows)).await;
    drop(raw);

    match outcome {
        Outcome::Exited(code) => {
            eprintln!("exited: {code}");
            Ok(code as i32)
        }
        Outcome::ServerErr(code, message) => {
            eprintln!("error: {}: {}", err_code_name(code), message);
            Ok(exit_code_for(code))
        }
        Outcome::Disconnected => {
            eprintln!("disconnected (resume with --session {session_id})");
            Ok(3)
        }
        Outcome::Fatal(message) => {
            eprintln!("error: {message}");
            Ok(1)
        }
    }
}

#[tokio::main]
async fn main() {
    // wss:// needs a rustls CryptoProvider; tokio-tungstenite does not install one.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let args = Args::parse();

    // Restore the terminal even when unwinding, then run the default hook.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = crossterm::terminal::disable_raw_mode();
        default_hook(info);
    }));

    let code = match run(args).await {
        Ok(code) => code,
        Err(err) => {
            eprintln!("landline-cli: {err:#}");
            1
        }
    };
    // Exits without waiting for the (possibly blocked) stdin reader thread.
    std::process::exit(code);
}
