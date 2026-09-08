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
- `landlined doctor`, nine checks covering the tailscale binary, backend state, MagicDNS, the
  serve mapping, the daemon's own listener, the admin socket, whether any login is allowed in,
  where the file inbox lands and whether it is writable, and the URL to type into the app. Serve config is per-machine state that drifts, so "why can I not
  reach that host" needed a one-command answer.
- `landlined install` / `uninstall`, writing a launchd plist on macOS, a systemd unit on Linux, and
  a scheduled task at logon on Windows (a session-0 service cannot host ConPTY sanely).

**The file inbox.** A phone cannot hand a file to a terminal, so `POST /v1/token` and
`PUT /v1/files/{name}` put one in a directory on the host and answer with the absolute path it
landed at, which the app types into the running session. Same listener, same serve mapping, same
login allowlist and unlock secret as the shell. Streamed and capped, name and destination chosen by
the daemon rather than the caller, never overwriting, swept after a TTL. Specified in
`docs/HTTP.md`. In the app it is one key in the bar, `FILE`, and the picker behind it.

Not a step towards a file browser: there is no read endpoint and no listing, and there will not be
one.

**Sessions, snippets, and files both ways.** `GET /v1/sessions` and `DELETE /v1/sessions/{id}`
put the session list on the phone, with resume and kill. `landlined send <path>` offers a file the
other way, fetched by id so no request ever names a path. Snippets are saved text the key bar can
type, because the phone keyboard is the bottleneck this app cannot fix. All specified in
`docs/HTTP.md`.

**Keepalive that means something.** PONG used to be received and discarded, so a half-open socket
read as LIVE indefinitely. Two missed pings now drop it and reattach with backoff, and because the
session lives on the daemon that is a resume rather than a new shell.

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

**Resilience.** What is left of it:

- Background detach and foreground resume, polished. iOS background socket termination is the
  classic source of leaked sessions and phantom disconnects.
- Dead-peer detection on the *daemon* side. The app now notices a peer that stopped answering; the
  daemon still waits for the reaper.
- Honest measurement of how often replay artifacts actually show up.

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
- **File manager, SFTP browser, or port forwarding UI.** The file inbox above is the whole of what
  this app will ever do with files: one file, one direction, one path handed back. Browsing a
  remote filesystem is not on the way to anything here.
- **Android, web client, or desktop client.** iOS only.
- **A hosted service, accounts, or any backend.** There is no server to trust because there is no
  server.
- **Team or multi-user features.** One person, N machines.

## How to help

Bug reports from real use are worth more than feature requests. See
[CONTRIBUTING.md](../CONTRIBUTING.md) for how to build, test, and send changes, and
[SECURITY.md](../SECURITY.md) for anything exploitable, which should go through a private advisory
rather than an issue.
