# Landline: product context

## What it is
An iPhone app plus a small Rust daemon (`landlined`) that give you a real terminal on machines
you own, over your own Tailscale tailnet. No hosted service, no account, no open port, no SSH key
management.

## The mechanism, in one sentence
Tailscale already put your machines on one private encrypted network, so the terminal needs no
transport of its own: the daemon binds loopback, `tailscale serve` fronts it with real TLS and a
verified caller identity, and the phone just opens a WebSocket.

## Who uses it, and the real scene
One person, on a phone, away from their desk. On a train, in a queue, on a couch, in bed. Usually
one-handed, usually in a dark room or bright sunlight, usually to do one specific thing: check a
build, restart a service, reattach to tmux, read a log. The session is short and the intent is
precise. This is not a machine you browse; it is a machine you reach.

## Audience
Developers and operators who already run Tailscale and already live in a terminal. They know what
a PTY is, they have opinions about their shell, and they will notice immediately if the colors are
wrong or the keyboard fights them.

## Non-negotiable product truths
- Terminal only, permanently. Screen sharing is a non-goal, not a missing feature.
- Sessions outlive connections. The phone changes networks constantly, so a dropped socket must
  never mean a dropped shell.
- The daemon is the source of truth. The app never invents state.
- Nothing is configured on the phone that could be wrong on the machine.

## Brand commitments (pinned by the owner, not open to redesign)
- **Visual world: micrographics.** Technical-drawing precision at small scale.
- **Terminal palette: One Dark Pro**, the scheme the owner already reads on every machine.
- The app must feel fast and exact. Latency and imprecision are the two ways it loses trust.

## Constraints
- iOS 17+, SwiftUI, SwiftTerm for the emulator.
- MIT licensed, source public. The paid App Store build is a convenience, not a moat.
- Solo spare-time project.

## What success looks like
The owner reaches for this instead of Blink Shell plus Tailscale SSH, because it is one tap from
lock screen to the right tmux session on the right machine.
