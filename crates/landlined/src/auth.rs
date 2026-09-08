//! Identity and unlock gating.
//!
//! Identity arrives out-of-band on the WebSocket upgrade request via the
//! `Tailscale-User-Login` header (injected by `tailscale serve`). It is
//! verified *before* the upgrade completes; failures are a plain HTTP 403.
//!
//! The optional unlock secret is a second factor checked in-band during the
//! protocol handshake (NEED_UNLOCK / UNLOCK frames), argon2id-verified
//! against `Config::unlock_hash`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::time::Instant;

use rand::RngCore;

use argon2::password_hash::PasswordHash;
use argon2::{Argon2, PasswordVerifier};
use axum::http::HeaderMap;

use crate::config::Config;

/// Header carrying the authenticated tailnet login on the upgrade request.
pub const LOGIN_HEADER: &str = "Tailscale-User-Login";

/// After this many wrong unlock secrets the gate shuts for [`LOCKOUT`], then
/// reopens with a fresh budget.
pub const MAX_UNLOCK_FAILURES: u32 = 10;

/// Longest secret this will hash. See the note in [`UnlockGate::verify`].
pub const MAX_SECRET_LEN: usize = 1024;

/// Resolves and authorizes the client identity from the upgrade request
/// headers. Returns the login on success; `None` means the caller must
/// reject with HTTP 403 before upgrading.
///
/// An empty `allowed_logins` list rejects everyone: the daemon fails closed
/// until the operator explicitly configures who may connect.
pub fn authenticate(cfg: &Config, headers: &HeaderMap) -> Option<String> {
    let login = headers
        .get(LOGIN_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);

    // LOCAL DEV ONLY: the `harness` feature treats a missing header as the
    // implicit login "dev@local" and always allows it, so the browser test
    // harness can connect without tailscale in front. This feature MUST
    // NEVER be enabled in a release build: it disables authentication for
    // anyone who can reach the listener.
    #[cfg(feature = "harness")]
    let login = login.or_else(|| Some("dev@local".to_string()));

    let login = login?;

    #[cfg(feature = "harness")]
    if login == "dev@local" {
        return Some(login);
    }

    if cfg.allowed_logins.iter().any(|allowed| allowed == &login) {
        Some(login)
    } else {
        None
    }
}

/// Result of an unlock attempt.
#[derive(Debug)]
pub enum UnlockOutcome {
    /// The secret was correct (or no unlock is configured).
    Unlocked,
    /// Wrong secret; the backoff delay has already been served.
    Wrong { attempts_left: u32 },
    /// The failure budget is exhausted; refused until daemon restart.
    LockedOut,
}

/// Per-daemon unlock state: the configured argon2id hash plus a global
/// failure counter shared by every connection.
/// How long the gate stays shut once the failure budget is spent.
///
/// A permanent lock-out would be a denial of service: anyone who can reach
/// the unlock stage could spend the budget and keep the owner out until the
/// daemon restarts, which is the one thing they cannot do remotely. A cooling
/// period keeps brute force pointless (ten argon2id guesses per window) while
/// letting legitimate access recover on its own.
pub const LOCKOUT: Duration = Duration::from_secs(15 * 60);

#[derive(Default)]
struct GateState {
    failures: u32,
    locked_until: Option<Instant>,
    /// Earliest instant the next attempt may be *verified*.
    ///
    /// The backoff used to be a sleep before the reply, which a caller who
    /// hung up (or who opened ten connections at once, or who used the HTTP
    /// token endpoint) never waited out: every attempt reached argon2
    /// immediately and only the failure budget limited the guessing. Holding
    /// the deadline on the gate makes the wait apply to the attempt instead of
    /// to the answer, so it cannot be skipped by dropping the connection.
    not_before: Option<Instant>,
}

#[derive(Clone)]
pub struct UnlockGate {
    /// PHC-format argon2id hash; empty means unlock is not required.
    hash: Arc<str>,
    state: Arc<Mutex<GateState>>,
    admission: Arc<tokio::sync::Mutex<()>>,
}

impl UnlockGate {
    pub fn new(unlock_hash: String) -> Self {
        UnlockGate {
            hash: unlock_hash.into(),
            state: Arc::new(Mutex::new(GateState::default())),
            admission: Arc::new(tokio::sync::Mutex::new(())),
        }
    }

    /// Whether the handshake must include an unlock exchange.
    pub fn required(&self) -> bool {
        !self.hash.is_empty()
    }

    /// True while the failure budget is spent and the cooling period runs.
    ///
    /// Expiry is evaluated lazily here, so a caller that waits out `LOCKOUT`
    /// finds the gate open again with a fresh budget.
    pub fn locked_out(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        match state.locked_until {
            Some(until) if Instant::now() >= until => {
                *state = GateState::default();
                false
            }
            Some(_) => true,
            None => false,
        }
    }

    /// Attempts remaining before lock-out.
    pub fn attempts_left(&self) -> u32 {
        MAX_UNLOCK_FAILURES.saturating_sub(self.state.lock().unwrap().failures)
    }

    /// Verifies `secret` against the configured hash.
    ///
    /// Wrong secrets serve an exponential backoff (`min(2^failures * 500ms,
    /// 60s)`) *before* returning, so the caller can answer NEED_UNLOCK
    /// immediately. A correct secret resets the failure counter.
    pub async fn verify(&self, secret: String) -> UnlockOutcome {
        if !self.required() {
            return UnlockOutcome::Unlocked;
        }
        // Finish admitted attempts even if the caller drops its request while
        // Argon2 is running. Cancellation must not erase a guess from the budget.
        let gate = self.clone();
        tokio::spawn(async move { gate.verify_serialized(secret).await })
            .await
            .unwrap_or(UnlockOutcome::LockedOut)
    }

    async fn verify_serialized(&self, secret: String) -> UnlockOutcome {
        // One admission gate for HTTP and WebSocket requests. Keep it through
        // verification and backoff so queued callers recheck the updated state.
        let _admission = self.admission.lock().await;
        if self.locked_out() {
            return UnlockOutcome::LockedOut;
        }
        // Capped here rather than at each caller, so both doors agree. The HTTP
        // token endpoint has always refused a body over this; the WebSocket
        // UNLOCK frame would take up to a 1 MiB payload and hand the whole
        // thing to argon2. Nobody's secret is a kilobyte, and a wrong one is a
        // wrong one however long it is.
        if secret.len() > MAX_SECRET_LEN {
            return self.record_failure().await;
        }
        // Serve any backoff still owed from a previous wrong secret, before
        // spending CPU on this one.
        let owed = {
            let state = self.state.lock().unwrap();
            state
                .not_before
                .and_then(|at| at.checked_duration_since(Instant::now()))
        };
        if let Some(delay) = owed {
            tokio::time::sleep(delay).await;
        }

        // Argon2 verification is CPU-heavy by design; keep it off the
        // async worker threads.
        let hash = Arc::clone(&self.hash);
        let ok = tokio::task::spawn_blocking(move || {
            PasswordHash::new(&hash)
                .map(|parsed| {
                    Argon2::default()
                        .verify_password(secret.as_bytes(), &parsed)
                        .is_ok()
                })
                .unwrap_or(false)
        })
        .await
        .unwrap_or(false);

        if ok {
            *self.state.lock().unwrap() = GateState::default();
            return UnlockOutcome::Unlocked;
        }

        self.record_failure().await
    }

    /// Counts one wrong secret, serves its backoff, and reports what is left.
    async fn record_failure(&self) -> UnlockOutcome {
        let (failures, backoff) = {
            let mut state = self.state.lock().unwrap();
            state.failures = state.failures.saturating_add(1).min(MAX_UNLOCK_FAILURES);
            if state.failures >= MAX_UNLOCK_FAILURES {
                state.locked_until = Some(Instant::now() + LOCKOUT);
            }
            let backoff = Duration::from_millis((500u64 << state.failures).min(60_000));
            // Recorded before the sleep, so a caller who hangs up mid-wait
            // still owes it on the next attempt.
            state.not_before = Some(Instant::now() + backoff);
            (state.failures, backoff)
        };
        if failures >= MAX_UNLOCK_FAILURES {
            return UnlockOutcome::LockedOut;
        }
        // Still slept here as well, so a caller that waits for its answer sees
        // the delay rather than a fast refusal it could retry in a tight loop.
        tokio::time::sleep(backoff).await;
        UnlockOutcome::Wrong {
            attempts_left: MAX_UNLOCK_FAILURES - failures,
        }
    }
}

#[cfg(test)]
mod token_tests {
    use super::*;

    #[test]
    fn tokens_are_bound_to_the_login_that_minted_them() {
        let store = TokenStore::new();
        let token = store.issue("alice@example.com");
        assert!(store.check(&token, "alice@example.com"));
        assert!(!store.check(&token, "bob@example.com"));
        assert!(!store.check("not-a-token", "alice@example.com"));
    }

    #[test]
    fn the_token_map_stays_bounded() {
        let store = TokenStore::new();
        let first = store.issue("alice@example.com");
        for _ in 0..MAX_LIVE_TOKENS * 2 {
            let token = store.issue("alice@example.com");
            assert!(store.check(&token, "alice@example.com"));
        }
        assert!(
            store.grants.lock().unwrap().len() <= MAX_LIVE_TOKENS,
            "the map must not grow without bound"
        );
        assert!(!store.check(&first, "alice@example.com"));
    }
}

#[cfg(test)]
mod lockout_tests {
    use super::*;

    fn hash_of(secret: &str) -> String {
        use argon2::password_hash::{rand_core::OsRng, PasswordHasher, SaltString};
        let salt = SaltString::generate(&mut OsRng);
        Argon2::default()
            .hash_password(secret.as_bytes(), &salt)
            .unwrap()
            .to_string()
    }

    #[tokio::test]
    async fn lockout_expires_and_restores_the_budget() {
        let gate = UnlockGate::new(hash_of("correct-horse"));
        {
            let mut state = gate.state.lock().unwrap();
            state.failures = MAX_UNLOCK_FAILURES;
            // Already elapsed: stands in for a cooling period that has run out.
            state.locked_until = Some(Instant::now() - Duration::from_secs(1));
        }
        assert!(
            !gate.locked_out(),
            "an expired lock-out must reopen the gate"
        );
        assert_eq!(gate.attempts_left(), MAX_UNLOCK_FAILURES);
        assert!(matches!(
            gate.verify("correct-horse".to_string()).await,
            UnlockOutcome::Unlocked
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn concurrent_attempts_share_one_budget() {
        let gate = UnlockGate::new(hash_of("correct"));
        let mut tasks = Vec::new();
        for _ in 0..12 {
            let gate = gate.clone();
            tasks.push(tokio::spawn(
                async move { gate.verify("wrong".into()).await },
            ));
        }
        let mut wrong = 0;
        let mut locked = 0;
        for task in tasks {
            match task.await.unwrap() {
                UnlockOutcome::Wrong { .. } => wrong += 1,
                UnlockOutcome::LockedOut => locked += 1,
                UnlockOutcome::Unlocked => panic!("wrong secret unlocked"),
            }
        }
        assert_eq!(wrong, 9);
        assert_eq!(locked, 3);
        assert_eq!(gate.state.lock().unwrap().failures, MAX_UNLOCK_FAILURES);
    }

    #[tokio::test(start_paused = true)]
    async fn a_queued_correct_secret_cannot_reset_a_new_lockout() {
        let gate = UnlockGate::new(hash_of("correct"));
        gate.state.lock().unwrap().failures = MAX_UNLOCK_FAILURES - 1;
        let (wrong, correct) =
            tokio::join!(gate.verify("wrong".into()), gate.verify("correct".into()),);
        assert!(matches!(wrong, UnlockOutcome::LockedOut));
        assert!(matches!(correct, UnlockOutcome::LockedOut));
        assert!(gate.locked_out());
    }

    #[tokio::test(start_paused = true)]
    async fn oversized_attempts_cannot_overflow_a_locked_gate() {
        let gate = UnlockGate::new(hash_of("correct"));
        gate.state.lock().unwrap().failures = MAX_UNLOCK_FAILURES - 1;
        for _ in 0..70 {
            assert!(matches!(
                gate.verify("x".repeat(MAX_SECRET_LEN + 1)).await,
                UnlockOutcome::LockedOut
            ));
        }
        assert_eq!(gate.state.lock().unwrap().failures, MAX_UNLOCK_FAILURES);
    }

    #[tokio::test]
    async fn lockout_holds_while_the_cooling_period_runs() {
        let gate = UnlockGate::new(hash_of("correct-horse"));
        {
            let mut state = gate.state.lock().unwrap();
            state.failures = MAX_UNLOCK_FAILURES;
            state.locked_until = Some(Instant::now() + LOCKOUT);
        }
        assert!(gate.locked_out());
        assert!(matches!(
            gate.verify("correct-horse".to_string()).await,
            UnlockOutcome::LockedOut
        ));
    }
}

/// How long an issued API token stays valid.
///
/// Short because it only has to outlive a picker and a request, and a token is
/// held in the app's memory rather than in its Keychain: a foregrounded app
/// that needs another one can always ask, since it holds the secret that mints
/// them.
pub const TOKEN_TTL: Duration = Duration::from_secs(600);

/// Live tokens kept at once. One phone needs one; the cap exists so a caller
/// that mints in a loop cannot grow the map without bound.
const MAX_LIVE_TOKENS: usize = 32;

// ---- API tokens ----
//
// The bearer tokens the HTTP endpoints (`docs/HTTP.md`) spend. They live here
// rather than beside any one of those endpoints because all three families
// take the same one: it is an authentication concern, not a file one.

struct Grant {
    login: String,
    expires: Instant,
}

/// Bearer tokens minted by `POST /v1/token` and spent on every other HTTP
/// endpoint.
///
/// In memory only: a daemon restart invalidates every token, which is correct.
/// There is nothing to persist and nothing on disk to leak.
#[derive(Clone, Default)]
pub struct TokenStore {
    grants: Arc<Mutex<HashMap<String, Grant>>>,
}

impl TokenStore {
    pub fn new() -> Self {
        TokenStore::default()
    }

    /// Mints a token bound to `login`, valid for [`TOKEN_TTL`].
    pub fn issue(&self, login: &str) -> String {
        let token = random_hex(32);
        let mut grants = self.grants.lock().unwrap();
        let now = Instant::now();
        grants.retain(|_, grant| grant.expires > now);
        // Still full after pruning: drop whichever grant dies soonest, so a
        // token that was just minted is never the one evicted.
        while grants.len() >= MAX_LIVE_TOKENS {
            let Some(oldest) = grants
                .iter()
                .min_by_key(|(_, grant)| grant.expires)
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            grants.remove(&oldest);
        }
        grants.insert(
            token.clone(),
            Grant {
                login: login.to_string(),
                expires: now + TOKEN_TTL,
            },
        );
        token
    }

    /// True when `token` is live and was minted for `login`.
    ///
    /// The lookup is not constant time and does not need to be: a token is 256
    /// bits from the OS CSPRNG, so there is no guess close enough for a timing
    /// difference to steer.
    pub fn check(&self, token: &str, login: &str) -> bool {
        let mut grants = self.grants.lock().unwrap();
        let now = Instant::now();
        grants.retain(|_, grant| grant.expires > now);
        grants.get(token).is_some_and(|grant| grant.login == login)
    }
}

/// `bytes` bytes from the OS CSPRNG, hex encoded. Shared with the file inbox,
/// which uses it for the suffix that makes an upload name unique.
pub fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    rand::rngs::OsRng.fill_bytes(&mut buf);
    buf.iter().map(|byte| format!("{byte:02x}")).collect()
}
