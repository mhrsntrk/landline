# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing has been released yet. This section covers the initial build.

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
  session. Documented in `docs/FILES.md`.
- `landlined doctor`, diagnosing tailscaled, MagicDNS, serve mapping, listener health, and the
  file inbox.
- Service installation for macOS (launchd), Linux (systemd), and Windows (scheduled task at
  logon).
- `landline-cli`, a terminal test client for connecting to the daemon without the iOS app.
- iOS app scaffold: SwiftUI, SwiftTerm-based terminal view, host list.
- Packaging (Homebrew tap, `.deb`) and CI across macOS, Linux, and Windows.

[Unreleased]: https://github.com/mhrsntrk/landline/commits/main
