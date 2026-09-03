# Landline: implementation plan

Companion to `SCOPE.md`. That document says what and why. This one says in what order, with what
crates, and how you know each step is finished.

Nothing is built until this plan is agreed. Read section 0 first, because one unresolved question
can invalidate the authentication design in section M2.

---

## 0. Decisions already locked

Recorded so they do not get relitigated mid-build.

| Decision | Value |
|---|---|
| Name | `landline`, daemon binary `landlined` |
| Scope | Terminal only. No screen sharing, ever. |
| Transport | WebSocket over Tailscale. No WebRTC, no signaling server, no TURN. |
| Agent language | Rust |
| Client | Native iOS only. No web, no Android, no desktop. |
| Host platforms | macOS, Linux, Windows |
| Host discovery | Manual list in the app. No Tailscale API, no probing. |
| Licence | MIT throughout |
| Distribution | Source public, paid App Store build as a tip jar |
| Session resume | In v0, not deferred |

---

## 1. Repository layout

```
landline/
├── Cargo.toml                    # workspace
├── LICENSE                       # MIT
├── README.md                     # quickstart, 20 lines, not a manifesto
├── crates/
│   ├── landline-proto/           # wire format, pure, no I/O
│   │   └── src/lib.rs
│   ├── landlined/                # the daemon
│   │   └── src/
│   │       ├── main.rs           # clap dispatch
│   │       ├── config.rs         # TOML, platform paths, defaults
│   │       ├── server.rs         # axum routes, WS upgrade, frame loop
│   │       ├── auth.rs           # identity headers, unlock, backoff
│   │       ├── session.rs        # Session, SessionManager, reaper
│   │       ├── pty.rs            # portable-pty bridge, blocking to async
│   │       ├── ring.rs           # scrollback buffer
│   │       ├── doctor.rs         # health checks
│   │       └── install/
│   │           ├── mod.rs
│   │           ├── launchd.rs
│   │           ├── systemd.rs
│   │           └── windows.rs
│   └── landline-cli/             # terminal test client, no iOS needed
│       └── src/main.rs
├── ios/
│   └── Landline.xcodeproj        # SwiftUI + SwiftTerm
├── harness/
│   └── index.html                # M1 throwaway: xterm.js in a browser
├── packaging/
│   ├── homebrew/landline.rb
│   ├── debian/
│   └── install.sh
└── docs/
    ├── SCOPE.md
    ├── PLAN.md                   # this file
    └── PROTOCOL.md               # normative frame spec
```

`landline-proto` exists as its own crate so the daemon and the CLI test client share one
definition of the wire format, and so the Swift implementation has one file to mirror.

## 2. Dependencies

```toml
# landline-proto
serde        = { version = "1",  features = ["derive"] }
serde_json   = "1"
thiserror    = "2"

# landlined
axum         = { version = "0.8", features = ["ws"] }
tokio        = { version = "1",   features = ["rt-multi-thread","macros","net","sync","time","io-util","signal"] }
portable-pty = "0.9"
clap         = { version = "4",   features = ["derive"] }
toml         = "0.8"
argon2       = "0.5"
uuid         = { version = "1",   features = ["v4","serde"] }
directories  = "5"
tracing      = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
anyhow       = "1"
bytes        = "1"
```

`portable-pty` is the single most important pick. It wraps ConPTY on Windows behind the same API
as `forkpty` on Unix, which is what makes Windows support close to free rather than a second
implementation.

Pin exact versions at M0 and commit `Cargo.lock`. This ships as a binary, not a library.

---

## M0: Foundation

Effort: a few hours. No product behaviour.

| # | Task | Done when |
|---|---|---|
| 0.1 | `git init`, MIT `LICENSE`, `.gitignore`, stub `README.md` | repo exists, first commit |
| 0.2 | Cargo workspace with the three crates stubbed | `cargo build` succeeds on macOS |
| 0.3 | Write `docs/PROTOCOL.md` as the normative frame spec | every frame type from SCOPE section 5 documented with byte layout and an example |
| 0.4 | GitHub Actions: fmt, clippy, test on ubuntu / macos / windows | all three green on an empty workspace |
| 0.5 | Decide MIT vs dual MIT-or-Apache | one licence file committed |

**Exit criteria:** CI is green on three operating systems before a single line of real logic
exists. Setting this up later is how Windows support quietly rots.

---

## M1: Daemon core

Effort: a weekend. This is the biggest single chunk of Rust and everything else depends on it.

### 1.1 `landline-proto`

```rust
pub enum ClientFrame { Stdin(Bytes), Resize{cols:u16, rows:u16}, Attach(AttachReq),   // AttachReq carries proto_version: u32
                       Ping([u8;8]), Unlock(String), Detach, Kill }
pub enum ServerFrame { Stdout(Bytes), Attached(AttachedResp), Exit(u32),
                       Pong([u8;8]), Err(ProtoError), NeedUnlock{attempts_left:u32} }
```

Encode and decode `[u8 type][u32 len BE][payload]`. Reject frames over 1 MiB. Unit tests for
roundtrip on every variant, plus truncated and oversized input.

### 1.2 `pty.rs`, the part that is easy to get wrong

`portable-pty` is **blocking**, not async. Bridging it correctly is the crux of M1:

- **Reader:** a `std::thread` doing blocking 8 KiB reads on the PTY master, pushing `Bytes` into a
  `tokio::sync::mpsc::UnboundedSender`. Not `spawn_blocking`, because this thread lives for the
  whole session and would occupy a pool slot forever.
- **Writer:** a `std::thread` draining an `mpsc::Receiver<Bytes>` into blocking `write_all`.
- **Reaper:** a third thread on `child.wait()`, sending the exit code.
- Resize goes through `PtyPair::master.resize()`, which is safe to call from any thread.

Three threads per session. With `max_sessions` at 8 that is 24 threads worst case, which is fine
and much simpler than fighting async PTY abstractions.

### 1.3 `ring.rs`

`VecDeque<u8>`, push bytes at the back, pop from the front while `len > capacity`. Default 256 KiB.
`snapshot()` returns a contiguous `Vec<u8>`. Amortised O(1). Tests: wraparound correctness, exact
capacity boundary, snapshot after wrap.

### 1.4 `session.rs`

```rust
struct Session {
    id: Uuid,
    pty_writer: mpsc::Sender<Bytes>,
    ring: Mutex<Ring>,
    attached: Mutex<Option<AttachedClient>>,   // generation-tagged
    master: Box<dyn MasterPty>,
    last_seen: AtomicI64,
    created_at: i64,
}
struct SessionManager { sessions: RwLock<HashMap<Uuid, Arc<Session>>>, cfg: Config }
```

Output fan-out uses a **single swappable `mpsc::Sender` slot**, not `broadcast`. A lagging
`broadcast` receiver silently drops messages, which corrupts a terminal stream. A bounded
`mpsc(1024)` applies backpressure instead, and if it fills, disconnect the client with
`ERR CLIENT_TOO_SLOW`. The ring buffer still holds the data, so reattaching recovers cleanly.

The attached slot is **generation-tagged**. When a second client attaches, bump the generation,
send `ERR SESSION_REPLACED` to the old sender, and install the new one. Without the generation
counter the old connection's task races the new one on teardown.

Reaper task on a 60 second interval, killing sessions idle past `session_ttl_hours`.

### 1.5 `server.rs`

`GET /v1/shell` upgrades to WebSocket. Set the WebSocket `max_message_size` to 1 MiB to match the
protocol cap; the tungstenite default is far larger and would let a peer buffer garbage. Behind a
dev-only `--features harness` flag, `GET /` serves the harness page so you can test without the
iOS app.

Per-connection loop:

1. Await `Attach` with a 10 second timeout, else close.
2. Reject unknown `proto_version` with `ERR PROTOCOL_VERSION` listing supported versions.
3. Create or resume the session, and **resize the PTY to the client's cols and rows**, so the
   SIGWINCH forces full-screen programs to repaint over the replay.
4. Send `Attached`, then `\x1b[2J\x1b[H`, then the ring snapshot, then go live.
5. Pump frames both ways until either side ends. **Any disconnect is an implicit detach**; the
   explicit `Detach` frame is an optimization the server must never depend on.

### 1.6 Harness

One HTML file, `xterm.js` from a CDN, `FitAddon` for sizing. Derive the socket URL from
`location` (`wss:` when the page came over `https:`), never hardcode `ws://127.0.0.1`, or the
harness silently breaks the moment it sits behind serve at M2. Disposable. Deleted at M3, or kept as a debugging tool.

**Exit criteria for M1, in order of how much they prove:**

- A shell appears in the browser.
- `htop` renders correctly and redraws on resize.
- **`vim` is fully usable**, including `:wq`. This exercises alternate screen buffer, cursor
  addressing and escape sequence handling all at once. If vim works, the PTY layer is right.
- Ctrl-C interrupts a running `sleep 100`.
- Killing the browser tab leaves the session alive; reconnecting resumes it with scrollback.

---

## M2: Tailnet integration

Effort: one evening, plus however long the investigation takes. **Two blocking investigations come
first.**

### 2.0 VERIFICATION: identity header stripping

Tailscale documents that serve strips incoming `Tailscale-*` headers before injecting its own
(their `id-headers-demo` repo exists to demonstrate exactly this), so the expected result is
known. Verify it anyway on our installed version before writing `auth.rs`; it costs fifteen
minutes and the whole auth design sits on it.

```bash
# On the MacBook, a throwaway server that dumps every request header:
python3 -c "
from http.server import *
class H(BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.end_headers()
        s.wfile.write(str(s.headers).encode())
HTTPServer(('127.0.0.1',7777),H).serve_forever()"

tailscale serve --bg --https=443 http://127.0.0.1:7777

# From the Ubuntu box, forging the header:
curl -s -H "Tailscale-User-Login: attacker@evil.com" \
     https://macbook.<tailnet>.ts.net/
```

Read the output and answer:

- Does exactly one `Tailscale-User-Login` arrive, or two?
- If two, which one would a header-map lookup return?
- Does the forged value survive at all?

**Expected: the forged value is stripped.** If our serve version forwards it anyway, do not
patch around it; switch to the WhoIs architecture from SCOPE 4.3 option 2, where the daemon binds
the tailnet address and asks tailscaled who the peer is.

### 2.1 RESOLVED: no unix socket backend in serve

`tailscale serve` proxies to local TCP ports, not unix sockets, so filesystem permissions cannot
be the local trust boundary. v0 keeps loopback TCP and accepts the local-process bypass on
single-user machines, with the unlock secret as the second factor; SCOPE 4.3 records the WhoIs
direct-bind design as the hardened alternative. Nothing to investigate, one sentence to put in
the README's security section.

### 2.2 through 2.5

| # | Task | Notes |
|---|---|---|
| 2.2 | `auth.rs`: extract identity, check `allowed_logins`, reject with 403 **before** the WS upgrade | never upgrade an unauthorised connection |
| 2.3 | `doctor` checks: tailscaled running, MagicDNS and HTTPS certificates enabled on the tailnet, serve mapping present | serve silently requires both tailnet features |
| 2.4 | Unlock secret: argon2id verify on `spawn_blocking` (a deliberate ~100ms hash must not stall the runtime), `NEED_UNLOCK` flow, backoff, `landlined set-unlock` | delay `min(2^failures * 500ms, 60s)`, lock out after 10 |
| 2.5 | Tailnet ACL policy with `tag:phone` and `tag:landlinehost`, applied to all three machines | policy file committed to `docs/` |

**Exit criteria:** from the phone on cellular, open Safari at `https://macbook.<tailnet>.ts.net`
and get a working shell in the harness. A request from a non-allowlisted login gets 403. A wrong
unlock secret triggers visible backoff. Confirm the same on all three machines, including the
Windows boot.

---

## M3: iOS client

Effort: 1 to 2 weeks. The single largest milestone, and the only one that cannot be tested in CI.

| # | Task | Notes |
|---|---|---|
| 3.1 | Xcode project, SwiftUI lifecycle, SwiftTerm via SPM | iOS 17 deployment target |
| 3.2 | `Frame.swift`, a direct port of `landline-proto` encode and decode | keep it a literal mirror; divergence here is painful to debug |
| 3.3 | `Connection.swift` on `URLSessionWebSocketTask` | explicit state machine: connecting, attaching, unlocking, live, closed. If its ping and close handling proves flaky, the fallback is `NWConnection` with the WebSocket protocol options; isolate the transport behind a protocol so the swap stays cheap |
| 3.4 | `TerminalView`, a `UIViewRepresentable` around SwiftTerm | wire stdin, stdout and resize |
| 3.5 | Host list: `Codable` array in a file. Unlock secrets in Keychain, never in `UserDefaults` | three hosts does not justify SwiftData |
| 3.6 | Keyboard accessory bar: Esc, Tab, Ctrl as a sticky toggle, Alt, arrows, `~ \| / -` | sticky Ctrl is what makes this usable one-handed |
| 3.7 | Face ID gate on foreground, per host, via `LocalAuthentication` | |

Do **not** hand-roll terminal emulation. SwiftTerm handles the escape sequences that took vim
thirty years to rely on.

**Exit criteria:** a shell on all three machines from the phone, over cellular, with vim usable.

---

## M4: Resilience

Effort: a few days. Budget properly. iOS background lifecycle is the most likely source of "it
just stopped working".

| # | Task |
|---|---|
| 4.1 | Send `Detach` on `scenePhase` background as a courtesy; the server already treats any drop as detach. Never send `Kill` automatically. |
| 4.2 | Reattach on foreground using the stored `session_id` |
| 4.3 | Replay handling and honest measurement of artifact frequency |
| 4.4 | Ping/pong keepalive with dead-peer detection on both sides |
| 4.5 | Session list UI: resume, kill, show age |
| 4.6 | Reconnect with exponential backoff on transport failure |

**Exit criteria, the real test:** start `top` on the Ubuntu server, lock the phone, ride the metro
for twenty minutes through dead zones and network handoffs, unlock, and find the session still
there with correct output.

**Also at M4, honestly:** use it daily for a week, then ask whether it actually beats Blink Shell
over Tailscale SSH. If it does not, it is still a good personal tool, and M5 and M6 become
optional rather than wasted.

---

## M5: Packaging

Effort: a few days. This stopped being a chore the moment the app went on sale. A buyer who cannot
get `landlined` running in two minutes will refund.

| # | Task |
|---|---|
| 5.1 | `landlined install` writing launchd plist, systemd user and system units, and on Windows a scheduled task at logon (a session-0 service cannot host ConPTY sanely) |
| 5.2 | `landlined doctor`: is tailscaled up, is serve mapped, is the port bound, are permissions right |
| 5.3 | Release workflow: aarch64 and x86_64 macOS, aarch64 and x86_64 Linux via `cargo-zigbuild` or `cross` (plain cargo cannot cross-link glibc), x86_64 Windows |
| 5.4 | Homebrew tap, `.deb` via `cargo-deb`, `install.sh` |
| 5.5 | README quickstart: install, `landlined install`, `tailscale serve`, done |

`doctor` matters more than it looks. "Why can I not reach the laptop" needs a one-command answer,
for you and for strangers.

---

## M6: Store

Effort: about a week. Optional, contingent on the M4 honesty check.

- Onboarding that walks a stranger from install to first shell, including getting the daemon
  running on their own machine.
- Screenshots, description, privacy nutrition labels.
- `ITSAppUsesNonExemptEncryption` in Info.plist.
- The listing has to make the daemon requirement unmissable.

---

## 3. Testing

| Layer | Approach |
|---|---|
| `landline-proto` | Unit tests on every frame, plus truncated, oversized and unknown-type input |
| `ring.rs` | Wraparound, capacity boundary, snapshot after wrap |
| `session.rs` | Integration test spawning `cat`, asserting echo, detach, reattach and replay |
| End to end | `landline-cli` connects, runs `echo hi`, asserts output. Runs in CI on Linux and macOS. |
| Windows | Build in CI from M0. Add a ConPTY smoke test at M5. |
| iOS | Manual. Signing makes CI not worth it at this scale. |

---

## 4. Sequencing and effort

```
M0 ──▶ M1 ──▶ M2 ──▶ M3 ──▶ M4 ──┬──▶ M5 ──▶ M6
       core   tailnet  iOS  resume │
                                   └──▶ stop here if it is only for you
        ▲
        └── M2.0 investigation can run in parallel with M1,
            and should, because a bad answer reshapes M2
```

| Milestone | Effort |
|---|---|
| M0 | hours |
| M1 | a weekend |
| M2 | an evening, plus investigation |
| M3 | 1 to 2 weeks |
| M4 | a few days |
| M5 | a few days |
| M6 | about a week |

Roughly four to six weeks of evenings to a shipped app. Personal v0 lands at the end of M4, which
is closer to two or three.

---

## 5. First three actions

1. Run the M2.0 header verification. Expected to pass per Tailscale docs, still cheapest possible insurance.
2. M0 in full, so CI is green on three operating systems before any logic exists.
3. M1.1 and M1.2, `landline-proto` and `pty.rs`, because a correct PTY bridge is what M1 stands on.
