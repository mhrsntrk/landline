//! The file inbox: a small HTTP sidecar that gets one file from the phone onto
//! the host, so whatever is running in the session can be handed a path.
//!
//! This is deliberately not a file manager and not an SFTP browser (both are
//! permanent non-goals, see `docs/SCOPE.md`). There is no directory listing, no
//! read endpoint, and no way to name a destination: a request hands over bytes
//! and gets back the absolute path of a new file inside one configured
//! directory. That is the whole surface.
//!
//! Normative reference for the HTTP behaviour: `docs/HTTP.md`.
//!
//! ## Why this is not a privilege escalation
//!
//! Both endpoints sit behind exactly the credentials `/v1/shell` sits behind:
//! the tailnet login that `tailscale serve` injects, plus the unlock secret
//! when one is configured. Anyone holding those already has an interactive
//! shell on this machine, which can write any file it likes. Writing bytes into
//! one directory is strictly less than that, which is why the inbox is on by
//! default rather than gated behind a second decision the operator would have
//! to make with no information.
//!
//! What the endpoints must therefore *not* do is widen that surface: no reads,
//! no path the caller controls, no overwrite of an existing file.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use axum::body::Body;
use axum::extract::{Path as UrlPath, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use futures_util::StreamExt;
use tokio::io::AsyncWriteExt;

use crate::api::{err, require_token};
use crate::auth::random_hex;

/// Longest accepted upload file name, after sanitizing.
const MAX_NAME_LEN: usize = 48;

// ---- file names ----

/// Turns whatever the client put in the URL into a file name this daemon is
/// willing to create, or `None` when nothing usable is left.
///
/// Everything hostile is handled by construction rather than by rejection:
/// only the last path component is considered, the character set is reduced to
/// `[a-z0-9._-]`, leading dots are stripped so nothing can be created hidden or
/// named `..`, and a random suffix is appended so a name can never collide with
/// or overwrite a file already in the inbox.
pub fn sanitize_name(raw: &str) -> Option<String> {
    let last = raw
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();

    let cleaned: String = last
        .chars()
        .map(|ch| match ch {
            'a'..='z' | '0'..='9' | '.' | '_' | '-' => ch,
            _ => '-',
        })
        .collect();

    let (stem, ext) = match cleaned.rsplit_once('.') {
        Some((stem, ext))
            if !ext.is_empty()
                && ext.len() <= 8
                && ext.chars().all(|ch| ch.is_ascii_alphanumeric()) =>
        {
            (stem, Some(ext))
        }
        _ => (cleaned.as_str(), None),
    };

    let stem: String = stem
        .trim_matches(['.', '-', '_'])
        .chars()
        .take(MAX_NAME_LEN)
        .collect();
    let stem = if stem.is_empty() {
        "file".to_string()
    } else {
        stem
    };

    let suffix = random_hex(4);
    Some(match ext {
        Some(ext) => format!("{stem}-{suffix}.{ext}"),
        None => format!("{stem}-{suffix}"),
    })
}

// ---- the inbox directory ----

/// Creates the inbox directory if it is missing, 0700 on Unix.
pub fn ensure_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Deletes inbox files older than `ttl`. Errors are logged and skipped: a
/// single unreadable entry must not stop the sweep.
pub fn reap(dir: &Path, ttl: Duration) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let now = SystemTime::now();
    let mut removed = 0;
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let Ok(modified) = meta.modified() else {
            continue;
        };
        let Ok(age) = now.duration_since(modified) else {
            continue;
        };
        if age > ttl && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    removed
}

/// Sweeps the inbox on a fixed interval for as long as the daemon runs.
pub fn spawn_reaper(dir: PathBuf, ttl: Duration) {
    if ttl.is_zero() {
        return;
    }
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(3600));
        loop {
            ticker.tick().await;
            let dir = dir.clone();
            let removed = tokio::task::spawn_blocking(move || reap(&dir, ttl))
                .await
                .unwrap_or(0);
            if removed > 0 {
                tracing::info!(removed, "reaped expired inbox files");
            }
        }
    });
}

// ---- handlers ----

/// Everything the two handlers need. Kept as its own struct so the inbox can be
/// reasoned about without the session machinery.
#[derive(Clone)]
pub struct FilesState {
    pub dir: PathBuf,
    pub max_bytes: u64,
}

#[derive(serde::Serialize)]
struct UploadResp {
    path: String,
    bytes: u64,
}

/// `PUT /v1/files/{name}`: writes the request body into the inbox and answers
/// with the absolute path of the file that was created.
///
/// The name in the URL is a *suggestion*. What gets created is derived from it
/// by [`sanitize_name`] and always carries a random suffix, so the caller
/// cannot choose a destination, cannot escape the inbox, and cannot overwrite
/// anything that is already there.
pub async fn upload_handler(
    State(state): State<crate::server::AppState>,
    UrlPath(name): UrlPath<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let login = match require_token(&state, &headers) {
        Ok(login) => login,
        Err(refusal) => return *refusal,
    };
    let Some(files) = state.files.clone() else {
        return err(StatusCode::NOT_FOUND, "uploads_disabled");
    };

    // Declared length first, so an oversized upload is refused before a byte of
    // it is read. The streaming cap below is what actually enforces the limit,
    // because Content-Length is a claim, not a fact.
    if let Some(declared) = content_length(&headers) {
        if declared > files.max_bytes {
            return err(StatusCode::PAYLOAD_TOO_LARGE, "too_large");
        }
    }

    let Some(filename) = sanitize_name(&name) else {
        return err(StatusCode::BAD_REQUEST, "bad_name");
    };
    let final_path = files.dir.join(&filename);
    // Belt and braces over `sanitize_name`: the file being created must sit
    // directly in the inbox, whatever the name did.
    if final_path.parent() != Some(files.dir.as_path()) {
        return err(StatusCode::BAD_REQUEST, "bad_name");
    }

    if let Err(err_io) = ensure_dir(&files.dir) {
        tracing::error!(%err_io, dir = %files.dir.display(), "inbox directory unusable");
        return err(StatusCode::INTERNAL_SERVER_ERROR, "inbox_unwritable");
    }

    // Written under a temporary name and renamed on success, so a dropped
    // connection leaves a `.part` the reaper collects rather than a truncated
    // file that looks finished to whatever is about to read it.
    let part_path = files.dir.join(format!(".{filename}.part"));
    match stream_to_file(body, &part_path, files.max_bytes).await {
        Ok(bytes) => match std::fs::rename(&part_path, &final_path) {
            Ok(()) => {
                tracing::info!(%login, path = %final_path.display(), bytes, "upload stored");
                (
                    StatusCode::CREATED,
                    Json(UploadResp {
                        path: final_path.to_string_lossy().into_owned(),
                        bytes,
                    }),
                )
                    .into_response()
            }
            Err(err_io) => {
                let _ = std::fs::remove_file(&part_path);
                tracing::error!(%err_io, "failed to move upload into place");
                err(StatusCode::INTERNAL_SERVER_ERROR, "write_failed")
            }
        },
        Err(UploadError::TooLarge) => {
            let _ = std::fs::remove_file(&part_path);
            err(StatusCode::PAYLOAD_TOO_LARGE, "too_large")
        }
        Err(UploadError::Io(err_io)) => {
            let _ = std::fs::remove_file(&part_path);
            tracing::warn!(%err_io, "upload failed");
            err(StatusCode::INTERNAL_SERVER_ERROR, "write_failed")
        }
    }
}

enum UploadError {
    TooLarge,
    Io(std::io::Error),
}

/// Streams `body` into `path`, refusing as soon as `max_bytes` is exceeded.
///
/// The cap is checked per chunk rather than from Content-Length, so a lying or
/// absent header cannot get more than `max_bytes` onto the disk.
async fn stream_to_file(body: Body, path: &Path, max_bytes: u64) -> Result<u64, UploadError> {
    let mut file = tokio::fs::File::create(path)
        .await
        .map_err(UploadError::Io)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .await
            .map_err(UploadError::Io)?;
    }

    let mut written: u64 = 0;
    let mut stream = body.into_data_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|err| UploadError::Io(std::io::Error::other(err)))?;
        written += chunk.len() as u64;
        if written > max_bytes {
            return Err(UploadError::TooLarge);
        }
        file.write_all(&chunk).await.map_err(UploadError::Io)?;
    }
    file.flush().await.map_err(UploadError::Io)?;
    Ok(written)
}

fn content_length(headers: &HeaderMap) -> Option<u64> {
    headers
        .get(axum::http::header::CONTENT_LENGTH)?
        .to_str()
        .ok()?
        .parse()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strip_suffix(name: &str) -> String {
        // Every sanitized name ends in `-<8 hex>` before any extension, which
        // is random and therefore not what these assertions are about.
        match name.rsplit_once('.') {
            Some((stem, ext)) => format!("{}.{ext}", &stem[..stem.len() - 9]),
            None => name[..name.len() - 9].to_string(),
        }
    }

    #[test]
    fn keeps_an_ordinary_name() {
        let name = sanitize_name("IMG_4821.HEIC").expect("name");
        assert_eq!(strip_suffix(&name), "img_4821.heic");
    }

    #[test]
    fn traversal_cannot_escape_the_inbox() {
        for raw in [
            "../../etc/passwd",
            "..\\..\\windows\\system32\\config",
            "/etc/shadow",
            "....//....//etc/passwd",
        ] {
            let name = sanitize_name(raw).expect("name");
            assert!(!name.contains('/'), "{raw} produced {name}");
            assert!(!name.contains('\\'), "{raw} produced {name}");
            assert!(!name.starts_with('.'), "{raw} produced {name}");
            assert_eq!(
                Path::new(&name).components().count(),
                1,
                "{raw} produced {name}"
            );
        }
    }

    #[test]
    fn a_name_that_is_all_punctuation_still_yields_a_file() {
        let name = sanitize_name("...").expect("name");
        assert_eq!(strip_suffix(&name), "file");
        let name = sanitize_name("").expect("name");
        assert_eq!(strip_suffix(&name), "file");
    }

    #[test]
    fn hidden_files_cannot_be_created() {
        let name = sanitize_name(".bashrc").expect("name");
        assert!(!name.starts_with('.'), "{name}");
    }

    #[test]
    fn names_are_bounded_and_unique() {
        let long = "x".repeat(500) + ".png";
        let name = sanitize_name(&long).expect("name");
        assert!(name.len() <= MAX_NAME_LEN + 14, "{} chars", name.len());
        assert_ne!(
            sanitize_name("shot.png").unwrap(),
            sanitize_name("shot.png").unwrap(),
            "two uploads of the same name must not collide"
        );
    }

    #[test]
    fn a_long_or_odd_extension_is_folded_into_the_stem() {
        let name = sanitize_name("archive.tar.gz").expect("name");
        assert_eq!(strip_suffix(&name), "archive.tar.gz");
        // Not an extension: too long, so it stays part of the stem and the file
        // is created without one.
        let name = sanitize_name("report.verylongextension").expect("name");
        assert!(name.starts_with("report.verylongextension-"), "{name}");
    }

    #[test]
    fn the_reaper_removes_only_expired_files() {
        let dir = std::env::temp_dir().join(format!("landline-reap-{}", random_hex(8)));
        ensure_dir(&dir).expect("create dir");
        let fresh = dir.join("fresh.txt");
        std::fs::write(&fresh, b"new").expect("write");
        // Long enough that the file is unambiguously older than a zero TTL on
        // every filesystem timestamp resolution this runs on.
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(reap(&dir, Duration::from_secs(3600)), 0);
        assert!(fresh.exists());
        // Zero TTL makes every file expired, which is the same code path as an
        // old mtime without having to fake one.
        assert_eq!(reap(&dir, Duration::ZERO), 1);
        assert!(!fresh.exists());
        std::fs::remove_dir_all(&dir).ok();
    }
}
