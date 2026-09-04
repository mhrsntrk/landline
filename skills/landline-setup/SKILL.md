---
name: landline-setup
description: Install and configure the landlined daemon so the Landline iOS app can reach this machine over Tailscale. Use when someone wants to set up Landline on a Mac, Linux box or Windows machine, when `landlined doctor` reports a failure, or when the app cannot connect to a host.
---

# Setting up a Landline host

Your job is to get one machine reachable from the Landline app and to **prove it**,
not to run four commands and declare success. `landlined doctor` is the proof.

Explain what you are doing as you go. This installs a daemon that hands out a
shell on the user's machine, so they should understand each step rather than
watch commands scroll past.

## Before anything

Check Tailscale is installed and up: `tailscale status`. If it is missing or
logged out, stop and tell the user, because nothing later can work without it.
The app reaches this machine over their tailnet, so their phone must be signed
into the **same** tailnet.

## 1. Install the daemon

```sh
brew install mhrsntrk/tap/landline
```

Or, on any Unix without Homebrew:

```sh
curl -fsSL https://raw.githubusercontent.com/mhrsntrk/landline/main/packaging/install.sh | sh
```

Windows: download `landlined-x86_64-pc-windows-msvc.exe` from the releases page.

**If Homebrew says the Command Line Tools are too outdated**, no bottle matched
this machine's macOS version and architecture, so Homebrew fell back to a source
build. Do not send the user to Xcode. Use `install.sh` instead; it fetches the
same binary and never involves Homebrew.

**Linux binaries need glibc 2.35 or newer** (Ubuntu 22.04 and up). On anything
older, build from source with `cargo build --release -p landlined`.

## 2. Register the service

```sh
landlined install
```

Writes a launchd agent on macOS, a systemd user unit on Linux, or a logon
scheduled task on Windows. On a headless Linux box also run
`loginctl enable-linger $USER`, or the unit will not start until someone logs in.

## 3. Allow the user's tailnet identity

The daemon **fails closed**: an empty `allowed_logins` rejects everyone, which is
the correct default but means the daemon does nothing until you edit it.

Find the config with `landlined config-path`, and set the login to the one
`tailscale status` shows for this user:

```toml
listen         = "127.0.0.1:7777"
allowed_logins = ["them@example.com"]
```

## 4. Put Tailscale in front of it

```sh
tailscale serve --bg --https=443 http://127.0.0.1:7777
```

This terminates TLS with a real certificate and injects the caller's verified
identity. The daemon itself only listens on loopback and is never exposed
directly.

**If this command appears to hang or reports that Serve is not enabled**, the
tailnet admin has to enable Serve once, at the URL the command prints. Only the
user can do that; wait for them rather than working around it.

## 5. Prove it

```sh
landlined doctor
```

Eight checks. Every one must pass. The last line prints the exact
`wss://<machine>.<tailnet>.ts.net/v1/shell` URL, and the hostname in it is what
the user types into the app.

If a check fails, read what it says rather than guessing: it names the missing
piece and, for the serve mapping, the exact command to run.

## 6. Optional, and worth offering

- **An unlock secret**: `landlined set-unlock`. Recommend it on any machine that
  is not single-user. Any local process can reach the loopback port and supply
  its own identity header, so this is the second factor. See `docs/SCOPE.md` 4.3.
- **A startup command**: set `default_cmd` in the config, for example
  `tmux new -A -s main`, so every session opens where they want it. It runs
  through their login shell interactively, so aliases and functions resolve.
- **Tailnet ACLs**, to narrow which devices may reach the host at all:

```jsonc
"grants": [
  { "src": ["tag:phone"], "dst": ["tag:landlinehost"], "ip": ["tcp:443"] }
]
```

## In the app

Add a host with the `ts.net` hostname from `doctor`, port 443, TLS on.

**If they use tmux, set the leader to match their machine.** The app defaults to
tmux's own `C-b`, and a prefix tmux is not listening for is discarded in silence,
so the leader key simply appears dead. Check their `.tmux.conf` for
`set -g prefix` and set the same value on that host.

## Things that look like bugs and are not

- **The first swipe after the keyboard drops scrolls less than later ones.** tmux
  re-anchors its copy-mode view when the terminal resizes.
- **Nerd Font icons render** because the app bundles a patched font. If the user
  picks their own font and icons vanish, their font is not patched; the bundled
  face fills in only the glyphs theirs lacks.
- **Sessions survive** a dropped connection by design. Reopening a host resumes
  the same shell with its scrollback rather than starting a new one.
