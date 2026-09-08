# The HTTP endpoints, version 1

Normative. Code disagreeing with this file is wrong.

Everything the daemon serves that is not the shell. All of it sits on the same
listener as `GET /v1/shell`, behind the same `tailscale serve` mapping, and
behind the same login allowlist and unlock secret.

| Endpoint | What it is for |
|---|---|
| `POST /v1/token` | Turn the unlock secret into a short-lived bearer token |
| `PUT /v1/files/{name}` | The inbox: a file from the phone onto the host |
| `GET /v1/sessions` | What is running here |
| `DELETE /v1/sessions/{id}` | Kill one session |
| `GET /v1/outbox` | Files the host has offered to the phone |
| `GET /v1/outbox/{id}` | Fetch one |
| `DELETE /v1/outbox/{id}` | Withdraw one |

They are deliberately **not** part of the WebSocket protocol. Version 1 of that
protocol is frozen and caps a frame at 1 MiB, and multiplexing a photo onto the
socket carrying the terminal would stall typing behind it for as long as the
upload took.

## What this is not

A file manager, an SFTP browser, and a sync tool are permanent non-goals
(`docs/SCOPE.md`). Nothing here lists a directory, and no request anywhere names
a path. The inbox takes bytes and answers with the path it chose. The outbox
serves files by an id that a **local** process created by running
`landlined send`, which is the only way a path ever enters it. That is the
entire surface, and it is meant to stay that way.

## Endpoints

Every endpoint requires the tailnet login on `Tailscale-User-Login`, verified
against `allowed_logins` exactly as the WebSocket upgrade verifies it. Every
endpoint but `POST /v1/token` additionally requires a bearer token minted by it.

`/v1/files` answers `404` with `{"error":"uploads_disabled"}` when
`uploads_enabled` is off or the inbox directory could not be prepared at
startup. The token endpoint stays available either way, because a token is
spent on sessions and the outbox too.

### `POST /v1/token`

Body: the unlock secret, verbatim, UTF-8, at most 1024 bytes. Empty on a host
with no unlock configured.

```json
{
  "token": "…64 hex chars…",
  "expires_in": 600,
  "max_bytes": 26214400,
  "features": ["sessions", "outbox", "files"]
}
```

`features` names what this daemon serves, so a client can hide what is not there
rather than discovering it by 404. It is additive: a client ignores a name it
does not know, and an older daemon omits the field entirely.

| Status | Meaning |
|---|---|
| 200 | Token minted, valid for `expires_in` seconds |
| 401 | Wrong secret. Body carries `attempts_left` |
| 403 | This login is not in `allowed_logins` |
| 404 | Uploads are not served here |
| 429 | The unlock failure budget is spent |

The secret is checked by the same `UnlockGate` the shell handshake uses, so
wrong guesses here serve the same backoff and spend the same budget, and
exhausting it locks the shell out too. That is intended: there is one secret,
and it has one budget.

Tokens live in the daemon's memory and nowhere else. A restart invalidates every
one of them, and there is nothing on disk to leak.

### `PUT /v1/files/{name}`

Headers: `Authorization: Bearer <token>`, plus the login. Body: the file.

```json
{ "path": "/Users/you/.landline/inbox/img_4821-3f9c2a41.png", "bytes": 184320 }
```

| Status | Meaning |
|---|---|
| 201 | Written. `path` is absolute on the host |
| 401 | Missing, expired, or unknown token, or one minted for another login |
| 403 | This login is not in `allowed_logins` |
| 404 | Uploads are not served here |
| 413 | Larger than `upload_max_bytes` |
| 500 | The inbox could not be written to |

`{name}` is a **suggestion**, not a destination. What is created is derived from
it: only the last path component is considered, the character set is reduced to
`[a-z0-9._-]`, leading dots are stripped, the stem is capped at 48 characters,
and a random suffix is appended before the extension. So `../../etc/passwd`
becomes `passwd-1a2b3c4d` inside the inbox, a name can never be created hidden,
and no upload can overwrite a file that is already there.

The body is streamed and counted as it arrives, so a lying or absent
`Content-Length` cannot get more than `upload_max_bytes` onto the disk. It is
written under a temporary `.name.part` and renamed on success, so a dropped
connection leaves something the reaper collects rather than a truncated file
that looks finished to whatever is about to read it.

### `GET /v1/sessions`

```json
[ { "id": "…uuid…", "shell": "/bin/zsh", "created_at": 1757000000,
    "attached": false, "idle_secs": 1428 } ]
```

Newest first. The daemon has always known this; until now only a local process
could ask, over the admin socket, which is exactly the machine you are not
sitting at when it matters.

### `DELETE /v1/sessions/{id}`

`204` on success, `404` for an id that is not running. Killing is the honest
verb: the child process is terminated and whatever was in it dies with it,
exactly as `landlined sessions kill` does.

### `GET /v1/outbox`, `GET /v1/outbox/{id}`, `DELETE /v1/outbox/{id}`

```json
[ { "id": "…16 hex chars…", "name": "report.pdf", "bytes": 18432,
    "offered_at": 1757000000 } ]
```

An offer is created only by `landlined send <path>` on the host, which reaches
the daemon over the owner-only admin socket. The registry holds the path rather
than a copy, so offering is instant and a file that changes on disk is served as
it now is; the cost is that an offer can go stale, which the fetch reports as a
plain `404` rather than pretending.

`GET /v1/outbox/{id}` answers with the bytes and a `Content-Disposition` naming
the file. `DELETE` withdraws the offer and **never touches the host's file**: the
phone saying "I have this now" is not the phone saying "delete your copy".

Offers older than `upload_ttl_hours` are dropped, and at most 64 are kept. An
outbox is a hand-off, not a folder.

## Configuration

```toml
uploads_enabled  = true        # serve the two endpoints at all
upload_dir       = ""          # empty resolves to ~/.landline/inbox
upload_max_bytes = 26214400    # 25 MiB
upload_ttl_hours = 72          # 0 keeps files forever
```

The directory is created 0700 and each file 0600. Files older than
`upload_ttl_hours` are deleted by an hourly sweep, which also drops stale outbox
offers. `landlined doctor` reports the resolved directory and whether it can be
written to.

Sessions and the outbox have no configuration. There is nothing to size and
nothing to place, and both are strictly less than the shell the same credentials
already grant.

`uploads_enabled` defaults to **on**, which is the only default in this daemon
that is not fail-closed, and the reason is that it grants nothing new. Reaching
either endpoint requires the tailnet login and the unlock secret, and anyone
holding both already has an interactive shell on the machine, which can write
any file anywhere. Turning it off is for hosts that want the endpoint gone, not
for hosts worried about who can reach it.

## What the app does with the path

It types it, wrapped in bracketed paste (`ESC [ 200 ~` … `ESC [ 201 ~`) when the
far end has asked for that mode, followed by one space. Nothing is executed and
nothing is guessed about what is running: the path arrives at whatever prompt is
there, whether that is a shell, an editor, or an agent, and the person decides.

Control bytes are stripped rather than escaped. The naming rules above mean a
path cannot contain one, so a path that did would be a bug or an attack, and
neither is worth typing into a live prompt.
