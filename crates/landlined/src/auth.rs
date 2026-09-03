//! Identity and unlock gating.
//!
//! Identity arrives out-of-band on the WebSocket upgrade request via the
//! `Tailscale-User-Login` header (injected by `tailscale serve`). It is
//! verified *before* the upgrade completes; failures are a plain HTTP 403.
//!
//! The optional unlock secret is a second factor checked in-band during the
//! protocol handshake (NEED_UNLOCK / UNLOCK frames), argon2id-verified
//! against `Config::unlock_hash`.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use argon2::password_hash::PasswordHash;
use argon2::{Argon2, PasswordVerifier};
use axum::http::HeaderMap;

use crate::config::Config;

/// Header carrying the authenticated tailnet login on the upgrade request.
pub const LOGIN_HEADER: &str = "Tailscale-User-Login";

/// After this many wrong unlock secrets the daemon refuses every further
/// attempt until it is restarted.
pub const MAX_UNLOCK_FAILURES: u32 = 10;

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
}

#[derive(Clone)]
pub struct UnlockGate {
    /// PHC-format argon2id hash; empty means unlock is not required.
    hash: Arc<str>,
    state: Arc<Mutex<GateState>>,
}

impl UnlockGate {
    pub fn new(unlock_hash: String) -> Self {
        UnlockGate {
            hash: unlock_hash.into(),
            state: Arc::new(Mutex::new(GateState::default())),
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
        if self.locked_out() {
            return UnlockOutcome::LockedOut;
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

        let failures = {
            let mut state = self.state.lock().unwrap();
            state.failures += 1;
            if state.failures >= MAX_UNLOCK_FAILURES {
                state.locked_until = Some(Instant::now() + LOCKOUT);
            }
            state.failures
        };
        if failures >= MAX_UNLOCK_FAILURES {
            return UnlockOutcome::LockedOut;
        }
        let backoff = Duration::from_millis((500u64 << failures).min(60_000));
        tokio::time::sleep(backoff).await;
        UnlockOutcome::Wrong {
            attempts_left: MAX_UNLOCK_FAILURES - failures,
        }
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
