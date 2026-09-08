//! Session lifetime management.
//!
//! A session is a PTY plus its scrollback ring; it outlives any client
//! connection. At most one client is attached at a time; a newer attach
//! replaces the older client. A long-lived pump task per session moves PTY
//! output into the ring and on to the attached client, and tears the
//! session down when the child exits.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, AtomicU64, AtomicUsize, Ordering};
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
    /// Program to spawn for a new session, already resolved by the caller
    /// (see [`crate::config::resolve_command`], which turns the ATTACH
    /// `cmd`, the `default_cmd` config key, and the configured shell into
    /// the program and argv actually spawned).
    pub program: String,
    /// argv for `program`, e.g. `["-l"]` for a plain login shell or
    /// `["-i", "-c", "tmux new -A -s main"]` for a startup command.
    pub args: Vec<String>,
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
// Only the Unix-only admin socket consumes this, so it is unreachable (but
// still legitimate API) on Windows.
#[cfg_attr(not(unix), allow(dead_code))]
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
    /// Sessions whose slot is reserved but whose PTY has not finished spawning.
    /// Counted towards `max_sessions` so the cap holds while `create` is
    /// outside the registry lock. See `PendingSlot`.
    pending: AtomicUsize,
}

/// Releases a reserved session slot when `create` returns, however it returns.
struct PendingSlot {
    inner: Arc<Inner>,
}

impl Drop for PendingSlot {
    fn drop(&mut self) {
        self.inner.pending.fetch_sub(1, Ordering::SeqCst);
    }
}

impl SessionManager {
    pub fn new(max_sessions: usize, scrollback_bytes: usize) -> Self {
        SessionManager {
            inner: Arc::new(Inner {
                sessions: RwLock::new(HashMap::new()),
                max_sessions,
                scrollback_bytes,
                pending: AtomicUsize::new(0),
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
        // Reserve a slot under the lock, then release it before spawning.
        //
        // The capacity check still has to be atomic against a racing create, or
        // two could both slip under the limit. What must *not* happen is
        // holding the registry's write lock across `pty::spawn`, which does a
        // blocking openpty and fork/exec: a slow shell start (cold disk, fork
        // latency, a scanner) would otherwise stall every session listing, the
        // admin socket, the reaper, and the pump's own exit-removal, all of
        // which want this lock.
        {
            let sessions = self.inner.sessions.write().unwrap();
            if sessions.len() + self.inner.pending.load(Ordering::SeqCst) >= self.inner.max_sessions
            {
                return Err(AttachError::TooManySessions);
            }
            self.inner.pending.fetch_add(1, Ordering::SeqCst);
        }
        // Whatever happens next, the reservation is released exactly once.
        let _reservation = PendingSlot {
            inner: Arc::clone(&self.inner),
        };

        let (pty, events) = pty::spawn(
            &args.program,
            &args.args,
            args.cwd.as_deref(),
            args.cols,
            args.rows,
        )
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
        {
            let mut sessions = self.inner.sessions.write().unwrap();
            sessions.insert(session.id, Arc::clone(&session));
            // Transfer the reservation under the same lock used by admission.
            drop(_reservation);
        }
        spawn_pump(Arc::clone(&self.inner), Arc::clone(&session), events);
        tracing::info!(id = %session.id, shell = %session.shell, "session created");
        Ok(session)
    }

    /// Kills a session's child by id. Returns false for an unknown id.
    /// The exit pump handles EXIT delivery and removal.
    // Called only from the Unix-only admin socket; unreachable on Windows.
    #[cfg_attr(not(unix), allow(dead_code))]
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
                let stale = stale_sessions(&inner, now_unix(), ttl_secs);
                for session in stale {
                    tracing::info!(id = %session.id, "reaping idle session past ttl");
                    session.kill();
                    inner.sessions.write().unwrap().remove(&session.id);
                }
            }
        });
    }
}

/// The sessions a sweep at `now` should reap: detached, and last seen longer
/// than `ttl_secs` ago.
///
/// Split out of the reaper task so the rule can be tested. Getting either half
/// of it backwards kills live work on a sixty second cadence, which is the kind
/// of thing that wants an assertion rather than a careful reading.
fn stale_sessions(inner: &Arc<Inner>, now: i64, ttl_secs: i64) -> Vec<Arc<Session>> {
    inner
        .sessions
        .read()
        .unwrap()
        .values()
        .filter(|s| !s.attached() && now.saturating_sub(s.last_seen()) > ttl_secs)
        .cloned()
        .collect()
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
            // Take the slot rather than borrow it. The EXIT below is best
            // effort: if the client's channel happens to be full at this
            // instant the frame is dropped, and a client whose `tx` stayed
            // parked in this slot would then never see its `rx` close either.
            // It would sit on a session that has left the registry, draining
            // its backlog and answering pings, with nothing left to tell it.
            // Dropping the sender at the end of this scope closes the receiver,
            // so the connection tears down even when the frame is lost.
            let client = session.attached.lock().unwrap().take();
            if let Some(client) = client {
                let _ = client.tx.try_send(ServerFrame::Exit(code));
            }
        }
        inner.sessions.write().unwrap().remove(&session.id);
        tracing::info!(id = %session.id, code, "session exited");
    });
}

#[cfg(all(test, unix))]
mod reaper_tests {
    use super::*;

    /// A manager holding one session, spawned from a shell that will sit there.
    fn manager_with_session() -> (SessionManager, Arc<Session>) {
        let manager = SessionManager::new(4, 4096);
        let attachment = manager
            .attach(AttachArgs {
                session_id: None,
                program: "/bin/sh".to_string(),
                args: vec![],
                cwd: None,
                cols: 80,
                rows: 24,
            })
            .expect("attach");
        let session = manager
            .inner
            .sessions
            .read()
            .unwrap()
            .values()
            .next()
            .cloned()
            .expect("one session");
        // Keep the attachment alive for as long as the caller wants it.
        std::mem::forget(attachment);
        (manager, session)
    }

    #[tokio::test]
    async fn an_attached_session_is_never_reaped() {
        let (manager, session) = manager_with_session();
        // Attached, and idle far past any ttl: still not stale. Reaping a
        // session someone is looking at is the one unrecoverable mistake here.
        session.last_seen.store(0, Ordering::SeqCst);
        let stale = stale_sessions(&manager.inner, 1_000_000, 1);
        assert!(stale.is_empty(), "an attached session must survive its ttl");
    }

    #[tokio::test]
    async fn a_detached_session_past_its_ttl_is_reaped() {
        let (manager, session) = manager_with_session();
        *session.attached.lock().unwrap() = None;
        session.last_seen.store(0, Ordering::SeqCst);

        let stale = stale_sessions(&manager.inner, 1_000, 100);
        assert_eq!(stale.len(), 1, "detached and long idle is exactly the case");
        assert_eq!(stale[0].id, session.id);
    }

    #[tokio::test]
    async fn a_detached_session_inside_its_ttl_survives() {
        let (manager, session) = manager_with_session();
        *session.attached.lock().unwrap() = None;
        session.last_seen.store(950, Ordering::SeqCst);

        // 50 seconds idle against a 100 second ttl.
        assert!(stale_sessions(&manager.inner, 1_000, 100).is_empty());
        // And exactly at the ttl it is still not *past* it.
        session.last_seen.store(900, Ordering::SeqCst);
        assert!(
            stale_sessions(&manager.inner, 1_000, 100).is_empty(),
            "the boundary is exclusive"
        );
        session.last_seen.store(899, Ordering::SeqCst);
        assert_eq!(stale_sessions(&manager.inner, 1_000, 100).len(), 1);
    }

    #[tokio::test]
    async fn a_saturating_ttl_reaps_nothing() {
        // `session_ttl_hours` large enough to overflow the seconds cast used to
        // wrap negative and reap everything; it must simply never fire.
        let (manager, session) = manager_with_session();
        *session.attached.lock().unwrap() = None;
        session.last_seen.store(0, Ordering::SeqCst);
        assert!(stale_sessions(&manager.inner, i64::MAX, i64::MAX).is_empty());
    }
}

#[cfg(all(test, unix))]
mod concurrency_tests {
    use super::*;
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_creation_respects_one_session_cap() {
        for round in 0..10 {
            let manager = SessionManager::new(1, 1024);
            let barrier = Arc::new(std::sync::Barrier::new(16));
            let handle = tokio::runtime::Handle::current();
            let mut threads = Vec::new();
            for _ in 0..16 {
                let manager = manager.clone();
                let barrier = barrier.clone();
                let handle = handle.clone();
                threads.push(std::thread::spawn(move || {
                    let _guard = handle.enter();
                    barrier.wait();
                    manager
                        .attach(AttachArgs {
                            session_id: None,
                            program: "/bin/sh".into(),
                            args: vec![],
                            cwd: None,
                            cols: 80,
                            rows: 24,
                        })
                        .ok()
                }));
            }
            let attachments: Vec<_> = threads
                .into_iter()
                .filter_map(|t| t.join().unwrap())
                .collect();
            let count = attachments.len();
            for a in &attachments {
                a.session.kill();
            }
            let _ = tokio::time::timeout(Duration::from_secs(5), async {
                while !manager.list().is_empty() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await;
            assert!(
                count <= 1,
                "round {round}: created {count} sessions with max_sessions=1"
            );
        }
    }
}
