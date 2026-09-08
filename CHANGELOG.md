# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Sessions over HTTP: `GET /v1/sessions` and `DELETE /v1/sessions/{id}`, and a session list per
  host in the app with resume and kill. The daemon has always known what is running; only a process
  on the host could ask.
- The outbox: `landlined send <path>` offers a file to the phone, and the app shows a band and
  opens it. Offers are registered by a local process and fetched by id, so no request ever names a
  path.
- Snippets: saved text, tap to type, reached from a `SNIP` key in the bar. Pasted as one paste, and
  never run unless the snippet says to.
- Setup on the empty index now starts at `brew install`, with a copy button on every command.
- Every key in the bar can choose its own face: a label of up to four characters, or one of thirty
  Nerd Font icons drawn in the bundled terminal face. Catalog keys are editable too, where before
  only a custom key opened anything.

### Changed

- Dead connections are detected and reconnected. PONG was received and discarded, so a half-open
  socket, which is what a phone gets crossing between cellular and wifi, read as LIVE forever. Two
  missed pings now drop the socket and reattach with exponential backoff.
- A host that is not answering says which of the four things went wrong (name, port, TLS, login)
  rather than only showing an offline square.
- Reordering the key bar is a long-press drag and nothing else. The per-row up and down buttons are
  gone, and the annotation under the title says the row can be held.
- The attach key's drawn page mark is retired in favour of the icon mechanism every key now shares.

## [0.2.0] - 2026-09-08

### Added

- File inbox: `POST /v1/token` and `PUT /v1/files/{name}` on the daemon, and an attach key in the
  app's key bar that picks a photo or a file, uploads it, and types the path it landed at into the
  session. It exists because a phone cannot otherwise hand a file to whatever is running in the
  terminal. Normative spec in `docs/HTTP.md`.
- Config keys `uploads_enabled` (default on), `upload_dir` (default `~/.landline/inbox`),
  `upload_max_bytes` (25 MiB) and `upload_ttl_hours` (72).
- `landlined doctor` gains a ninth check: where the inbox lands, and whether it is writable.

### Changed

- The default key bar row carries the attach key, third. A stored layout is not migrated, so an
  existing install adds it from Settings.

## [0.1.0] - 2026-09-04

### Added

- Wire protocol v1: a single binary WebSocket protocol for PTY sessions, documented in
  `docs/PROTOCOL.md`.
- `landlined`, the host daemon: PTY sessions over WebSocket, bound to loopback.
- Session resume with scrollback replay, so a dropped connection does not kill the shell.
- Tailnet identity authentication via `tailscale serve` header injection and an allowlist of
  logins.
- Optional per-host unlock secret, argon2id hashed, with exponential backoff on repeated
  failures.
- Admin unix socket and `landlined sessions` for listing and killing sessions from the CLI.
- File inbox: `POST /v1/token` and `PUT /v1/files/{name}` on the daemon, and a `FILE` key in the
  app's key bar that picks a photo or a file, uploads it, and types the path it landed at into the
  session. Documented in `docs/HTTP.md`.
- `landlined doctor`, diagnosing tailscaled, MagicDNS, serve mapping, listener health, and the
  file inbox.
- Service installation for macOS (launchd), Linux (systemd), and Windows (scheduled task at
  logon).
- `landline-cli`, a terminal test client for connecting to the daemon without the iOS app.
- iOS app scaffold: SwiftUI, SwiftTerm-based terminal view, host list.
- Packaging (Homebrew tap, `.deb`) and CI across macOS, Linux, and Windows.

[Unreleased]: https://github.com/mhrsntrk/landline/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/mhrsntrk/landline/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mhrsntrk/landline/releases/tag/v0.1.0
