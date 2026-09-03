//! Session lifetime management.
//!
//! A session is a PTY plus its scrollback ring; it outlives any client
//! connection. At most one client is attached at a time; a newer attach
//! replaces the older client. A long-lived pump task per session moves PTY
//! output into the ring and on to the attached client, and tears the
//! session down when the child exits.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use bytes::Bytes;
use landline_proto::frame::{ErrCode, ServerFrame};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::{pty, ring};

/// Capacity of the per-client outbound frame channel. A client that lets
/// this many frames queue up is dropped as too slow.
const CLIENT_CHANNEL_CAPACITY: usize = 1024;

/// Current unix time in seconds.
pub(crate) fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The one client currently attached to a session.
struct AttachedClient {
    /// Monotonic per-session counter guarding against a stale connection
    /// detaching a newer client.
    generation: u64,
    tx: mpsc::Sender<ServerFrame>,
}

/// A PTY-backed shell session.
pub struct Session {
    pub id: Uuid,
    /// Program running in the PTY (shell or explicit `cmd`).
    pub shell: String,
    /// Unix seconds at creation.
    pub created_at: i64,
    /// Clone of the PTY's stdin sender; bytes written here reach the child.
    pub stdin: mpsc::Sender<Bytes>,
    pty: Mutex<pty::Pty>,
    ring: Mutex<ring::Ring>,
    attached: Mutex<Option<AttachedClient>>,
    generation: AtomicU64,
    /// Unix seconds of the last attach/detach; the reaper compares this
    /// against the session TTL for unattached sessions.
    last_seen: AtomicI64,
    size: Mutex<(u16, u16)>,
}

impl Session {
    /// Installs a new attached client, replacing (and notifying) any
    /// previous one, and returns the replay snapshot.
    ///
    /// The snapshot is taken *after* the new client is installed and under
    /// the ring lock. The output pump holds the ring lock across its
    /// push-then-forward step, so every output chunk lands either in the
    /// snapshot or in the new client's channel: no gap, no duplicate.
    fn install_client(&self) -> (u64, mpsc::Receiver<ServerFrame>, Vec<u8>) {
        let (tx, rx) = mpsc::channel(CLIENT_CHANNEL_CAPACITY);
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let ring = self.ring.lock().unwrap();
        let mut attached = self.attached.lock().unwrap();
        if let Some(old) = attached.take() {
            // Best effort: the old client may already be gone or full.
            let _ = old.tx.try_send(ServerFrame::Err {
                code: ErrCode::SessionReplaced,
                message: "another client attached to this session".to_string(),
            });
        }
        *attached = Some(AttachedClient { generation, tx });
        let replay = if ring.is_empty() {
            Vec::new()
        } else {
            ring.snapshot()
        };
        drop(attached);
        tracing::debug!(id = %self.id, generation, replay = ring.len(), "client attached");
        drop(ring);
        self.touch();
        (generation, rx, replay)
    }

    /// Clears the attached slot if `generation` still matches, so a stale
    /// connection cannot detach a client that replaced it.
    pub fn detach(&self, generation: u64) {
        let mut attached = self.attached.lock().unwrap();
        if attached
            .as_ref()
            .is_some_and(|client| client.generation == generation)
        {
            *attached = None;
        }
        drop(attached);
        self.touch();
    }

    /// Resizes the PTY and records the new size.
    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        self.pty.lock().unwrap().resize(cols, rows)?;
        *self.size.lock().unwrap() = (cols, rows);
        Ok(())
    }

    /// Current terminal size.
    pub fn size(&self) -> (u16, u16) {
        *self.size.lock().unwrap()
    }

    /// Terminates the child process (best-effort, idempotent). The exit
    /// pump forwards EXIT and removes the session once the child dies.
    pub fn kill(&self) {
        self.pty.lock().unwrap().kill();
    }

    fn attached(&self) -> bool {
        self.attached.lock().unwrap().is_some()
    }

    fn last_seen(&self) -> i64 {
        self.last_seen.load(Ordering::Relaxed)
    }

    fn touch(&self) {
        self.last_seen.store(now_unix(), Ordering::Relaxed);
    }
}

/// Everything a connection needs after a successful attach.
pub struct Attachment {
    pub session: Arc<Session>,
    pub generation: u64,
    pub rx: mpsc::Receiver<ServerFrame>,
    /// Scrollback snapshot to send as STDOUT after ATTACHED.
    pub replay: Vec<u8>,
}

/// Parameters for [`SessionManager::attach`].
pub struct AttachArgs {
    /// `None` creates a new session; `Some` resumes an existing one.
    pub session_id: Option<Uuid>,
    /// Program to spawn for a new session (already resolved).
    pub program: String,
    pub cwd: Option<PathBuf>,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug)]
pub enum AttachError {
    SessionGone,
    TooManySessions,
    SpawnFailed(String),
}

/// One row of `sessions list` output.
pub struct SessionInfo {
    pub id: Uuid,
    pub shell: String,
    pub created_at: i64,
    pub attached: bool,
    pub last_seen: i64,
}

/// Shared registry of live sessions.
#[derive(Clone)]
pub struct SessionManager {
    inner: Arc<Inner>,
}

struct Inner {
    sessions: RwLock<HashMap<Uuid, Arc<Session>>>,
    max_sessions: usize,
    scrollback_bytes: usize,
}

impl SessionManager {
    pub fn new(max_sessions: usize, scrollback_bytes: usize) -> Self {
        SessionManager {
            inner: Arc::new(Inner {
                sessions: RwLock::new(HashMap::new()),
                max_sessions,
                scrollback_bytes,
            }),
        }
    }

    /// Creates or resumes a session and installs the caller as its
    /// attached client. Must be called from within a tokio runtime.
    pub fn attach(&self, args: AttachArgs) -> Result<Attachment, AttachError> {
        let session = match args.session_id {
            Some(id) => {
                let session = self
                    .inner
                    .sessions
                    .read()
                    .unwrap()
                    .get(&id)
                    .cloned()
                    .ok_or(AttachError::SessionGone)?;
                // Resume adopts the new client's terminal size.
                if let Err(err) = session.resize(args.cols, args.rows) {
                    tracing::debug!(id = %session.id, %err, "resize on resume failed");
                }
                session
            }
            None => self.create(&args)?,
        };
        let (generation, rx, replay) = session.install_client();
        Ok(Attachment {
            session,
            generation,
            rx,
            replay,
        })
    }

    fn create(&self, args: &AttachArgs) -> Result<Arc<Session>, AttachError> {
        // Hold the write lock across the capacity check and insert so two
        // racing creates cannot both slip under the limit.
        let mut sessions = self.inner.sessions.write().unwrap();
        if sessions.len() >= self.inner.max_sessions {
            return Err(AttachError::TooManySessions);
        }
        let (pty, events) = pty::spawn(&args.program, args.cwd.as_deref(), args.cols, args.rows)
            .map_err(|err| AttachError::SpawnFailed(err.to_string()))?;
        let now = now_unix();
        let session = Arc::new(Session {
            id: Uuid::new_v4(),
            shell: args.program.clone(),
            created_at: now,
            stdin: pty.stdin.clone(),
            pty: Mutex::new(pty),
            ring: Mutex::new(ring::Ring::new(self.inner.scrollback_bytes)),
            attached: Mutex::new(None),
            generation: AtomicU64::new(0),
            last_seen: AtomicI64::new(now),
            size: Mutex::new((args.cols, args.rows)),
        });
        sessions.insert(session.id, Arc::clone(&session));
        drop(sessions);
        spawn_pump(Arc::clone(&self.inner), Arc::clone(&session), events);
        tracing::info!(id = %session.id, shell = %session.shell, "session created");
        Ok(session)
    }

    /// Kills a session's child by id. Returns false for an unknown id.
    /// The exit pump handles EXIT delivery and removal.
    pub fn kill(&self, id: Uuid) -> bool {
        let session = self.inner.sessions.read().unwrap().get(&id).cloned();
        match session {
            Some(session) => {
                session.kill();
                true
            }
            None => false,
        }
    }

    /// Snapshot of all live sessions.
    pub fn list(&self) -> Vec<SessionInfo> {
        self.inner
            .sessions
            .read()
            .unwrap()
            .values()
            .map(|s| SessionInfo {
                id: s.id,
                shell: s.shell.clone(),
                created_at: s.created_at,
                attached: s.attached(),
                last_seen: s.last_seen(),
            })
            .collect()
    }

    /// Starts the background reaper: every 60s, kill and remove sessions
    /// that have no attached client and were last seen longer than `ttl`
    /// ago.
    pub fn spawn_reaper(&self, ttl: Duration) {
        let inner = Arc::clone(&self.inner);
        let ttl_secs = i64::try_from(ttl.as_secs()).unwrap_or(i64::MAX);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(60));
            loop {
                interval.tick().await;
                let now = now_unix();
                let stale: Vec<Arc<Session>> = inner
                    .sessions
                    .read()
                    .unwrap()
                    .values()
                    .filter(|s| !s.attached() && now.saturating_sub(s.last_seen()) > ttl_secs)
                    .cloned()
                    .collect();
                for session in stale {
                    tracing::info!(id = %session.id, "reaping idle session past ttl");
                    session.kill();
                    inner.sessions.write().unwrap().remove(&session.id);
                }
            }
        });
    }
}

/// Long-lived per-session task: pumps PTY output into the ring and to the
/// attached client, then handles child exit.
fn spawn_pump(inner: Arc<Inner>, session: Arc<Session>, mut events: pty::PtyEvents) {
    tokio::spawn(async move {
        while let Some(chunk) = events.output.recv().await {
            // The ring lock is held across push-and-forward so an attach
            // (which installs its tx and snapshots under the same lock)
            // sees each chunk exactly once: in the snapshot or live.
            let mut ring = session.ring.lock().unwrap();
            ring.push(&chunk);
            let mut attached = session.attached.lock().unwrap();
            if let Some(client) = attached.as_ref() {
                match client.tx.try_send(ServerFrame::Stdout(chunk)) {
                    Ok(()) => {}
                    Err(mpsc::error::TrySendError::Full(_)) => {
                        // Best effort; the channel is full, so this most
                        // likely fails too. The client is dropped either way.
                        let _ = client.tx.try_send(ServerFrame::Err {
                            code: ErrCode::ClientTooSlow,
                            message: "client cannot keep up with output".to_string(),
                        });
                        tracing::warn!(id = %session.id, "dropping too-slow client");
                        *attached = None;
                    }
                    Err(mpsc::error::TrySendError::Closed(_)) => {
                        // Connection already gone; clear the stale slot.
                        *attached = None;
                    }
                }
            }
        }

        // Output stream closed: the child is exiting. Forward EXIT, then
        // remove the session.
        let code = events.exit.await.unwrap_or(u32::MAX);
        {
            let attached = session.attached.lock().unwrap();
            if let Some(client) = attached.as_ref() {
                let _ = client.tx.try_send(ServerFrame::Exit(code));
            }
        }
        inner.sessions.write().unwrap().remove(&session.id);
        tracing::info!(id = %session.id, code, "session exited");
    });
}
