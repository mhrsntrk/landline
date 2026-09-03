# landline

A fixed, private, direct line to every machine you own. Terminal on your iPhone,
over your own tailnet. No open ports, no SSH keys, no accounts, no server.

## Quickstart (host)

```sh
brew install mhrsntrk/tap/landline     # or: curl -fsSL .../install.sh | sh
landlined install                       # launchd / systemd / scheduled task
tailscale serve --bg --https=443 http://127.0.0.1:7777
```

Then add the machine's `ts.net` hostname in the iOS app.

Security model, protocol, and design: see `docs/SCOPE.md`. Note: any local
process on a host can reach the daemon on loopback; the per-host unlock secret
is the second factor. Details in SCOPE §4.3.

MIT. The paid App Store build is a tip jar; build it yourself if you prefer.
