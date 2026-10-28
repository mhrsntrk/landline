# Privacy Policy

**Landline**, last updated 17 September 2026.

Landline collects nothing. There is no account, no analytics, no telemetry, no
crash reporting, no advertising identifier, and no server operated by the
developer. Nothing you do in the app is transmitted to us, because there is
nowhere for it to go.

## What the app stores, and where

Your hosts, terminal settings and content stay on your devices. Apple handles
App Store purchases separately, as described below.

| Data | Where it lives | Leaves the device? |
|---|---|---|
| Host names, tailnet hostnames, ports | A file in the app's private container | Only to the machine you connect to |
| Terminal palette, font, size, key bar layout | Same | No |
| Per-host unlock secret | The iOS Keychain | Only to the daemon that asks for it, over TLS |
| Session identifiers | Same file, so a session can be resumed | Only to the machine you connect to |
| Photos or files you attach | Not stored by the app | Only to the machine you chose, when you pick one |
| Snippets you save | A file in the app's private container | Only to the machine you type them into |
| Files a machine sends you | A temporary file, cleared by iOS | Never leaves the device |

Deleting the app removes its local files. Keychain entries may persist under
iOS's Keychain rules. There is no backup on our side to delete, because we never
received a copy. Purchase history remains associated with your Apple Account.

## Trial and purchases

Version 1.1 uses Apple's StoreKit to load localized prices, start the free trial,
purchase the one-time unlock, and restore purchases. StoreKit contacts Apple;
payment information is handled by Apple and is never available to the developer.
The app checks Apple's signed purchase history locally to determine access,
including continued access for existing customers. It sends no terminal content,
host configuration, snippets, or unlock secrets with purchase requests.

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

## Photos and files

The app can send a photo or a file to a machine you connect to, so that whatever
you are running there can open it. Nothing is sent unless you pick it, and it
goes only to the machine whose session you are looking at, over the same
connection as everything else. The app keeps no copy.

Choosing a photo uses the system picker, which hands over the one image you
chose and nothing else. The app is never granted access to your photo library.

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
