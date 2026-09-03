# Security policy

Landline gives a phone a real shell on your machines. That makes the daemon a high value target
by definition, so this document is written to be accurate rather than reassuring.

## Reporting a vulnerability

Use GitHub private security advisories:

**https://github.com/mhrsntrk/landline/security/advisories/new**

That is the primary channel. Please do not open a public issue for anything exploitable. Public
issues are fine for hardening suggestions, documentation gaps, and questions about the model below.

What to expect, stated plainly: this is a solo, spare-time project. There is no bug bounty, no
payout, and no guaranteed response time. Reports are read and answered on a best-effort basis,
usually within a couple of weeks. If a report is valid, the fix and the advisory are published
together, and you get credit in the advisory unless you ask otherwise.

Useful things to include: the version or commit, the host platform, whether `tailscale serve` was
in front of the daemon, and the smallest reproduction you have.

## Supported versions

Only the latest release gets fixes. There are no backports and no long-term support branches.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Anything older | No |

## Security model

Nothing here is invented cryptography. Landline stacks existing boundaries and adds one gate of
its own. The layers, outermost first:

**1. Tailnet membership.** The daemon has no public listener and no port to forward. Everything
reaches it over WireGuard through Tailscale, so an attacker has to already be a node on your
tailnet before any of the following even applies. Tailscale's threat model is inherited wholesale.

**2. Tailnet ACLs.** Membership is not authorization. Grants can narrow which nodes may reach
port 443 on which hosts, so a compromised node that is not your phone has no path to the daemon.
See the hardening checklist for a concrete policy.

**3. Loopback bind.** `landlined` binds `127.0.0.1:7777` by default and never `0.0.0.0`. A machine
on the same LAN, coffee shop Wi-Fi, or datacenter subnet cannot reach the port at all. Traffic
arrives only through `tailscale serve`, which terminates TLS with a real Let's Encrypt certificate
for the `*.ts.net` name.

**4. Identity allowlisting.** When proxying to a plaintext backend, `tailscale serve` injects
`Tailscale-User-Login` (along with `Tailscale-User-Name` and `Tailscale-User-ProfilePic`)
identifying the calling tailnet user. The daemon checks that login against `allowed_logins` and
answers HTTP 403 **before** the WebSocket upgrade completes. An empty `allowed_logins` rejects
everyone: the daemon fails closed until you configure it.

Serve strips any client-supplied `Tailscale-*` headers before injecting its own, so a tailnet peer
cannot forge an identity by setting the header itself. Tailscale documents this, and it was also
verified empirically on tailscale 1.102.3 against this daemon's design: a request sent through
serve with a forged `Tailscale-User-Login` arrived at the backend with the forged value gone and
the real identity in its place.

**5. Unlock secret.** Identity proves which tailnet user is calling. It does not prove the phone is
in your hands. So each host may carry an optional unlock secret, argon2id hashed into the config
file and never stored on the host in plaintext. It is verified in-band during the protocol
handshake, **before any PTY is spawned**, and it is per connection, not per session: resuming an
existing session over a new connection requires unlocking again, so a stolen session id on its own
is worth nothing. Wrong secrets serve an exponential backoff (`min(2^failures * 500ms, 60s)`), and
after 10 failures the daemon refuses every further unlock attempt until it is restarted.

The iOS app also gates on Face ID or the device passcode when it comes to the foreground. That is
a client-side convenience, not a boundary. The unlock secret is the real gate.

## Known limitations

These are real, they are not theoretical, and none of them are hidden further down.

**Any local process on the host can reach the daemon.** The listener is loopback TCP, which means
any process running as any user on that machine can connect to `127.0.0.1:7777` directly, skip
`tailscale serve` entirely, and supply its own `Tailscale-User-Login` header with any value in the
allowlist. `tailscale serve` has no unix socket backend, so filesystem permissions cannot be used
as the boundary here.

On a single-user laptop where you are already the only account, this is close to irrelevant:
anything running as you can spawn a shell without going through Landline. On a shared or
multi-user machine it is not irrelevant at all, and it means the local-process boundary does not
hold. **The per-host unlock secret is the mitigation**, because a local process that does not know
the secret still cannot get a PTY.

The hardened alternative is designed and documented but not built: bind the daemon to the
machine's tailnet `100.x` address and identify each peer through the tailscaled LocalAPI WhoIs
endpoint, with no loopback listener and no header trust at all. See `docs/SCOPE.md` section 4.3.
If you run `landlined` on a genuinely multi-user machine, know that today's shipping design is
the loopback one.

**The `harness` cargo feature bypasses authentication.** It exists so the browser test page can
connect without Tailscale in front, and it treats a missing identity header as an implicit
`dev@local` login that is always allowed. It is dev-only and now refuses to compile in an
optimized build (`compile_error!` on `not(debug_assertions)`), so it cannot ride into a release
binary by accident. Do not remove that guard, and do not run a harness build anywhere reachable.

**Scrollback lives in daemon memory.** Each session keeps a ring buffer, 256 KiB by default
(`scrollback_bytes`), so a reattaching client can replay recent output. It holds whatever crossed
that terminal, which includes secrets you echoed, tokens a command printed, and anything in a
here-doc. It is replayed to whoever successfully attaches to that session id, and it is present in
the daemon's memory (and therefore in any core dump of it) until the session is reaped.

**Unlock lockout is daemon-wide and needs a restart.** The failure counter is global, not per
connection and not per login, and the lockout persists until `landlined` is restarted. That is
deliberate for brute-force resistance, but it also means a caller who can reach the unlock stage
can lock you out of your own host until you restart the daemon.

**The unlock secret is stored in the iOS Keychain.** The app keeps one generic-password item per
host so you do not retype the secret on every reconnect. It is protected by Keychain, which means
it is as safe as the device and its passcode, and no safer. An unlocked, attacker-held phone has
the secret.

**Config file permissions are enforced on Unix only.** `landlined set-unlock` writes the config
with mode 0600 on macOS and Linux. On Windows the file inherits whatever ACL its directory has,
so check it yourself if the machine has other accounts on it.

**The admin socket is owner-only.** On Unix the daemon listens on `admin.sock` next to the config
file, mode 0700, with no authentication of its own. Anything running as your user can list and
kill sessions through it. It cannot spawn a session or read output.

**Replay artifacts are not a security property.** The clear-screen sequence sent before a replay is
cosmetic. Do not read it as scrubbing anything.

## Hardening checklist

For anyone running `landlined` on a machine that matters:

1. **Set an unlock secret on every host that is not single-user.**
   ```sh
   landlined set-unlock
   ```
   On a shared box, treat this as mandatory rather than optional. It is the only thing standing
   between a local process and a PTY.

2. **Keep `allowed_logins` to exactly the logins you actually use.** One entry is the normal case.
   Never leave it broad "just for now"; an empty list fails closed, a wide list fails open.
   ```toml
   allowed_logins = ["you@example.com"]
   ```

3. **Restrict reachability with tailnet ACL grants,** so only the tagged phone can reach the tagged
   hosts, on one port:
   ```jsonc
   {
     "tagOwners": {
       "tag:phone":        ["autogroup:admin"],
       "tag:landlinehost": ["autogroup:admin"]
     },
     "grants": [
       { "src": ["tag:phone"], "dst": ["tag:landlinehost"], "ip": ["tcp:443"] }
     ]
   }
   ```
   Tag the phone `tag:phone` and each Landline host `tag:landlinehost`. Without this, every node on
   your tailnet can at least reach the port and get as far as the identity check.

4. **Keep tailscaled updated.** Serve's header handling is load-bearing for the identity layer, and
   it is not code that lives in this repo.

5. **Run `landlined doctor` after any change** to the config, to serve, or to your tailnet policy.
   It checks the tailscale binary, the backend state, MagicDNS, the serve mapping, the daemon's
   listener, the admin socket, whether anyone is actually allowed in, and the URL to enter in the
   app. Serve configuration is per-machine state that drifts, and "why can I not reach the laptop"
   should have a one-command answer.

6. **Lower `session_ttl_hours` and `scrollback_bytes`** if detached sessions holding terminal output
   in memory for a day is more than you want on that machine.

## Out of scope

Not defended against, deliberately:

- **A compromised Tailscale coordination server.** Landline sits on top of Tailscale's trust model
  and does not attempt to second-guess it.
- **A stolen phone that is unlocked and in someone else's hands.** The Keychain holds the unlock
  secret, and the Face ID gate is client-side. If the device is unlocked, the attacker has the app.
- **Physical or root access to a host.** Anyone with root on the machine already has a shell and
  does not need this app to get one. Nothing here is designed to hold against the host's own
  administrator.
