# Roadmap

What exists, what is being worked on next, and what will never be built. Written to be checkable:
if something is listed as done, it is in the repo and it runs.

Design and rationale live in `docs/SCOPE.md`. The normative wire spec is `docs/PROTOCOL.md`.

## Where it stands

The host side is real. The daemon serves PTY sessions over the wire protocol, survives
disconnects, and installs itself as a service on macOS, Linux, and Windows. You can use it today
with the bundled CLI client.

The iOS app is a working scaffold rather than a finished product: it builds, it has the wire codec
with unit tests behind it, it has the terminal view and the host list, and it has not yet been
through real day-to-day use from a phone. That is the current work.

## Done

**Wire protocol, version 1.** Binary framing (`[u8 type][u32 length BE][payload]`) over a single
WebSocket at `GET /v1/shell`, with a 1 MiB payload cap. Frame types, the handshake order, and every
error code are specified in `docs/PROTOCOL.md`, which is normative: code that disagrees with it is
wrong. Version 1 is frozen. Changes to it require a version bump, because the app and the daemon
ship independently and version skew is the normal case.

**The daemon (`landlined`).**

- PTY sessions through `portable-pty`, so the same code path covers `forkpty` on Unix and ConPTY
  on Windows.
- Session resume. Sessions outlive their connection; reattaching replays the scrollback ring, then
  tails live output. Any transport drop is an implicit detach, because iOS routinely kills a socket
  before an explicit frame can flush.
- Identity authentication. The tailnet login injected by `tailscale serve` is checked against
  `allowed_logins` and rejected with HTTP 403 before the WebSocket upgrade completes. An empty
  allowlist rejects everyone.
- Optional per-host unlock secret, argon2id hashed, verified before any PTY is spawned, with
  exponential backoff on wrong attempts and lockout after ten.
- Local admin socket for session listing and killing, backing `landlined sessions list` and
  `landlined sessions kill`.
- Session reaper that tears down sessions idle past `session_ttl_hours`.
- `landlined doctor`, eight checks covering the tailscale binary, backend state, MagicDNS, the
  serve mapping, the daemon's own listener, the admin socket, whether any login is allowed in, and
  the URL to type into the app. Serve config is per-machine state that drifts, so "why can I not
  reach that host" needed a one-command answer.
- `landlined install` / `uninstall`, writing a launchd plist on macOS, a systemd unit on Linux, and
  a scheduled task at logon on Windows (a session-0 service cannot host ConPTY sanely).

**CLI test client (`landline-cli`).** A real terminal client for the daemon: attach or resume, raw
mode, bytes both ways. It exists so the host side can be developed and debugged without an iPhone
in the loop, and it stays.

**iOS app scaffold.** SwiftUI app that builds against SwiftTerm, with the host list, terminal
screen, keyboard accessory bar, Keychain storage for per-host unlock secrets, and a `Frame.swift`
that mirrors the Rust wire codec and is covered by unit tests.

**Packaging and CI.** Release workflow producing binaries for macOS (aarch64, x86_64),
Linux (aarch64, x86_64, glibc pinned low via `cargo-zigbuild`), and Windows (x86_64), each with a
checksum. Homebrew formula and `install.sh` for host installation. CI runs fmt, clippy with
warnings denied, and the test suite on Ubuntu, macOS, and Windows on every push.

## Next

**Field testing from the phone.** Connecting to all three reference hosts from an actual iPhone,
over cellular, through `tailscale serve`, and confirming that vim is genuinely usable. Everything
below is gated on what that surfaces.

**Resilience.** The part that decides whether this is pleasant or infuriating:

- Session list per host in the app, with resume, kill, and session age.
- Background detach and foreground resume, polished. iOS background socket termination is the
  classic source of leaked sessions and phantom disconnects.
- Ping/pong keepalive with dead-peer detection on both sides.
- Reconnect with exponential backoff on transport failure.
- Honest measurement of how often replay artifacts actually show up.

**Snippets.** Saved commands, tap to insert. Cheap to build and disproportionately useful when the
keyboard is a phone.

**Onboarding.** A flow that takes someone from installing the app to a first working shell,
including getting `landlined` running on their own machine. The app is useless without a daemon
somewhere, and that has to be obvious before install, not after.

**App Store release.** Listing, screenshots, privacy labels, export compliance. A Debian package
alongside the existing Homebrew formula and install script.

## Under consideration, not committed

Designed or thought through, but not scheduled. Listed so nobody has to guess whether they were
overlooked.

- **Hardened mode without serve.** Bind the daemon to the machine's tailnet address and identify
  peers through the tailscaled LocalAPI WhoIs endpoint, removing both the loopback listener and any
  trust in headers. Fully specified in `docs/SCOPE.md` section 4.3. It matters on multi-user hosts;
  nothing in the protocol or the client depends on which of the two designs is in front.
- **Screen state model for replay.** Replaying a raw byte ring into a fresh terminal can start
  mid escape sequence and render garbage. The correct fix is what tmux and mosh do: model screen
  state on the server and synchronize state instead of bytes. That is real work, and the byte ring
  is not equivalent to it.
- **Multiple clients attached to one session.** Today a second attach evicts the first with
  `SESSION_REPLACED`. tmux-style multi-attach invites echo and resize conflicts that are not worth
  it yet.

## Not planned, permanently

These are closed, not deferred. Please do not open issues asking for them.

- **Screen sharing or remote desktop.** Terminal only, forever. If you need a desktop, use Screen
  Sharing or RustDesk.
- **File manager, SFTP browser, or port forwarding UI.**
- **Android, web client, or desktop client.** iOS only.
- **A hosted service, accounts, or any backend.** There is no server to trust because there is no
  server.
- **Team or multi-user features.** One person, N machines.

## How to help

Bug reports from real use are worth more than feature requests. See
[CONTRIBUTING.md](../CONTRIBUTING.md) for how to build, test, and send changes, and
[SECURITY.md](../SECURITY.md) for anything exploitable, which should go through a private advisory
rather than an issue.
