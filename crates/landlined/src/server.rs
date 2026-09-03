//! The WebSocket server: axum router, per-connection protocol handshake
//! and pump loop, plus the local admin unix socket.
//!
//! Normative reference for the wire behavior: `docs/PROTOCOL.md`.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use bytes::Bytes;
use landline_proto::frame::{
    AttachedResp, ClientFrame, ErrCode, ServerFrame, MAX_PAYLOAD, PROTO_VERSION,
};
use tokio::time::timeout;
use uuid::Uuid;

use crate::auth::{self, UnlockGate, UnlockOutcome};
use crate::config::Config;
use crate::session::{AttachArgs, AttachError, Attachment, SessionManager};
// The admin socket, and everything only it uses, is Unix-only.
#[cfg(unix)]
use crate::config;
#[cfg(unix)]
use crate::session::now_unix;

/// The client must send ATTACH within this window (PROTOCOL.md step 1).
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// How long we wait for an UNLOCK reply to NEED_UNLOCK.
const UNLOCK_TIMEOUT: Duration = Duration::from_secs(60);
/// WebSocket close code for protocol errors.
const CLOSE_PROTOCOL_ERROR: u16 = 1002;
/// Replay snapshots are chunked into STDOUT frames of at most this size.
const REPLAY_CHUNK: usize = 900 * 1024;
/// Sent as STDOUT right after ATTACHED, before the replay.
const CLEAR_SCREEN: &[u8] = b"\x1b[2J\x1b[H";

#[derive(Clone)]
struct AppState {
    cfg: Arc<Config>,
    manager: SessionManager,
    gate: UnlockGate,
    host: Arc<str>,
}

fn app_state(cfg: Config) -> AppState {
    let manager = SessionManager::new(cfg.max_sessions, cfg.scrollback_bytes);
    let gate = UnlockGate::new(cfg.unlock_hash.clone());
    AppState {
        cfg: Arc::new(cfg),
        manager,
        gate,
        host: hostname().into(),
    }
}

fn router(state: AppState) -> Router {
    let router = Router::new().route("/v1/shell", get(ws_handler));
    #[cfg(feature = "harness")]
    let router = router.route("/", get(harness_page));
    router.with_state(state)
}

/// LOCAL DEV ONLY: serves the browser harness. See the `harness` note in
/// `auth.rs`; this feature must never be in a release build.
#[cfg(feature = "harness")]
async fn harness_page() -> axum::response::Html<&'static str> {
    axum::response::Html(include_str!("../../../harness/index.html"))
}

/// Runs the daemon: WebSocket listener, admin unix socket, session reaper.
pub async fn run(cfg: Config) -> anyhow::Result<()> {
    let state = app_state(cfg);
    state.manager.spawn_reaper(Duration::from_secs(
        state.cfg.session_ttl_hours.saturating_mul(3600),
    ));

    #[cfg(unix)]
    {
        let manager = state.manager.clone();
        tokio::spawn(async move {
            if let Err(err) = admin_listener(manager).await {
                tracing::error!(%err, "admin socket listener failed");
            }
        });
    }

    let listener = tokio::net::TcpListener::bind(&state.cfg.listen)
        .await
        .with_context(|| format!("failed to bind {}", state.cfg.listen))?;
    tracing::info!(
        listen = %listener.local_addr()?,
        allowed_logins = state.cfg.allowed_logins.len(),
        unlock = if state.cfg.unlock_hash.is_empty() { "no" } else { "yes" },
        "landlined listening"
    );
    axum::serve(listener, router(state))
        .await
        .context("server error")?;
    Ok(())
}

/// Best-effort hostname for the ATTACHED payload.
fn hostname() -> String {
    std::env::var("HOSTNAME")
        .ok()
        .filter(|h| !h.is_empty())
        .or_else(|| {
            std::process::Command::new("hostname")
                .output()
                .ok()
                .and_then(|out| String::from_utf8(out.stdout).ok())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "localhost".to_string())
}

// ---- WebSocket connection handling ----

async fn ws_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    // Identity is verified before the upgrade completes; a bad or missing
    // login is a plain HTTP 403, never an upgraded socket.
    let Some(login) = auth::authenticate(&state.cfg, &headers) else {
        tracing::warn!("rejecting upgrade: missing or unauthorized login");
        return StatusCode::FORBIDDEN.into_response();
    };
    ws.max_message_size(MAX_PAYLOAD + 5)
        .on_upgrade(move |socket| async move {
            tracing::info!(%login, "client connected");
            handle_socket(socket, state).await;
        })
        .into_response()
}

/// Reads WebSocket messages until one client frame (or an error) arrives.
///
/// - `Some(Ok(frame))`: a decoded binary frame.
/// - `Some(Err(()))`: a protocol error (text message or undecodable frame);
///   the caller closes with code 1002.
/// - `None`: the transport is closed or errored (implicit DETACH).
async fn next_client_frame(socket: &mut WebSocket) -> Option<Result<ClientFrame, ()>> {
    loop {
        match socket.recv().await? {
            Ok(Message::Binary(buf)) => return Some(ClientFrame::decode(&buf).map_err(|_| ())),
            Ok(Message::Text(_)) => return Some(Err(())),
            Ok(Message::Ping(_) | Message::Pong(_)) => continue,
            Ok(Message::Close(_)) | Err(_) => return None,
        }
    }
}

async fn send_frame(socket: &mut WebSocket, frame: &ServerFrame) -> bool {
    socket
        .send(Message::Binary(frame.encode().into()))
        .await
        .is_ok()
}

async fn close_with(socket: &mut WebSocket, code: u16, reason: &'static str) {
    let _ = socket
        .send(Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        })))
        .await;
}

fn locked_out_err() -> ServerFrame {
    ServerFrame::Err {
        code: ErrCode::LockedOut,
        message: "too many failed unlock attempts; restart the daemon".to_string(),
    }
}

/// Drives one connection through the PROTOCOL.md handshake, then hands off
/// to the attached pump loop.
async fn handle_socket(mut socket: WebSocket, state: AppState) {
    // 1. ATTACH must arrive within 10s, before any other frame.
    let first = match timeout(HANDSHAKE_TIMEOUT, next_client_frame(&mut socket)).await {
        Ok(Some(Ok(frame))) => frame,
        Ok(Some(Err(()))) => {
            close_with(&mut socket, CLOSE_PROTOCOL_ERROR, "protocol error").await;
            return;
        }
        Ok(None) => return,
        Err(_) => {
            close_with(&mut socket, CLOSE_PROTOCOL_ERROR, "attach timeout").await;
            return;
        }
    };
    let ClientFrame::Attach(req) = first else {
        close_with(&mut socket, CLOSE_PROTOCOL_ERROR, "expected ATTACH").await;
        return;
    };

    // 2. Protocol version.
    if req.proto_version != PROTO_VERSION {
        let _ = send_frame(
            &mut socket,
            &ServerFrame::Err {
                code: ErrCode::ProtocolVersion,
                message: "supported: 1".to_string(),
            },
        )
        .await;
        close_with(
            &mut socket,
            CLOSE_PROTOCOL_ERROR,
            "unsupported protocol version",
        )
        .await;
        return;
    }

    // 3. Unlock (per connection, even when resuming).
    if state.gate.required() && !run_unlock(&mut socket, &state.gate).await {
        return;
    }

    // 4. Resolve the session. A malformed session id can only be an id we
    //    never issued, so it gets SESSION_GONE like any unknown id.
    let session_id = match req.session_id.as_deref().map(Uuid::parse_str).transpose() {
        Ok(id) => id,
        Err(_) => {
            let _ = send_frame(
                &mut socket,
                &ServerFrame::Err {
                    code: ErrCode::SessionGone,
                    message: "unknown session id".to_string(),
                },
            )
            .await;
            let _ = socket.send(Message::Close(None)).await;
            return;
        }
    };
    let (program, args) = state.cfg.resolve_command(req.cmd.as_deref());
    let attachment = match state.manager.attach(AttachArgs {
        session_id,
        program,
        args,
        cwd: req.cwd.clone().map(PathBuf::from),
        cols: req.cols,
        rows: req.rows,
    }) {
        Ok(attachment) => attachment,
        Err(err) => {
            let (code, message) = match err {
                AttachError::SessionGone => {
                    (ErrCode::SessionGone, "unknown session id".to_string())
                }
                AttachError::TooManySessions => (
                    ErrCode::TooManySessions,
                    "session limit reached".to_string(),
                ),
                AttachError::SpawnFailed(msg) => (ErrCode::SpawnFailed, msg),
            };
            let _ = send_frame(&mut socket, &ServerFrame::Err { code, message }).await;
            let _ = socket.send(Message::Close(None)).await;
            return;
        }
    };

    serve_attached(socket, &state, attachment).await;
}

/// PROTOCOL.md step 3: NEED_UNLOCK / UNLOCK exchange. Returns true once
/// unlocked; on false the socket has already been closed.
async fn run_unlock(socket: &mut WebSocket, gate: &UnlockGate) -> bool {
    if gate.locked_out() {
        let _ = send_frame(socket, &locked_out_err()).await;
        let _ = socket.send(Message::Close(None)).await;
        return false;
    }
    let mut attempts_left = gate.attempts_left();
    loop {
        if !send_frame(socket, &ServerFrame::NeedUnlock { attempts_left }).await {
            return false;
        }
        let secret = match timeout(UNLOCK_TIMEOUT, next_client_frame(socket)).await {
            Ok(Some(Ok(ClientFrame::Unlock(secret)))) => secret,
            Ok(Some(Ok(_)) | Some(Err(()))) => {
                close_with(socket, CLOSE_PROTOCOL_ERROR, "expected UNLOCK").await;
                return false;
            }
            Ok(None) => return false,
            Err(_) => {
                close_with(socket, CLOSE_PROTOCOL_ERROR, "unlock timeout").await;
                return false;
            }
        };
        match gate.verify(secret).await {
            UnlockOutcome::Unlocked => return true,
            UnlockOutcome::Wrong {
                attempts_left: left,
            } => attempts_left = left,
            UnlockOutcome::LockedOut => {
                let _ = send_frame(socket, &locked_out_err()).await;
                let _ = socket.send(Message::Close(None)).await;
                return false;
            }
        }
    }
}

/// PROTOCOL.md steps 5-7: ATTACHED, clear-screen, replay, then the
/// bidirectional pump until either side is done.
async fn serve_attached(mut socket: WebSocket, state: &AppState, attachment: Attachment) {
    let Attachment {
        session,
        generation,
        mut rx,
        replay,
    } = attachment;
    let (cols, rows) = session.size();
    let resp = AttachedResp {
        session_id: session.id.to_string(),
        cols,
        rows,
        replay_bytes: replay.len() as u64,
        shell: session.shell.clone(),
        host: state.host.to_string(),
        created_at: session.created_at,
    };

    let mut sent = send_frame(&mut socket, &ServerFrame::Attached(resp)).await
        && send_frame(
            &mut socket,
            &ServerFrame::Stdout(Bytes::from_static(CLEAR_SCREEN)),
        )
        .await;
    if sent {
        for chunk in replay.chunks(REPLAY_CHUNK) {
            if !send_frame(
                &mut socket,
                &ServerFrame::Stdout(Bytes::copy_from_slice(chunk)),
            )
            .await
            {
                sent = false;
                break;
            }
        }
    }
    if !sent {
        session.detach(generation);
        return;
    }

    loop {
        tokio::select! {
            msg = socket.recv() => match msg {
                Some(Ok(Message::Binary(buf))) => match ClientFrame::decode(&buf) {
                    Ok(ClientFrame::Stdin(data)) => {
                        // Child gone => stdin channel closed; EXIT arrives
                        // via rx, so a failed send is simply dropped.
                        let _ = session.stdin.send(data).await;
                    }
                    Ok(ClientFrame::Resize { cols, rows }) => {
                        if let Err(err) = session.resize(cols, rows) {
                            tracing::debug!(id = %session.id, %err, "resize failed");
                        }
                    }
                    Ok(ClientFrame::Ping(payload)) => {
                        if !send_frame(&mut socket, &ServerFrame::Pong(payload)).await {
                            break;
                        }
                    }
                    Ok(ClientFrame::Detach) => {
                        let _ = socket.send(Message::Close(None)).await;
                        break;
                    }
                    Ok(ClientFrame::Kill) => {
                        // The exit pump delivers EXIT via rx, then we close.
                        session.kill();
                    }
                    Ok(ClientFrame::Attach(_) | ClientFrame::Unlock(_)) => {
                        close_with(&mut socket, CLOSE_PROTOCOL_ERROR, "unexpected frame").await;
                        break;
                    }
                    Err(_) => {
                        close_with(&mut socket, CLOSE_PROTOCOL_ERROR, "bad frame").await;
                        break;
                    }
                },
                Some(Ok(Message::Text(_))) => {
                    close_with(&mut socket, CLOSE_PROTOCOL_ERROR, "text message").await;
                    break;
                }
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                // Transport drop is an implicit DETACH.
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
            },
            frame = rx.recv() => match frame {
                // Sender gone (session torn down under us): close.
                None => {
                    let _ = socket.send(Message::Close(None)).await;
                    break;
                }
                Some(frame) => {
                    let terminal = matches!(
                        &frame,
                        ServerFrame::Exit(_)
                            | ServerFrame::Err {
                                code: ErrCode::SessionReplaced | ErrCode::ClientTooSlow,
                                ..
                            }
                    );
                    if !send_frame(&mut socket, &frame).await {
                        break;
                    }
                    if terminal {
                        let _ = socket.send(Message::Close(None)).await;
                        break;
                    }
                }
            }
        }
    }

    // Generation-guarded: a stale connection never detaches a newer client.
    session.detach(generation);
}

// ---- admin unix socket ----

/// Path of the admin unix socket: `admin.sock` next to the config file.
#[cfg(unix)]
pub fn admin_socket_path() -> anyhow::Result<PathBuf> {
    let config = config::config_path()?;
    let dir = config
        .parent()
        .context("config path has no parent directory")?;
    Ok(dir.join("admin.sock"))
}

/// Newline-delimited JSON over a unix socket, one request per connection:
/// `{"op":"list"}` or `{"op":"kill","id":"<uuid>"}`.
#[cfg(unix)]
async fn admin_listener(manager: SessionManager) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let path = admin_socket_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    match std::fs::remove_file(&path) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => {
            return Err(err).with_context(|| format!("failed to remove stale {}", path.display()))
        }
    }
    let listener = tokio::net::UnixListener::bind(&path)
        .with_context(|| format!("failed to bind {}", path.display()))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
        .with_context(|| format!("failed to set permissions on {}", path.display()))?;
    tracing::info!(path = %path.display(), "admin socket listening");
    loop {
        let (stream, _) = listener.accept().await?;
        let manager = manager.clone();
        tokio::spawn(async move {
            if let Err(err) = handle_admin(stream, manager).await {
                tracing::debug!(%err, "admin connection failed");
            }
        });
    }
}

#[cfg(unix)]
async fn handle_admin(
    stream: tokio::net::UnixStream,
    manager: SessionManager,
) -> anyhow::Result<()> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    let (reader, mut writer) = stream.into_split();
    let mut line = String::new();
    tokio::io::BufReader::new(reader)
        .read_line(&mut line)
        .await?;
    let response = admin_response(&manager, line.trim());
    writer.write_all(response.as_bytes()).await?;
    writer.write_all(b"\n").await?;
    Ok(())
}

#[cfg(unix)]
fn admin_response(manager: &SessionManager, line: &str) -> String {
    #[derive(serde::Deserialize)]
    struct AdminReq {
        op: String,
        #[serde(default)]
        id: Option<String>,
    }

    let req: AdminReq = match serde_json::from_str(line) {
        Ok(req) => req,
        Err(err) => {
            return serde_json::json!({ "error": format!("bad request: {err}") }).to_string()
        }
    };
    match req.op.as_str() {
        "list" => {
            let now = now_unix();
            let sessions: Vec<serde_json::Value> = manager
                .list()
                .into_iter()
                .map(|s| {
                    serde_json::json!({
                        "id": s.id.to_string(),
                        "shell": s.shell,
                        "created_at": s.created_at,
                        "attached": s.attached,
                        "last_seen": s.last_seen,
                        "idle_secs": now.saturating_sub(s.last_seen).max(0),
                    })
                })
                .collect();
            serde_json::to_string(&sessions).expect("session list serialization cannot fail")
        }
        "kill" => match req.id.as_deref().map(Uuid::parse_str) {
            Some(Ok(id)) => {
                if manager.kill(id) {
                    r#"{"ok":true}"#.to_string()
                } else {
                    serde_json::json!({ "error": "unknown session id" }).to_string()
                }
            }
            Some(Err(_)) => serde_json::json!({ "error": "invalid session id" }).to_string(),
            None => serde_json::json!({ "error": "kill requires an id" }).to_string(),
        },
        other => serde_json::json!({ "error": format!("unknown op {other:?}") }).to_string(),
    }
}

// ---- integration tests (M1 exit gate) ----

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    use std::net::SocketAddr;

    use futures_util::{SinkExt, StreamExt};
    use landline_proto::frame::AttachReq;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    use tokio_tungstenite::tungstenite::{Error as WsError, Message as TMessage};
    use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

    type WsClient = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

    const LOGIN: &str = "test@example.com";
    const RECV_TIMEOUT: Duration = Duration::from_secs(10);

    fn test_config() -> Config {
        Config {
            listen: "127.0.0.1:0".to_string(),
            allowed_logins: vec![LOGIN.to_string()],
            shell: "/bin/sh".to_string(),
            default_cmd: String::new(),
            session_ttl_hours: 1,
            scrollback_bytes: 16_384,
            max_sessions: 4,
            unlock_hash: String::new(),
        }
    }

    async fn start(cfg: Config) -> SocketAddr {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test listener");
        let addr = listener.local_addr().expect("local addr");
        let app = router(app_state(cfg));
        tokio::spawn(async move {
            axum::serve(listener, app).await.expect("test server");
        });
        addr
    }

    async fn connect(addr: SocketAddr, login: Option<&str>) -> Result<WsClient, Box<WsError>> {
        let mut request = format!("ws://{addr}/v1/shell")
            .into_client_request()
            .expect("client request");
        if let Some(login) = login {
            request
                .headers_mut()
                .insert(auth::LOGIN_HEADER, login.parse().expect("header value"));
        }
        Ok(connect_async(request).await.map_err(Box::new)?.0)
    }

    async fn send(ws: &mut WsClient, frame: ClientFrame) {
        ws.send(TMessage::Binary(frame.encode()))
            .await
            .expect("send frame");
    }

    async fn recv(ws: &mut WsClient) -> ServerFrame {
        timeout(RECV_TIMEOUT, recv_inner(ws))
            .await
            .expect("timed out waiting for a server frame")
    }

    /// Collects STDOUT frames until the accumulated text contains `needle`.
    async fn collect_stdout_until(ws: &mut WsClient, needle: &str) -> String {
        let mut acc = String::new();
        timeout(RECV_TIMEOUT, async {
            while !acc.contains(needle) {
                match recv_inner(ws).await {
                    ServerFrame::Stdout(data) => acc.push_str(&String::from_utf8_lossy(&data)),
                    other => panic!("expected STDOUT while collecting output, got {other:?}"),
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("timed out waiting for {needle:?}; got: {acc:?}"));
        acc
    }

    /// Like `recv` but without its own timeout (callers wrap the loop).
    async fn recv_inner(ws: &mut WsClient) -> ServerFrame {
        loop {
            let msg = ws
                .next()
                .await
                .expect("socket closed while awaiting frame")
                .expect("websocket error while awaiting frame");
            match msg {
                TMessage::Binary(buf) => {
                    return ServerFrame::decode(&buf).expect("decode server frame")
                }
                TMessage::Ping(_) | TMessage::Pong(_) => continue,
                other => panic!("unexpected websocket message: {other:?}"),
            }
        }
    }

    fn attach_req(session_id: Option<String>) -> ClientFrame {
        ClientFrame::Attach(AttachReq {
            proto_version: PROTO_VERSION,
            session_id,
            cmd: None,
            cwd: None,
            cols: 80,
            rows: 24,
        })
    }

    async fn attach(ws: &mut WsClient, session_id: Option<String>) -> AttachedResp {
        send(ws, attach_req(session_id)).await;
        match recv(ws).await {
            ServerFrame::Attached(resp) => resp,
            other => panic!("expected ATTACHED, got {other:?}"),
        }
    }

    // 1. Missing (or unauthorized) login header: rejected with HTTP 403
    //    before the upgrade.
    #[tokio::test]
    async fn rejects_upgrade_without_login_header() {
        let addr = start(test_config()).await;

        for login in [None, Some("intruder@example.com")] {
            match connect(addr, login).await {
                Err(err) => match *err {
                    WsError::Http(response) => {
                        assert_eq!(response.status(), StatusCode::FORBIDDEN)
                    }
                    other => panic!("expected HTTP 403, got {other:?}"),
                },
                Ok(_) => panic!("upgrade unexpectedly succeeded for login {login:?}"),
            }
        }
    }

    // 2. Full happy path: ATTACH new -> ATTACHED, stdin echo comes back.
    #[tokio::test]
    async fn attach_stdin_stdout_happy_path() {
        let addr = start(test_config()).await;
        let mut ws = connect(addr, Some(LOGIN)).await.expect("connect");

        let resp = attach(&mut ws, None).await;
        Uuid::parse_str(&resp.session_id).expect("session_id is a uuid");
        assert_eq!(resp.shell, "/bin/sh");
        assert_eq!((resp.cols, resp.rows), (80, 24));

        send(
            &mut ws,
            ClientFrame::Stdin(Bytes::from_static(b"echo m1-gate\n")),
        )
        .await;
        collect_stdout_until(&mut ws, "m1-gate").await;
    }

    // 3. Resume: drop the socket without DETACH, reconnect with the
    //    session id, get the same session back with the replay.
    #[tokio::test]
    async fn resume_replays_scrollback() {
        let addr = start(test_config()).await;

        let mut ws = connect(addr, Some(LOGIN)).await.expect("connect");
        let resp = attach(&mut ws, None).await;
        let session_id = resp.session_id;
        send(
            &mut ws,
            ClientFrame::Stdin(Bytes::from_static(b"echo m1-gate\n")),
        )
        .await;
        collect_stdout_until(&mut ws, "m1-gate").await;
        // Implicit detach: drop the transport without a DETACH frame.
        drop(ws);
        tokio::time::sleep(Duration::from_millis(100)).await;

        let mut ws = connect(addr, Some(LOGIN)).await.expect("reconnect");
        let resumed = attach(&mut ws, Some(session_id.clone())).await;
        assert_eq!(resumed.session_id, session_id);
        assert!(resumed.replay_bytes > 0, "expected a non-empty replay");
        let replayed = collect_stdout_until(&mut ws, "m1-gate").await;
        assert!(replayed.contains("m1-gate"));
    }

    // 4. Unsupported proto_version -> ERR PROTOCOL_VERSION.
    #[tokio::test]
    async fn wrong_proto_version_is_rejected() {
        let addr = start(test_config()).await;
        let mut ws = connect(addr, Some(LOGIN)).await.expect("connect");

        send(
            &mut ws,
            ClientFrame::Attach(AttachReq {
                proto_version: 99,
                session_id: None,
                cmd: None,
                cwd: None,
                cols: 80,
                rows: 24,
            }),
        )
        .await;
        match recv(&mut ws).await {
            ServerFrame::Err { code, message } => {
                assert_eq!(code, ErrCode::ProtocolVersion);
                assert_eq!(message, "supported: 1");
            }
            other => panic!("expected ERR PROTOCOL_VERSION, got {other:?}"),
        }
    }

    // 5. Unknown session id -> ERR SESSION_GONE.
    #[tokio::test]
    async fn unknown_session_id_is_gone() {
        let addr = start(test_config()).await;
        let mut ws = connect(addr, Some(LOGIN)).await.expect("connect");

        send(&mut ws, attach_req(Some(Uuid::new_v4().to_string()))).await;
        match recv(&mut ws).await {
            ServerFrame::Err { code, .. } => assert_eq!(code, ErrCode::SessionGone),
            other => panic!("expected ERR SESSION_GONE, got {other:?}"),
        }
    }

    // 6. Unlock flow: NEED_UNLOCK, wrong secret decrements attempts,
    //    right secret attaches.
    #[tokio::test]
    async fn unlock_flow() {
        use argon2::password_hash::{rand_core::OsRng, PasswordHasher, SaltString};

        let salt = SaltString::generate(&mut OsRng);
        let hash = argon2::Argon2::default()
            .hash_password(b"letmein", &salt)
            .expect("hash unlock secret")
            .to_string();
        let cfg = Config {
            unlock_hash: hash,
            ..test_config()
        };
        let addr = start(cfg).await;
        let mut ws = connect(addr, Some(LOGIN)).await.expect("connect");

        send(&mut ws, attach_req(None)).await;
        match recv(&mut ws).await {
            ServerFrame::NeedUnlock { attempts_left } => {
                assert_eq!(attempts_left, auth::MAX_UNLOCK_FAILURES)
            }
            other => panic!("expected NEED_UNLOCK, got {other:?}"),
        }

        send(&mut ws, ClientFrame::Unlock("wrong-secret".to_string())).await;
        match recv(&mut ws).await {
            ServerFrame::NeedUnlock { attempts_left } => {
                assert_eq!(attempts_left, auth::MAX_UNLOCK_FAILURES - 1)
            }
            other => panic!("expected NEED_UNLOCK after wrong secret, got {other:?}"),
        }

        send(&mut ws, ClientFrame::Unlock("letmein".to_string())).await;
        match recv(&mut ws).await {
            ServerFrame::Attached(resp) => {
                Uuid::parse_str(&resp.session_id).expect("session_id is a uuid");
            }
            other => panic!("expected ATTACHED after unlock, got {other:?}"),
        }
    }
}
