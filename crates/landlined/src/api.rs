//! The HTTP endpoints that sit beside `/v1/shell` on the same listener.
//!
//! Normative reference: `docs/HTTP.md`. Three families, one gate:
//!
//! - `POST /v1/token`, which turns the unlock secret into a bearer token
//! - `/v1/files`, the inbox (`crate::files`), phone to host
//! - `/v1/sessions` and `/v1/outbox`, here
//!
//! Every one of them checks the tailnet login exactly as the WebSocket upgrade
//! does, and every one but the token endpoint additionally spends a token. That
//! is the whole authorization story, and `require_token` is the one place it
//! is written down.
//!
//! None of this widens what the credentials already grant. Anyone through the
//! login allowlist and the unlock secret has an interactive shell, which can
//! list its own processes, kill them, and read any file on the machine. These
//! endpoints do strictly less, and the outbox in particular reads only what a
//! local process explicitly offered.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::body::Body;
use axum::extract::{Path as UrlPath, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use uuid::Uuid;

use crate::auth::{self, UnlockOutcome, TOKEN_TTL};
use crate::server::AppState;

/// Longest accepted unlock secret on the token endpoint. Re-exported from
/// `auth`, which enforces the same ceiling on the WebSocket UNLOCK frame, so
/// the two doors cannot drift apart.
pub use crate::auth::MAX_SECRET_LEN;

// ---- shared shapes ----

#[derive(serde::Serialize)]
pub struct ErrResp {
    pub error: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attempts_left: Option<u32>,
}

/// One refusal, as JSON. Every endpoint answers in this shape so a client has
/// one thing to parse rather than one per route.
pub fn err(status: StatusCode, error: &'static str) -> Response {
    (
        status,
        Json(ErrResp {
            error,
            attempts_left: None,
        }),
    )
        .into_response()
}

/// The bearer token on a request, if it carries a well-formed one.
pub fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .filter(|token| !token.is_empty())
}

/// The authenticated login for a request that carries both a permitted tailnet
/// identity and a live token minted for it, or the refusal to answer with.
///
/// Both halves are load-bearing and they answer different questions. The login
/// says which tailnet user is calling, and `tailscale serve` is what makes it
/// unforgeable. The token says that whoever is calling knew the unlock secret,
/// which is what a stolen, unlocked phone on the tailnet does not.
pub fn require_token(state: &AppState, headers: &HeaderMap) -> Result<String, Box<Response>> {
    let Some(login) = auth::authenticate(&state.cfg, headers) else {
        return Err(Box::new(err(StatusCode::FORBIDDEN, "unauthorized")));
    };
    let Some(token) = bearer(headers) else {
        return Err(Box::new(err(StatusCode::UNAUTHORIZED, "missing_token")));
    };
    if !state.tokens.check(token, &login) {
        return Err(Box::new(err(StatusCode::UNAUTHORIZED, "bad_token")));
    }
    Ok(login)
}

// ---- POST /v1/token ----

#[derive(serde::Serialize)]
struct TokenResp {
    token: String,
    expires_in: u64,
    /// Advertised so a client can refuse an oversized file before sending it.
    /// Zero when the inbox is not served here.
    max_bytes: u64,
    /// What this daemon can do beyond the shell, so a client can hide what is
    /// not there rather than discovering it by 404. Additive by design: an
    /// older app ignores a name it does not know.
    features: Vec<&'static str>,
}

/// `POST /v1/token`: exchanges the unlock secret for a short-lived bearer
/// token. The request body is the secret, verbatim; empty on a host with no
/// unlock configured.
///
/// Wrong secrets go through the same [`crate::auth::UnlockGate`] the shell
/// handshake uses, so they serve the same backoff and spend the same failure
/// budget. Guessing here locks out the shell too, which is intended: there is
/// one secret and it has one budget.
pub async fn token_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: String,
) -> Response {
    let Some(login) = auth::authenticate(&state.cfg, &headers) else {
        return err(StatusCode::FORBIDDEN, "unauthorized");
    };
    if body.len() > MAX_SECRET_LEN {
        return err(StatusCode::BAD_REQUEST, "secret_too_long");
    }

    match state.gate.verify(body).await {
        UnlockOutcome::Unlocked => {
            let token = state.tokens.issue(&login);
            tracing::info!(%login, "issued api token");
            let mut features = vec!["sessions", "outbox"];
            if state.files.is_some() {
                features.push("files");
            }
            Json(TokenResp {
                token,
                expires_in: TOKEN_TTL.as_secs(),
                max_bytes: state.files.as_ref().map(|f| f.max_bytes).unwrap_or(0),
                features,
            })
            .into_response()
        }
        UnlockOutcome::Wrong { attempts_left } => (
            StatusCode::UNAUTHORIZED,
            Json(ErrResp {
                error: "bad_secret",
                attempts_left: Some(attempts_left),
            }),
        )
            .into_response(),
        UnlockOutcome::LockedOut => err(StatusCode::TOO_MANY_REQUESTS, "locked_out"),
    }
}

// ---- /v1/sessions ----

#[derive(serde::Serialize)]
struct SessionResp {
    id: String,
    shell: String,
    created_at: i64,
    attached: bool,
    idle_secs: i64,
}

/// `GET /v1/sessions`: what is running on this host, so the phone that
/// orphaned a session can see it.
///
/// The daemon has always known this; until now only a local process could ask,
/// through the admin socket, which is exactly the machine you are not sitting
/// at when it matters.
pub async fn sessions_handler(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if let Err(refusal) = require_token(&state, &headers) {
        return *refusal;
    }
    let now = crate::session::now_unix();
    let mut sessions: Vec<SessionResp> = state
        .manager
        .list()
        .into_iter()
        .map(|info| SessionResp {
            id: info.id.to_string(),
            shell: info.shell,
            created_at: info.created_at,
            attached: info.attached,
            idle_secs: (now - info.last_seen).max(0),
        })
        .collect();
    // Newest first: the one you just lost is the one you are looking for.
    sessions.sort_by_key(|session| std::cmp::Reverse(session.created_at));
    Json(sessions).into_response()
}

/// `DELETE /v1/sessions/{id}`: kill one session.
///
/// Killing is the honest verb. The child process is terminated, and whatever
/// was running in it dies with it, exactly as `landlined sessions kill` does.
pub async fn session_kill_handler(
    State(state): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
) -> Response {
    let login = match require_token(&state, &headers) {
        Ok(login) => login,
        Err(refusal) => return *refusal,
    };
    let Ok(uuid) = Uuid::parse_str(&id) else {
        return err(StatusCode::BAD_REQUEST, "bad_session_id");
    };
    if state.manager.kill(uuid) {
        tracing::info!(%login, session = %uuid, "killed session over http");
        StatusCode::NO_CONTENT.into_response()
    } else {
        err(StatusCode::NOT_FOUND, "no_such_session")
    }
}

// ---- /v1/outbox ----

/// One file a local process has offered to the phone.
///
/// The path is held rather than the bytes, so offering a file is instant and
/// costs nothing, and a file that changes on disk is served as it now is. The
/// consequence is that an offer can go stale, which the read path reports as a
/// plain 404 rather than pretending.
#[derive(Clone)]
struct OutboxEntry {
    id: String,
    path: PathBuf,
    name: String,
    offered_at: i64,
}

/// The files waiting to go the other way, host to phone.
///
/// Deliberately a registry of explicit offers and not a filesystem view. There
/// is no path in any request: a caller names an id that some local process
/// created by running `landlined send`. That is what keeps this from being the
/// read half of an SFTP browser, which is a permanent non-goal.
#[derive(Clone, Default)]
pub struct Outbox {
    entries: Arc<Mutex<Vec<OutboxEntry>>>,
}

/// Offers kept at once. Old ones fall off the front, because an outbox is a
/// hand-off, not a folder.
///
/// Unix-gated with `offer` below: the only thing that fills an outbox is
/// `landlined send`, which reaches the daemon over the admin socket, and there
/// is no admin socket on Windows yet. The endpoints are still served there and
/// still answer, with an outbox that is always empty.
#[cfg_attr(not(unix), allow(dead_code))]
const MAX_OUTBOX_ENTRIES: usize = 64;

impl Outbox {
    pub fn new() -> Self {
        Outbox::default()
    }

    /// Registers `path` and returns the id the phone will fetch it by, or an
    /// error string for the CLI to print.
    ///
    /// The path is canonicalised here, while the offering process is still
    /// around to be told it was wrong, rather than at fetch time when nobody
    /// is watching.
    ///
    /// Reached only from the admin socket, which is Unix-only, so on Windows
    /// this has no caller and `-D warnings` would fail the build over it.
    #[cfg_attr(not(unix), allow(dead_code))]
    pub fn offer(&self, path: &str) -> Result<String, String> {
        let resolved = std::fs::canonicalize(path).map_err(|err| format!("{path}: {err}"))?;
        let meta = std::fs::metadata(&resolved).map_err(|err| format!("{path}: {err}"))?;
        if !meta.is_file() {
            return Err(format!("{path}: not a regular file"));
        }
        let name = resolved
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "file".to_string());
        let id = auth::random_hex(8);
        let mut entries = self.entries.lock().unwrap();
        entries.push(OutboxEntry {
            id: id.clone(),
            path: resolved,
            name,
            offered_at: now_secs(),
        });
        let overflow = entries.len().saturating_sub(MAX_OUTBOX_ENTRIES);
        entries.drain(..overflow);
        Ok(id)
    }

    fn list(&self) -> Vec<OutboxEntry> {
        self.entries.lock().unwrap().clone()
    }

    fn take(&self, id: &str) -> Option<OutboxEntry> {
        self.entries
            .lock()
            .unwrap()
            .iter()
            .find(|entry| entry.id == id)
            .cloned()
    }

    fn forget(&self, id: &str) -> bool {
        let mut entries = self.entries.lock().unwrap();
        let before = entries.len();
        entries.retain(|entry| entry.id != id);
        entries.len() != before
    }

    /// Drops offers older than `ttl`. An offer is a hand-off that was meant to
    /// be picked up in the next minute, so one still sitting here a day later
    /// is a forgotten intention rather than a queue.
    pub fn reap(&self, ttl: Duration) -> usize {
        if ttl.is_zero() {
            return 0;
        }
        // Saturating, not a bare cast: an absurd `upload_ttl_hours` overflows
        // i64, wraps the cutoff into the future, and the sweep then drops every
        // offer it has. The session reaper already guards this the same way.
        let ttl_secs = i64::try_from(ttl.as_secs()).unwrap_or(i64::MAX);
        let cutoff = now_secs().saturating_sub(ttl_secs);
        let mut entries = self.entries.lock().unwrap();
        let before = entries.len();
        entries.retain(|entry| entry.offered_at > cutoff);
        before - entries.len()
    }
}

/// Sweeps stale offers on a fixed interval for as long as the daemon runs.
pub fn spawn_reaper(outbox: Outbox, ttl: Duration) {
    if ttl.is_zero() {
        return;
    }
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(3600));
        loop {
            ticker.tick().await;
            let dropped = outbox.reap(ttl);
            if dropped > 0 {
                tracing::info!(dropped, "dropped stale outbox offers");
            }
        }
    });
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[derive(serde::Serialize)]
struct OutboxResp {
    id: String,
    name: String,
    bytes: u64,
    offered_at: i64,
}

/// `GET /v1/outbox`: what the host has offered.
///
/// An offer whose file has since been moved or deleted is dropped from the
/// listing rather than reported with a size of zero, so the phone is never
/// shown something it cannot fetch.
pub async fn outbox_handler(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if let Err(refusal) = require_token(&state, &headers) {
        return *refusal;
    }
    let mut offers: Vec<OutboxResp> = state
        .outbox
        .list()
        .into_iter()
        .filter_map(|entry| {
            let bytes = std::fs::metadata(&entry.path).ok()?.len();
            Some(OutboxResp {
                id: entry.id,
                name: entry.name,
                bytes,
                offered_at: entry.offered_at,
            })
        })
        .collect();
    offers.sort_by_key(|offer| std::cmp::Reverse(offer.offered_at));
    Json(offers).into_response()
}

/// `GET /v1/outbox/{id}`: the bytes of one offer.
pub async fn outbox_get_handler(
    State(state): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
) -> Response {
    if let Err(refusal) = require_token(&state, &headers) {
        return *refusal;
    }
    let Some(entry) = state.outbox.take(&id) else {
        return err(StatusCode::NOT_FOUND, "no_such_offer");
    };
    // Opened at fetch time, not at offer time, so an offer costs nothing to
    // stand and a file that changed on disk is served as it now is.
    //
    // Streamed rather than read whole. `landlined send` puts no ceiling on what
    // can be offered (a disk image is a legitimate thing to hand yourself), and
    // reading one into a `Vec` would pin a worker thread for the length of the
    // read and then OOM the daemon on a big enough file, taking every live
    // shell session with it.
    let file = match tokio::fs::File::open(&entry.path).await {
        Ok(file) => file,
        Err(_) => return err(StatusCode::NOT_FOUND, "offer_gone"),
    };
    let length = file.metadata().await.map(|meta| meta.len()).ok();

    let stream = tokio_util::io::ReaderStream::new(file);
    let mut response = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/octet-stream")
        .header(header::CONTENT_DISPOSITION, disposition(&entry.name));
    if let Some(length) = length {
        response = response.header(header::CONTENT_LENGTH, length);
    }
    response
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| err(StatusCode::INTERNAL_SERVER_ERROR, "offer_unreadable"))
}

/// A `Content-Disposition` value that is a valid header whatever the file is
/// called.
///
/// Unix file names may contain almost anything, including quotes, backslashes
/// and control bytes, and a name carrying one produced either a malformed
/// quoted-string or a `HeaderValue` that fails to build at all, turning the
/// fetch into a bare 500. So the quoted form is reduced to a conservative
/// ASCII subset, and the real name travels in RFC 5987 `filename*`, which is
/// what any client written this decade reads.
fn disposition(name: &str) -> String {
    let fallback: String = name
        .chars()
        .map(|ch| match ch {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '.' | '_' | '-' => ch,
            _ => '-',
        })
        .take(80)
        .collect();
    let fallback = if fallback.trim_matches('-').is_empty() {
        "file".to_string()
    } else {
        fallback
    };

    // Percent-encode everything outside the RFC 5987 attribute character set.
    let encoded: String = name
        .bytes()
        .map(|byte| match byte {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'.' | b'_' | b'-' | b'~' => {
                (byte as char).to_string()
            }
            other => format!("%{other:02X}"),
        })
        .collect();

    format!("attachment; filename=\"{fallback}\"; filename*=UTF-8''{encoded}")
}

/// `DELETE /v1/outbox/{id}`: withdraw an offer.
///
/// Forgets the offer. The file on the host is not touched, because the phone
/// saying "I have this now" is not the phone saying "delete your copy".
pub async fn outbox_delete_handler(
    State(state): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
) -> Response {
    if let Err(refusal) = require_token(&state, &headers) {
        return *refusal;
    }
    if state.outbox.forget(&id) {
        StatusCode::NO_CONTENT.into_response()
    } else {
        err(StatusCode::NOT_FOUND, "no_such_offer")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_file(contents: &[u8]) -> PathBuf {
        let path = std::env::temp_dir().join(format!("landline-outbox-{}", auth::random_hex(8)));
        std::fs::write(&path, contents).expect("write");
        path
    }

    #[test]
    fn offering_a_file_yields_an_id_that_fetches_it() {
        let outbox = Outbox::new();
        let path = temp_file(b"hello");
        let id = outbox.offer(path.to_str().unwrap()).expect("offer");
        let entry = outbox.take(&id).expect("entry");
        assert_eq!(std::fs::read(&entry.path).unwrap(), b"hello");
        assert_eq!(entry.name, path.file_name().unwrap().to_string_lossy());
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn offering_refuses_what_it_cannot_serve() {
        let outbox = Outbox::new();
        assert!(outbox.offer("/definitely/not/here").is_err());
        // A directory is not a hand-off, and serving one would mean deciding
        // what "the bytes of a directory" are.
        assert!(outbox
            .offer(std::env::temp_dir().to_str().unwrap())
            .is_err());
    }

    #[test]
    fn an_unknown_id_is_not_an_offer() {
        let outbox = Outbox::new();
        assert!(outbox.take("deadbeef").is_none());
        assert!(!outbox.forget("deadbeef"));
    }

    #[test]
    fn withdrawing_an_offer_leaves_the_file_alone() {
        let outbox = Outbox::new();
        let path = temp_file(b"keep me");
        let id = outbox.offer(path.to_str().unwrap()).expect("offer");
        assert!(outbox.forget(&id));
        assert!(outbox.take(&id).is_none());
        assert!(
            path.exists(),
            "withdrawing an offer must not delete the file"
        );
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn the_registry_stays_bounded() {
        let outbox = Outbox::new();
        let path = temp_file(b"x");
        let first = outbox.offer(path.to_str().unwrap()).expect("offer");
        for _ in 0..MAX_OUTBOX_ENTRIES {
            outbox.offer(path.to_str().unwrap()).expect("offer");
        }
        assert!(outbox.entries.lock().unwrap().len() <= MAX_OUTBOX_ENTRIES);
        assert!(outbox.take(&first).is_none(), "the oldest offer falls off");
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn a_disposition_is_a_valid_header_for_any_name() {
        use axum::http::HeaderValue;

        // Unix names may hold quotes, backslashes, control bytes and any UTF-8
        // at all. Each of these used to produce either a malformed
        // quoted-string or a HeaderValue that fails to build, turning a fetch
        // into a bare 500.
        for name in [
            "report.pdf",
            "r\u{e9}sum\u{e9}.pdf",
            "back\\slash.txt",
            "quote\".txt",
            "new\nline.txt",
            "\u{4e2d}\u{6587}.txt",
            "...",
            "",
        ] {
            let value = disposition(name);
            assert!(
                HeaderValue::from_str(&value).is_ok(),
                "{name:?} produced an unusable header: {value:?}"
            );
            assert!(value.starts_with("attachment; filename=\""));
            assert!(value.contains("filename*=UTF-8''"), "{value}");
        }
    }

    #[test]
    fn a_disposition_keeps_an_ordinary_name_readable() {
        let value = disposition("report.pdf");
        assert!(value.contains("filename=\"report.pdf\""), "{value}");
        assert!(value.contains("filename*=UTF-8''report.pdf"), "{value}");
    }

    #[test]
    fn a_disposition_never_falls_back_to_an_empty_name() {
        // Everything strippable: the quoted form still has to name something.
        assert!(disposition("///").contains("filename=\"file\""));
        assert!(disposition("").contains("filename=\"file\""));
    }

    #[test]
    fn the_reaper_drops_stale_offers_only() {
        let outbox = Outbox::new();
        let path = temp_file(b"x");
        outbox.offer(path.to_str().unwrap()).expect("offer");
        assert_eq!(outbox.reap(Duration::from_secs(3600)), 0);
        assert_eq!(outbox.list().len(), 1);
        // A zero TTL is disabled, not "expire everything": that is what the
        // config key means, and a sweep that emptied the outbox when someone
        // switched it off would be the opposite of switching it off.
        assert_eq!(outbox.reap(Duration::ZERO), 0);
        assert_eq!(outbox.list().len(), 1);
        std::fs::remove_file(&path).ok();
    }
}
