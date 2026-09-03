# Landline

Reach every machine you own from your phone. Terminal only, over your own tailnet.

> A landline is a fixed, private, direct line to a known place. That is the whole product.

## 1. What this is

A small daemon you run on each of your machines, plus a native iOS app that gives you a real
shell on any of them. No VPN setup, no port forwarding, no SSH key management, no bastion host.
Tailscale already put your machines on one private network; this is the client that makes that
network usable from a phone.

### Non-goals

Stated up front so they stay dead:

- **No screen sharing or remote desktop.** Terminal forever. If you need a desktop, use Screen
  Sharing or RustDesk.
- No file manager, no SFTP browser, no port forwarding UI.
- No Android, no web client, no desktop client.
- No hosted service, no accounts, no server you have to trust. There is no backend.
- No multi-user or team features. One person, N machines.

### Why build it when Tailscale SSH + Blink Shell exists

Honest answer: that combination already gives you a shell on all three machines today. The bet is
that a purpose-built client beats a general one for this specific job:

- Three machines in a list, one tap to switch, no host config files.
- Sessions that survive the subway, because the agent keeps the PTY alive and replays on reattach.
- A keyboard built for shells instead of prose.
- Zero setup on the phone beyond installing Tailscale.

If those four do not feel meaningfully better than Blink in daily use, the project has no reason
to exist. Worth checking honestly at M4.

## 2. Target hardware

The three machines this is designed against:

| Machine | OS | Role | Shell |
|---|---|---|---|
| MacBook Pro | macOS | daily driver | zsh |
| Home server | Ubuntu | headless, always on | bash |
| Laptop | Windows / Omarchy dual boot | occasional | PowerShell / bash |

All three already run Tailscale. The iPhone runs the Tailscale app.

The Windows side is supported because `portable-pty` wraps ConPTY behind the same API as
`forkpty`, so the marginal cost is a service wrapper and a config path. Reaching the laptop
should not depend on which OS happened to boot.

## 3. Architecture

```
iPhone (Tailscale app active)
   |
   |  HTTPS / WSS  ->  macbook.<tailnet>.ts.net
   v
tailscale serve :443
   |
   |  HTTP / WS  ->  127.0.0.1:7777  (loopback only, see 4.3)
   v
landlined
   |
   +-- PTY session A  (detached, alive)
   +-- PTY session B
```

Tailscale supplies everything the original design would have had to build:

| Would have needed | Tailscale provides |
|---|---|
| Signaling server | The tailnet itself |
| TURN relay | DERP |
| WebRTC + ICE + reconnect logic | WireGuard, which roams across networks |
| Pairing ceremony (SPAKE2, TOFU pinning) | Tailnet identity and ACLs |
| Self-signed cert handling in the client | Real Let's Encrypt cert on `*.ts.net` |

The client therefore speaks plain `URLSessionWebSocketTask` to a URL with a valid certificate.
No WebRTC framework, no signaling client, no certificate pinning code.

### Components

- **`landlined`** (Rust). One static binary per platform. Runs a WebSocket server bound to
  loopback, owns PTY sessions, holds no network-facing surface of its own.
- **`tailscale serve`** (already installed). Terminates TLS on the tailnet, proxies to the
  daemon, injects caller identity headers.
- **iOS app** (Swift + SwiftUI + SwiftTerm).

## 4. Security model

The threat model is narrow and should stay that way: the daemon must be unreachable from
anything that is not an authorized node on the tailnet, and reaching it must not be enough to
get a shell if the phone is stolen.

### 4.1 Network reachability

`landlined` binds to loopback only, never `0.0.0.0`. Everything from outside arrives through
`tailscale serve`, which means a machine on the same LAN but not on the tailnet cannot reach the
port at all. Tailnet ACLs narrow it further:

```jsonc
{
  "tagOwners": {
    "tag:phone":     ["autogroup:admin"],
    "tag:landlinehost": ["autogroup:admin"]
  },
  "grants": [
    { "src": ["tag:phone"], "dst": ["tag:landlinehost"], "ip": ["tcp:443"] }
  ]
}
```

### 4.2 Caller identity

`tailscale serve` injects `Tailscale-User-Login`, `Tailscale-User-Name` and
`Tailscale-User-ProfilePic` when proxying to a plaintext backend. The daemon allowlists logins in
config and rejects everything else with 403 before the WebSocket upgrade completes.

### 4.3 Loopback and local processes

Tailscale documents that serve **strips incoming `Tailscale-*` headers before injecting its own**
(see their `id-headers-demo` repository), so a tailnet peer cannot forge an identity.
**Verified empirically 2026-09-03 on tailscale 1.102.3**: a request through serve carrying a
forged `Tailscale-User-Login` arrived at the backend with the forged value stripped and the
real identity in its place. Header identity is trusted from serve.

What remains is narrower: **any local process on the host can connect to `127.0.0.1:7777`
directly**, bypassing serve, and supply its own headers. On a single-user MacBook this is close
to irrelevant. On the Ubuntu server it is not.

`tailscale serve` has no unix socket backend, so filesystem permissions cannot be the boundary.
Two real options:

1. **Accept it on single-user machines, document it loudly.** The unlock secret (4.5) still
   stands between a local process and a shell it does not already have.
2. **Hardened mode, no serve at all:** bind the daemon to the machine's tailnet `100.x` address
   and identify each peer via the tailscaled LocalAPI WhoIs endpoint
   (`/localapi/v0/whois?addr=ip:port`, Rust crate `tailscale-localapi`). No loopback listener,
   no header trust, no serve config to drift. Costs: TLS must come from `tailscale cert`
   (renewal handling included), and WhoIs does not work under userspace-networking, where every
   peer appears as 127.0.0.1. All three target hosts run normal kernel-mode Tailscale, so this
   limitation does not bite here.

v0 ships option 1 with serve. Option 2 is the designed escape hatch if the daemon ever runs on
a genuinely multi-user machine, and nothing in the protocol or client depends on which one is in
front.

### 4.4 The admin socket

`landlined sessions list` and `kill` talk to the daemon over a unix socket next to the config
file, mode 0700. It has no authentication of its own: anything running as your user can list and
kill your sessions. That is the same trust level as the loopback listener above, and on Windows
the socket does not exist at all, which is why `sessions` is unavailable there.

### 4.5 Unlock secret

Identity proves *which tailnet user* is calling. It does not prove the phone is in your hands.
So, independently of Tailscale:

- Optional per-host unlock secret, argon2id hashed in the daemon config, never stored on the
  phone in plaintext.
- Verified over the WebSocket **before any PTY is spawned**.
- Exponential backoff on repeated failures, then a 15 minute lock-out.
  The lock-out is deliberately time-limited rather than permanent: a lock that
  only a daemon restart could clear would let anyone who reaches the unlock
  stage deny you the very access you are away from the machine to use.
- Face ID / passcode gate on app foreground, enforced client side.

Set it on the Ubuntu server. Probably skip it on the laptop. Make it per-host, not global.

### 4.6 What is deliberately not defended against

- A compromised tailnet coordination server. Tailscale's threat model is inherited wholesale.
- A rooted or jailbroken phone with the app unlocked.
- Anyone with physical root on a host, who does not need this app to get a shell.

## 5. Wire protocol

One WebSocket. Binary frames. Freeze this at M0 and change it only with a version bump.

```
frame = [u8 type][u32 length big-endian][payload]
```

### Client to agent

| Type | Name | Payload |
|---|---|---|
| `0x01` | STDIN | raw bytes written to the PTY |
| `0x02` | RESIZE | `[u16 cols][u16 rows]` big-endian |
| `0x03` | ATTACH | JSON `{proto_version, session_id?, cmd?, cwd?, cols, rows}` |
| `0x04` | PING | 8 bytes, client monotonic nanos |
| `0x05` | UNLOCK | UTF-8 secret |
| `0x06` | DETACH | empty, leave the session running |
| `0x07` | KILL | empty, terminate the session |

### Agent to client

| Type | Name | Payload |
|---|---|---|
| `0x81` | STDOUT | raw PTY output |
| `0x82` | ATTACHED | JSON `{session_id, cols, rows, replay_bytes, shell, host, created_at}` |
| `0x83` | EXIT | `[u32 exit_code]` |
| `0x84` | PONG | echo of the PING payload |
| `0x85` | ERR | JSON `{code, message}` |
| `0x86` | NEED_UNLOCK | JSON `{attempts_left}` |

Error codes: `SESSION_GONE`, `SESSION_REPLACED`, `UNAUTHORIZED`, `LOCKED_OUT`, `TOO_MANY_SESSIONS`,
`SPAWN_FAILED`, `PROTOCOL_VERSION`, `CLIENT_TOO_SLOW`.

`proto_version` is 1. The daemon answers an unknown version with `ERR PROTOCOL_VERSION` carrying
the versions it supports, and the app shows an update prompt instead of garbage. The app and the
daemon ship independently; skew is the normal case, not the exception.

Handshake order: connect, `ATTACH`, then either `NEED_UNLOCK` (client sends `UNLOCK`, repeat) or
`ATTACHED` followed by replay bytes and then live output.

Unlock is **per connection**, not per session: resuming a session over a new connection requires
unlocking again. The Keychain holds the secret so the user does not retype it, but a stolen
session id alone is never enough.

## 6. Session persistence

WireGuard roams across networks; a TCP socket does not. Sessions must outlive the connection, and
this belongs in v0, not a later milestone. Without it the app is unusable on a train.

- The daemon holds `session_id -> { pty master, child pid, ring buffer, last_seen, cols, rows }`.
- `ATTACH` with no `session_id` creates a session and returns a fresh UUID.
- `ATTACH` with a known `session_id` replays the ring buffer, then tails live.
- `ATTACH` with an unknown id returns `ERR SESSION_GONE`.
- **Any transport drop is an implicit detach.** iOS routinely kills the socket before a
  `DETACH` frame can flush, so the explicit frame is an optimization, never a requirement.
- **Reattach applies the client's current `cols`/`rows` to the PTY** even when they match the old
  values only approximately. The resulting SIGWINCH makes full-screen programs repaint, which is
  also the cheapest mitigation for replay artifacts.
- Detached sessions are reaped after `session_ttl_hours` without an attached client, default 24.
  Note this measures client attention, not process activity: a detached `top` dies at the TTL.
  Raise the TTL in config for machines that run long jobs.
- Ring buffer defaults to 256 KB.
- **One client attached per session in v0.** A second attach evicts the first with
  `ERR SESSION_REPLACED`. Multi-attach, tmux style, is a plausible v2 but invites echo and
  resize conflicts that are not worth it yet.

### Known limitation: replay artifacts

Replaying a raw byte ring into a fresh terminal can start mid escape sequence and render garbage.
Mitigation for v0 is to send `\x1b[2J\x1b[H` before the replay and accept occasional artifacts.

The correct fix is what tmux and mosh do: maintain a **screen state model** server side and
synchronize state rather than bytes. That is real work and a genuine v2 candidate. Do not pretend
the byte ring is equivalent.

## 7. Daemon surface

### CLI

```
landlined serve                 # foreground, what the service unit runs
landlined install               # launchd plist / systemd unit / Windows scheduled task at logon
landlined uninstall
landlined status                # running? sessions? tailscale serve configured?
landlined doctor                # verify tailscale up, serve mapping, ACL reachability, perms
landlined sessions list
landlined sessions kill <id>
landlined config path
landlined set-unlock            # prompt, argon2id hash into config
```

`doctor` matters more than it looks. Serve configuration is per-machine state that drifts, and
"why can I not reach the laptop" needs a one-command answer.

### Config

TOML, at `~/.config/landline/config.toml`, `~/Library/Application Support/landline/config.toml`, or
`%APPDATA%\landline\config.toml`.

```toml
listen            = "127.0.0.1:7777"   # loopback TCP; see 4.3 on why not a unix socket
allowed_logins    = ["you@example.com"]
shell             = ""                  # empty = $SHELL; on Windows pwsh, then powershell.exe
default_cmd       = ""                  # e.g. "tmuxon"; runs as `$SHELL -i -c`, so aliases resolve
session_ttl_hours = 24
scrollback_bytes  = 262144
max_sessions      = 8
unlock_hash       = ""                  # argon2id, empty = no unlock secret
```

## 8. iOS app scope

- Host list. Name, `ts.net` hostname, color. Manually entered, no discovery, no credentials.
- Terminal view on SwiftTerm. Do not hand-roll ANSI emulation.
- Keyboard accessory bar: Esc, Tab, Ctrl (sticky), Alt, arrows, and `~ | / -`.
- Session list per host with resume and kill.
- Snippets. Saved commands, tap to insert. Cheap to build, disproportionately useful on a phone.
- Face ID gate, per host. Client-side and therefore cosmetic; the unlock secret is the real gate.
- Font size and theme.
- Background handling: send `DETACH` on backgrounding, reattach on foreground. Getting this wrong
  leaks sessions and is the most likely source of "it stopped working" reports.
- Onboarding that walks a stranger from install to first shell, including how to get `landlined`
  running on their own machine. This is now the funnel, not a nicety.

## 9. Licensing and distribution

**MIT across the whole repo**, agent and iOS client alike.

The App Store build is paid at roughly $10, but that price is a tip jar, not a moat. People who
want the app without a build toolchain pay for the convenience and to support the work. People who
want to build it themselves can, and are welcome to.

Permissive licensing is a deliberate choice to keep Apple out of the picture entirely. GPLv3 would
prevent a third party from listing a fork on the App Store, but it also creates a permanent
compatibility argument with App Store distribution terms that is not worth having for a project of
this size. MIT has no such friction.

The accepted tradeoff, stated once so it is not rediscovered later as a surprise: **anyone can
rebuild the client and list it on the App Store for free.** That is fine. If it happens, the paid
listing was never the point.

Consider dual MIT OR Apache-2.0 on the Rust crates, which is the Rust ecosystem convention and adds
an explicit patent grant. The only cost is a second license file. Not required.

No CLA. Contributions come in under MIT like everything else.

### App Store notes

- Remote terminal apps have clear precedent: Termius, Blink, Prompt, Secure ShellFish. Review risk
  is low.
- Set `ITSAppUsesNonExemptEncryption` in Info.plist. Leaving export compliance unanswered makes
  builds vanish from TestFlight even when they show as VALID.
- The app is useless without a daemon running somewhere. The App Store description and the
  onboarding flow both have to make that obvious, or the refund and one-star rate will reflect it.

## 10. Milestones

| M | Deliverable | Rough effort |
|---|---|---|
| M0 | Repo, Cargo workspace, wire format frozen, this document | hours |
| M1 | `landlined`: PTY over WebSocket on loopback, browser test harness | a weekend |
| M2 | `tailscale serve` in front, identity headers, **resolve 4.3**, ACL tags, reachable from phone | an evening plus the 4.3 investigation |
| M3 | iOS: SwiftTerm, host list, connect, keyboard bar | 1 to 2 weeks |
| M4 | Session resume, detach on background, reattach on foreground | a few days |
| M5 | Packaging: launchd, systemd, Windows scheduled task, brew tap, `.deb`, `install.sh` | a few days |
| M6 | Onboarding, App Store listing, screenshots, privacy nutrition labels | 1 week |

Personal v0 is done at M4. M5 and M6 exist only because it is being sold.

Note that M5 grew in importance the moment this became a product. A stranger who cannot get
`landlined` running in under two minutes will refund.

## 11. Risks

1. **Header stripping must be verified empirically at M2**, even though Tailscale documents it.
   Fifteen minutes. If our serve version forwards forged `Tailscale-*` headers, switch to the
   WhoIs architecture in 4.3 before M3.
2. **Replay artifacts** from the byte ring buffer will be visible and will look like bugs.
   Document the limitation, or spend the v2 effort on a screen state model.
3. **iOS background socket termination** is the classic source of leaked sessions and phantom
   disconnects. Budget real time for M4; it is not a half day.
4. **Windows ConPTY** is the least tested path. Resize semantics and signal handling differ from
   Unix in ways that surface late, and a session-0 service cannot host ConPTY sanely, which is why
   install uses a scheduled task at logon instead of a service.
5. **Value proposition versus Blink Shell.** Re-evaluate honestly at M4. If it is not clearly
   better for this job it still works as a personal tool, and M5 and M6 become optional rather than
   wasted.
6. **Name.** `landline` is a common English word, which makes it hard to defend but also hard to
   collide with. A cursory App Store and npm search before the listing is enough. There is no brand
   to protect here.

## 12. Open questions

- Dual MIT OR Apache-2.0 on the Rust crates, or plain MIT everywhere. Low stakes either way.
- Whether hardened mode (4.3 option 2) is worth building at all, or stays a documented design.
