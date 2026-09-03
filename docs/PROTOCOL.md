# Landline wire protocol, version 1

Normative. Code disagreeing with this file is wrong.

One WebSocket at `GET /v1/shell`, binary messages only. Text messages are a protocol error;
close with code 1002. Every WebSocket message contains exactly one frame.

## Frame encoding

```
[u8 type][u32 payload_length, big-endian][payload bytes]
```

Max payload 1 MiB (1_048_576). Oversized, truncated, or unknown-type frames are protocol
errors; the receiver closes the connection (server: WS close 1002).

## Client → server

| Type | Name   | Payload |
|------|--------|---------|
| 0x01 | STDIN  | raw bytes for the PTY |
| 0x02 | RESIZE | `[u16 cols BE][u16 rows BE]` (payload length exactly 4) |
| 0x03 | ATTACH | JSON, below |
| 0x04 | PING   | exactly 8 opaque bytes |
| 0x05 | UNLOCK | UTF-8 secret |
| 0x06 | DETACH | empty |
| 0x07 | KILL   | empty |

ATTACH payload:
```json
{
  "proto_version": 1,
  "session_id": "uuid, omit to create a new session",
  "cmd": "optional startup command, see below",
  "cwd": "optional working directory",
  "cols": 80,
  "rows": 24
}
```

What runs in the PTY is resolved highest priority first: `cmd` from this payload, then
the daemon's `default_cmd` config key, then the shell. A blank value counts as absent at
each step.

A command from either source is not executed directly, it is handed to the resolved shell
in interactive mode: `<shell> -i -c "<cmd>"` on Unix. Interactive mode is what sources the
rc files, so aliases, shell functions, and rc-file `PATH` entries resolve exactly as they
do in a terminal (`"cmd": "tmuxon"` works when `tmuxon` is a shell alias; without `-i` it
would fail with "command not found"). On Windows, PowerShell has no `-i`, so pwsh and
powershell get `-NoExit -Command "<cmd>"` and cmd.exe gets `/K "<cmd>"`, both of which run
the command and leave the user at a prompt.

With no command from either source the shell itself is spawned, as a login shell (`-l`) on
Unix so the session's environment matches a normal terminal login. The `shell` field of
ATTACHED reports the program that was spawned.

## Server → client

| Type | Name        | Payload |
|------|-------------|---------|
| 0x81 | STDOUT      | raw PTY output |
| 0x82 | ATTACHED    | JSON, below |
| 0x83 | EXIT        | `[u32 exit_code BE]` |
| 0x84 | PONG        | echo of PING payload |
| 0x85 | ERR         | JSON `{"code": "...", "message": "..."}` |
| 0x86 | NEED_UNLOCK | JSON `{"attempts_left": n}` |

ATTACHED payload:
```json
{
  "session_id": "uuid",
  "cols": 120, "rows": 40,
  "replay_bytes": 4096,
  "shell": "/bin/zsh",
  "host": "macbook",
  "created_at": 1756900000
}
```

Error codes: `SESSION_GONE`, `SESSION_REPLACED`, `UNAUTHORIZED`, `LOCKED_OUT`,
`TOO_MANY_SESSIONS`, `SPAWN_FAILED`, `PROTOCOL_VERSION`, `CLIENT_TOO_SLOW`.
For `PROTOCOL_VERSION`, `message` lists supported versions, e.g. `"supported: 1"`.

## Handshake

1. Client connects and MUST send ATTACH within 10 seconds, before any other frame.
   Any other first frame, or timeout: server closes.
2. Server checks `proto_version`; unknown → ERR PROTOCOL_VERSION, close.
3. If an unlock secret is configured: server sends NEED_UNLOCK; client sends UNLOCK;
   wrong secret → NEED_UNLOCK with decremented `attempts_left` after a backoff delay;
   `attempts_left` 0 → ERR LOCKED_OUT, close. Unlock is per connection: a new
   connection always re-unlocks, even when resuming an existing session.
4. Server resolves the session: new (no `session_id`), resume (known id), or
   ERR SESSION_GONE (unknown id, close). Resume resizes the PTY to the ATTACH
   cols/rows. A concurrent attached client receives ERR SESSION_REPLACED and is dropped.
5. Server sends ATTACHED, then `\x1b[2J\x1b[H` as STDOUT, then the scrollback ring
   as one or more STDOUT frames, then live output.
6. Any transport drop is an implicit DETACH. Explicit DETACH is a courtesy.
   KILL terminates the child process; the server then sends EXIT and closes.
7. When the child exits on its own, server sends EXIT and closes; the session is gone.

## Transport notes

- The daemon sets WebSocket max message size to 1 MiB + 5 bytes.
- PING may be sent by either side at any time after ATTACHED; peer echoes PONG.
- Identity (which tailnet user) arrives out-of-band via `Tailscale-User-Login` on the
  upgrade request, verified before the upgrade completes. 403 without upgrade otherwise.
