# The file inbox, version 1

Normative. Code disagreeing with this file is wrong.

A phone cannot hand a file to a terminal. This is how one gets there: the app
puts the bytes in a directory on the host and the daemon answers with the
absolute path they landed at, which the app then types into the running session.
What happens to that path next is the person's business, not the app's.

Two HTTP endpoints on the daemon's own listener, beside `GET /v1/shell` and
behind the same `tailscale serve` mapping. They are deliberately **not** part of
the WebSocket protocol, for two reasons: version 1 of that protocol is frozen
and caps a frame at 1 MiB, and multiplexing a photo onto the socket carrying the
terminal would stall typing behind it for as long as the upload took.

## What this is not

A file manager, an SFTP browser, and a sync tool are permanent non-goals
(`docs/SCOPE.md`). Nothing here lists a directory, reads a file, or lets a
caller name a destination. One request hands over bytes and gets back one path.
That is the entire surface, and it is meant to stay that way.

## Endpoints

Both require the tailnet login on `Tailscale-User-Login`, verified against
`allowed_logins` exactly as the WebSocket upgrade verifies it. Both answer
`404` with `{"error":"uploads_disabled"}` when `uploads_enabled` is off or the
inbox directory could not be prepared at startup.

### `POST /v1/token`

Body: the unlock secret, verbatim, UTF-8, at most 1024 bytes. Empty on a host
with no unlock configured.

```json
{ "token": "…64 hex chars…", "expires_in": 600, "max_bytes": 26214400 }
```

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

## Configuration

```toml
uploads_enabled  = true        # serve the two endpoints at all
upload_dir       = ""          # empty resolves to ~/.landline/inbox
upload_max_bytes = 26214400    # 25 MiB
upload_ttl_hours = 72          # 0 keeps files forever
```

The directory is created 0700 and each file 0600. Files older than
`upload_ttl_hours` are deleted by an hourly sweep. `landlined doctor` reports the
resolved directory and whether it can be written to.

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
