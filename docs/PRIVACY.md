# Privacy Policy

**Landline**, last updated 27 November 2026.

Landline collects nothing. There is no account, no analytics, no telemetry, no
crash reporting, no advertising identifier, and no server operated by the
developer. Nothing you do in the app is transmitted to us, because there is
nowhere for it to go.

This policy covers the iOS app and the `landlined` daemon you install on your
own machines.

## What the app stores, and where

Your hosts, terminal settings and content stay on your devices. Apple handles
App Store purchases separately, as described below.

| Data | Where it lives | Leaves the device? |
|---|---|---|
| Host names, tailnet hostnames, ports, TLS and Face ID settings | A file in the app's Documents folder | Only to the machine you connect to |
| Terminal palette, font, size, key bar layout | Same | No |
| Per-host unlock secret | The iOS Keychain, this device only | Only to the daemon that asks for it |
| Session identifiers | Same file as your hosts, so a session can be resumed | Only to the machine you connect to |
| Photos or files you attach | Not stored by the app | Only to the machine you chose, when you pick one |
| Snippets you save | A file in the app's Documents folder | Only to the machine you type them into |
| Files a machine sends you | A temporary file, deleted by the app after 24 hours | Never leaves the device |
| Small preferences: rating prompt state, trial reminder choice, which hosts need no unlock secret | The app's settings on the device | No |

The Documents folder is private to the app, but iOS includes it in your own
iCloud or Finder backup of the device. Those backups are yours and Apple's to
manage; the developer never receives them. The unlock secret is stored with
the Keychain's "this device only" setting, so it is not included in backups
and does not sync to your other devices.

Deleting the app removes its local files. Keychain entries may persist under
iOS's Keychain rules. There is no backup on our side to delete, because we never
received a copy. Purchase history remains associated with your Apple Account.

## Trial and purchases

The app uses Apple's StoreKit to load localized prices, start the free trial,
purchase the one-time unlock, and restore purchases. StoreKit contacts Apple;
payment information is handled by Apple and is never available to the developer.
The app checks Apple's signed purchase history locally to determine access,
including continued access for existing customers. It sends no terminal content,
host configuration, snippets, or unlock secrets with purchase requests.

## Notifications and the rating prompt

If you allow notifications, the app schedules reminders before your free trial
ends. They are scheduled on the device by iOS. There is no push server and
nothing is sent to the developer.

After a few sessions the app may ask iOS to show Apple's standard rating prompt.
Whether it appears, and what you choose, is handled by Apple. The app only keeps
a local note that it has asked.

## Shortcuts and Siri

The names of your hosts are offered to the Shortcuts app and Siri so you can
open a machine by name. This happens on the device through Apple's App Intents
system. The developer receives nothing.

## What travels over the network

The app connects directly to daemons **you** run on machines **you** own, over
your own Tailscale network. Traffic is end to end between your device and your
machine and is always encrypted by WireGuard inside your tailnet.

Each host also has a TLS setting, which is on by default. With it on, the
connection is encrypted a second time by TLS, terminated on your own machine by
`tailscale serve`. If you turn TLS off for a host, for example for a daemon
without `tailscale serve` in front of it, terminal traffic, file transfers and
the unlock secret for that host are protected by Tailscale's WireGuard
encryption only.

The developer runs no relay, no proxy and no backend. We cannot see your
terminal sessions, your commands, your output, your hostnames, or the fact that
you connected at all.

Your use of Tailscale is governed by Tailscale's own privacy policy, and your
use of the machines you connect to is governed by whatever you have configured
there. Neither is under the developer's control.

## The daemon on your machine

`landlined` runs on your own computer and makes no connections to the developer.
It has no update check and no telemetry. With the default configuration:

- It listens only on `127.0.0.1:7777`. It is reachable from your tailnet only
  through `tailscale serve`, and only for the Tailscale logins you allow.
- Terminal scrollback is kept in memory, not on disk. A session with no phone
  attached ends after 24 hours (`session_ttl_hours`).
- Files you send from the phone are saved in `~/.landline/inbox` and deleted
  after 72 hours (`upload_ttl_hours`). Files you offer to the phone are
  withdrawn on the same schedule.
- If you set an unlock secret, the daemon stores only an Argon2id hash of it in
  its config file.
- Its log records your Tailscale login when you connect, upload paths and sizes,
  and session identifiers. It never records what you type or what the terminal
  shows. On macOS the log is written to `~/Library/Logs/landline/`.

All of these settings are in the daemon's config file on your machine, under
your control.

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
