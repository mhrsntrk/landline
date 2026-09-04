# Privacy Policy

**Landline**, last updated 4 September 2026.

Landline collects nothing. There is no account, no analytics, no telemetry, no
crash reporting, no advertising identifier, and no server operated by the
developer. Nothing you do in the app is transmitted to us, because there is
nowhere for it to go.

## What the app stores, and where

Everything stays on your device.

| Data | Where it lives | Leaves the device? |
|---|---|---|
| Host names, tailnet hostnames, ports | A file in the app's private container | Only to the machine you connect to |
| Terminal palette, font, size, key bar layout | Same | No |
| Per-host unlock secret | The iOS Keychain | Only to the daemon that asks for it, over TLS |
| Session identifiers | Same file, so a session can be resumed | Only to the machine you connect to |

Deleting the app deletes all of it. There is no backup on our side to delete,
because we never received a copy.

## What travels over the network

The app connects directly to daemons **you** run on machines **you** own, over
your own Tailscale network. Traffic is end to end between your device and your
machine: it is encrypted by WireGuard inside your tailnet, and again by TLS
terminated on your own machine by `tailscale serve`.

The developer runs no relay, no proxy and no backend. We cannot see your
terminal sessions, your commands, your output, your hostnames, or the fact that
you connected at all.

Your use of Tailscale is governed by Tailscale's own privacy policy, and your
use of the machines you connect to is governed by whatever you have configured
there. Neither is under the developer's control.

## Face ID

If you turn on the Face ID gate for a host, authentication is performed by iOS.
The app is told only whether it succeeded. No biometric data is ever available
to, or stored by, the app.

## Children

Landline is a developer tool with no user generated content, no social features,
no advertising and no data collection. It is not directed at children.

## Changes

If this policy ever changes, the revision will appear in this file's history in
the public repository, so the change is visible rather than announced.

## Contact

Open an issue at <https://github.com/mhrsntrk/landline/issues>, or write to
`m@mhrsntrk.com`.
