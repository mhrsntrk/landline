//! Wire frames for the Landline protocol, version 1.
//!
//! Normative reference: `docs/PROTOCOL.md`. Every frame is encoded as
//! `[u8 type][u32 payload_length big-endian][payload bytes]`, one frame per
//! WebSocket message.

use bytes::Bytes;

/// Protocol version carried in `AttachReq::proto_version`.
pub const PROTO_VERSION: u32 = 1;

/// Maximum payload size in bytes (1 MiB).
pub const MAX_PAYLOAD: usize = 1_048_576;

const HEADER_LEN: usize = 5;

// Client -> server frame types.
const T_STDIN: u8 = 0x01;
const T_RESIZE: u8 = 0x02;
const T_ATTACH: u8 = 0x03;
const T_PING: u8 = 0x04;
const T_UNLOCK: u8 = 0x05;
const T_DETACH: u8 = 0x06;
const T_KILL: u8 = 0x07;

// Server -> client frame types.
const T_STDOUT: u8 = 0x81;
const T_ATTACHED: u8 = 0x82;
const T_EXIT: u8 = 0x83;
const T_PONG: u8 = 0x84;
const T_ERR: u8 = 0x85;
const T_NEED_UNLOCK: u8 = 0x86;

/// ATTACH payload sent by the client during the handshake.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct AttachReq {
    pub proto_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cmd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub cols: u16,
    pub rows: u16,
}

/// ATTACHED payload sent by the server after a successful attach.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct AttachedResp {
    pub session_id: String,
    pub cols: u16,
    pub rows: u16,
    pub replay_bytes: u64,
    pub shell: String,
    pub host: String,
    pub created_at: i64,
}

/// Error codes carried by the ERR frame, SCREAMING_SNAKE_CASE on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrCode {
    SessionGone,
    SessionReplaced,
    Unauthorized,
    LockedOut,
    TooManySessions,
    SpawnFailed,
    ProtocolVersion,
    ClientTooSlow,
}

/// Frames sent by the client.
#[derive(Debug, Clone, PartialEq)]
pub enum ClientFrame {
    /// 0x01: raw bytes for the PTY.
    Stdin(Bytes),
    /// 0x02: `[u16 cols BE][u16 rows BE]`, payload exactly 4 bytes.
    Resize { cols: u16, rows: u16 },
    /// 0x03: JSON [`AttachReq`].
    Attach(AttachReq),
    /// 0x04: exactly 8 opaque bytes.
    Ping([u8; 8]),
    /// 0x05: UTF-8 secret.
    Unlock(String),
    /// 0x06: empty payload.
    Detach,
    /// 0x07: empty payload.
    Kill,
}

/// Frames sent by the server.
#[derive(Debug, Clone, PartialEq)]
pub enum ServerFrame {
    /// 0x81: raw PTY output.
    Stdout(Bytes),
    /// 0x82: JSON [`AttachedResp`].
    Attached(AttachedResp),
    /// 0x83: `[u32 exit_code BE]`, payload exactly 4 bytes.
    Exit(u32),
    /// 0x84: echo of the PING payload, exactly 8 bytes.
    Pong([u8; 8]),
    /// 0x85: JSON `{"code": "...", "message": "..."}`.
    Err { code: ErrCode, message: String },
    /// 0x86: JSON `{"attempts_left": n}`.
    NeedUnlock { attempts_left: u32 },
}

/// Decoding errors.
#[derive(Debug, thiserror::Error)]
pub enum ProtoError {
    #[error("frame truncated")]
    Truncated,
    #[error("unknown frame type {0:#x}")]
    UnknownType(u8),
    #[error("payload too large: {0}")]
    TooLarge(usize),
    #[error("payload length mismatch")]
    LengthMismatch,
    #[error("bad payload: {0}")]
    BadPayload(String),
}

#[derive(serde::Serialize, serde::Deserialize)]
struct ErrPayload {
    code: ErrCode,
    message: String,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct NeedUnlockPayload {
    attempts_left: u32,
}

fn encode_frame(frame_type: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.push(frame_type);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// Validates the header and framing, returning `(type, payload)`.
fn split_frame(buf: &[u8]) -> Result<(u8, &[u8]), ProtoError> {
    if buf.len() < HEADER_LEN {
        return Err(ProtoError::Truncated);
    }
    let frame_type = buf[0];
    let declared = u32::from_be_bytes([buf[1], buf[2], buf[3], buf[4]]) as usize;
    if declared > MAX_PAYLOAD {
        return Err(ProtoError::TooLarge(declared));
    }
    let total = HEADER_LEN + declared;
    if buf.len() < total {
        return Err(ProtoError::Truncated);
    }
    if buf.len() > total {
        return Err(ProtoError::LengthMismatch);
    }
    Ok((frame_type, &buf[HEADER_LEN..]))
}

fn expect_len(payload: &[u8], expected: usize) -> Result<(), ProtoError> {
    if payload.len() != expected {
        return Err(ProtoError::LengthMismatch);
    }
    Ok(())
}

fn parse_json<T: serde::de::DeserializeOwned>(payload: &[u8]) -> Result<T, ProtoError> {
    serde_json::from_slice(payload).map_err(|e| ProtoError::BadPayload(e.to_string()))
}

fn to_json<T: serde::Serialize>(value: &T) -> Vec<u8> {
    serde_json::to_vec(value).expect("frame payload serialization cannot fail")
}

impl ClientFrame {
    pub fn encode(&self) -> Vec<u8> {
        match self {
            ClientFrame::Stdin(data) => encode_frame(T_STDIN, data),
            ClientFrame::Resize { cols, rows } => {
                let mut payload = [0u8; 4];
                payload[..2].copy_from_slice(&cols.to_be_bytes());
                payload[2..].copy_from_slice(&rows.to_be_bytes());
                encode_frame(T_RESIZE, &payload)
            }
            ClientFrame::Attach(req) => encode_frame(T_ATTACH, &to_json(req)),
            ClientFrame::Ping(data) => encode_frame(T_PING, data),
            ClientFrame::Unlock(secret) => encode_frame(T_UNLOCK, secret.as_bytes()),
            ClientFrame::Detach => encode_frame(T_DETACH, &[]),
            ClientFrame::Kill => encode_frame(T_KILL, &[]),
        }
    }

    pub fn decode(buf: &[u8]) -> Result<Self, ProtoError> {
        let (frame_type, payload) = split_frame(buf)?;
        match frame_type {
            T_STDIN => Ok(ClientFrame::Stdin(Bytes::copy_from_slice(payload))),
            T_RESIZE => {
                expect_len(payload, 4)?;
                Ok(ClientFrame::Resize {
                    cols: u16::from_be_bytes([payload[0], payload[1]]),
                    rows: u16::from_be_bytes([payload[2], payload[3]]),
                })
            }
            T_ATTACH => Ok(ClientFrame::Attach(parse_json(payload)?)),
            T_PING => {
                expect_len(payload, 8)?;
                let mut data = [0u8; 8];
                data.copy_from_slice(payload);
                Ok(ClientFrame::Ping(data))
            }
            T_UNLOCK => {
                let secret = std::str::from_utf8(payload)
                    .map_err(|e| ProtoError::BadPayload(e.to_string()))?;
                Ok(ClientFrame::Unlock(secret.to_owned()))
            }
            T_DETACH => {
                expect_len(payload, 0)?;
                Ok(ClientFrame::Detach)
            }
            T_KILL => {
                expect_len(payload, 0)?;
                Ok(ClientFrame::Kill)
            }
            other => Err(ProtoError::UnknownType(other)),
        }
    }
}

impl ServerFrame {
    pub fn encode(&self) -> Vec<u8> {
        match self {
            ServerFrame::Stdout(data) => encode_frame(T_STDOUT, data),
            ServerFrame::Attached(resp) => encode_frame(T_ATTACHED, &to_json(resp)),
            ServerFrame::Exit(code) => encode_frame(T_EXIT, &code.to_be_bytes()),
            ServerFrame::Pong(data) => encode_frame(T_PONG, data),
            ServerFrame::Err { code, message } => {
                let payload = ErrPayload {
                    code: *code,
                    message: message.clone(),
                };
                encode_frame(T_ERR, &to_json(&payload))
            }
            ServerFrame::NeedUnlock { attempts_left } => {
                let payload = NeedUnlockPayload {
                    attempts_left: *attempts_left,
                };
                encode_frame(T_NEED_UNLOCK, &to_json(&payload))
            }
        }
    }

    pub fn decode(buf: &[u8]) -> Result<Self, ProtoError> {
        let (frame_type, payload) = split_frame(buf)?;
        match frame_type {
            T_STDOUT => Ok(ServerFrame::Stdout(Bytes::copy_from_slice(payload))),
            T_ATTACHED => Ok(ServerFrame::Attached(parse_json(payload)?)),
            T_EXIT => {
                expect_len(payload, 4)?;
                Ok(ServerFrame::Exit(u32::from_be_bytes([
                    payload[0], payload[1], payload[2], payload[3],
                ])))
            }
            T_PONG => {
                expect_len(payload, 8)?;
                let mut data = [0u8; 8];
                data.copy_from_slice(payload);
                Ok(ServerFrame::Pong(data))
            }
            T_ERR => {
                let ErrPayload { code, message } = parse_json(payload)?;
                Ok(ServerFrame::Err { code, message })
            }
            T_NEED_UNLOCK => {
                let NeedUnlockPayload { attempts_left } = parse_json(payload)?;
                Ok(ServerFrame::NeedUnlock { attempts_left })
            }
            other => Err(ProtoError::UnknownType(other)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attach_req_full() -> AttachReq {
        AttachReq {
            proto_version: PROTO_VERSION,
            session_id: Some("f1e2d3c4-b5a6-7890-1234-567890abcdef".into()),
            cmd: Some("/usr/bin/htop".into()),
            cwd: Some("/home/user".into()),
            cols: 120,
            rows: 40,
        }
    }

    fn attach_req_minimal() -> AttachReq {
        AttachReq {
            proto_version: PROTO_VERSION,
            session_id: None,
            cmd: None,
            cwd: None,
            cols: 80,
            rows: 24,
        }
    }

    fn attached_resp() -> AttachedResp {
        AttachedResp {
            session_id: "f1e2d3c4-b5a6-7890-1234-567890abcdef".into(),
            cols: 120,
            rows: 40,
            replay_bytes: 4096,
            shell: "/bin/zsh".into(),
            host: "macbook".into(),
            created_at: 1_756_900_000,
        }
    }

    fn client_roundtrip(frame: ClientFrame) {
        let encoded = frame.encode();
        let decoded = ClientFrame::decode(&encoded).expect("decode");
        assert_eq!(frame, decoded);
    }

    fn server_roundtrip(frame: ServerFrame) {
        let encoded = frame.encode();
        let decoded = ServerFrame::decode(&encoded).expect("decode");
        assert_eq!(frame, decoded);
    }

    // ---- roundtrips: every ClientFrame variant ----

    #[test]
    fn roundtrip_stdin() {
        client_roundtrip(ClientFrame::Stdin(Bytes::from_static(b"ls -la\n")));
    }

    #[test]
    fn roundtrip_stdin_empty() {
        client_roundtrip(ClientFrame::Stdin(Bytes::new()));
    }

    #[test]
    fn roundtrip_resize() {
        client_roundtrip(ClientFrame::Resize {
            cols: 213,
            rows: 57,
        });
    }

    #[test]
    fn roundtrip_resize_extremes() {
        client_roundtrip(ClientFrame::Resize {
            cols: u16::MAX,
            rows: 0,
        });
    }

    #[test]
    fn roundtrip_attach_full() {
        client_roundtrip(ClientFrame::Attach(attach_req_full()));
    }

    #[test]
    fn roundtrip_attach_minimal() {
        client_roundtrip(ClientFrame::Attach(attach_req_minimal()));
    }

    #[test]
    fn roundtrip_ping() {
        client_roundtrip(ClientFrame::Ping([1, 2, 3, 4, 5, 6, 7, 8]));
    }

    #[test]
    fn roundtrip_unlock() {
        client_roundtrip(ClientFrame::Unlock("hünter2 🔑".into()));
    }

    #[test]
    fn roundtrip_detach() {
        client_roundtrip(ClientFrame::Detach);
    }

    #[test]
    fn roundtrip_kill() {
        client_roundtrip(ClientFrame::Kill);
    }

    // ---- roundtrips: every ServerFrame variant ----

    #[test]
    fn roundtrip_stdout() {
        server_roundtrip(ServerFrame::Stdout(Bytes::from_static(b"\x1b[2J\x1b[H")));
    }

    #[test]
    fn roundtrip_attached() {
        server_roundtrip(ServerFrame::Attached(attached_resp()));
    }

    #[test]
    fn roundtrip_exit() {
        server_roundtrip(ServerFrame::Exit(137));
    }

    #[test]
    fn roundtrip_exit_max() {
        server_roundtrip(ServerFrame::Exit(u32::MAX));
    }

    #[test]
    fn roundtrip_pong() {
        server_roundtrip(ServerFrame::Pong([8, 7, 6, 5, 4, 3, 2, 1]));
    }

    #[test]
    fn roundtrip_err_all_codes() {
        for code in [
            ErrCode::SessionGone,
            ErrCode::SessionReplaced,
            ErrCode::Unauthorized,
            ErrCode::LockedOut,
            ErrCode::TooManySessions,
            ErrCode::SpawnFailed,
            ErrCode::ProtocolVersion,
            ErrCode::ClientTooSlow,
        ] {
            server_roundtrip(ServerFrame::Err {
                code,
                message: "supported: 1".into(),
            });
        }
    }

    #[test]
    fn roundtrip_need_unlock() {
        server_roundtrip(ServerFrame::NeedUnlock { attempts_left: 3 });
    }

    // ---- wire format checks ----

    #[test]
    fn stdin_wire_layout() {
        let encoded = ClientFrame::Stdin(Bytes::from_static(b"hi")).encode();
        assert_eq!(encoded, vec![0x01, 0, 0, 0, 2, b'h', b'i']);
    }

    #[test]
    fn resize_wire_layout_is_be() {
        let encoded = ClientFrame::Resize {
            cols: 0x0102,
            rows: 0x0304,
        }
        .encode();
        assert_eq!(encoded, vec![0x02, 0, 0, 0, 4, 0x01, 0x02, 0x03, 0x04]);
    }

    #[test]
    fn exit_wire_layout_is_be() {
        let encoded = ServerFrame::Exit(0x01020304).encode();
        assert_eq!(encoded, vec![0x83, 0, 0, 0, 4, 0x01, 0x02, 0x03, 0x04]);
    }

    #[test]
    fn detach_and_kill_are_empty() {
        assert_eq!(ClientFrame::Detach.encode(), vec![0x06, 0, 0, 0, 0]);
        assert_eq!(ClientFrame::Kill.encode(), vec![0x07, 0, 0, 0, 0]);
    }

    #[test]
    fn attach_minimal_omits_optional_fields() {
        let encoded = ClientFrame::Attach(attach_req_minimal()).encode();
        let json = std::str::from_utf8(&encoded[HEADER_LEN..]).unwrap();
        assert!(!json.contains("session_id"));
        assert!(!json.contains("cmd"));
        assert!(!json.contains("cwd"));
        assert!(json.contains("\"proto_version\":1"));
    }

    #[test]
    fn err_code_serializes_screaming_snake() {
        // Spot check requested by the spec: SessionGone == "SESSION_GONE" on the wire.
        assert_eq!(
            serde_json::to_string(&ErrCode::SessionGone).unwrap(),
            "\"SESSION_GONE\""
        );
        let encoded = ServerFrame::Err {
            code: ErrCode::SessionGone,
            message: "bye".into(),
        }
        .encode();
        let json = std::str::from_utf8(&encoded[HEADER_LEN..]).unwrap();
        assert!(json.contains("\"SESSION_GONE\""));
        assert_eq!(
            serde_json::to_string(&ErrCode::ClientTooSlow).unwrap(),
            "\"CLIENT_TOO_SLOW\""
        );
    }

    // ---- error cases ----

    #[test]
    fn truncated_header() {
        for len in 0..HEADER_LEN {
            let buf = vec![0x01; len];
            assert!(matches!(
                ClientFrame::decode(&buf),
                Err(ProtoError::Truncated)
            ));
            assert!(matches!(
                ServerFrame::decode(&buf),
                Err(ProtoError::Truncated)
            ));
        }
    }

    #[test]
    fn truncated_payload() {
        // Declares 10 payload bytes, supplies 3.
        let buf = [0x01, 0, 0, 0, 10, b'a', b'b', b'c'];
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::Truncated)
        ));
        let buf = [0x81, 0, 0, 0, 10, b'a', b'b', b'c'];
        assert!(matches!(
            ServerFrame::decode(&buf),
            Err(ProtoError::Truncated)
        ));
    }

    #[test]
    fn oversized_declared_length() {
        let declared = (MAX_PAYLOAD + 1) as u32;
        let mut buf = vec![0x01];
        buf.extend_from_slice(&declared.to_be_bytes());
        // No payload attached: TooLarge must fire before any payload is read.
        match ClientFrame::decode(&buf) {
            Err(ProtoError::TooLarge(n)) => assert_eq!(n, MAX_PAYLOAD + 1),
            other => panic!("expected TooLarge, got {other:?}"),
        }
        buf[0] = 0x81;
        assert!(matches!(
            ServerFrame::decode(&buf),
            Err(ProtoError::TooLarge(_))
        ));
        // u32::MAX declared length is likewise rejected.
        let mut huge = vec![0x01];
        huge.extend_from_slice(&u32::MAX.to_be_bytes());
        assert!(matches!(
            ClientFrame::decode(&huge),
            Err(ProtoError::TooLarge(_))
        ));
    }

    #[test]
    fn max_payload_exactly_is_accepted() {
        let data = vec![0x55u8; MAX_PAYLOAD];
        let frame = ClientFrame::Stdin(Bytes::from(data));
        client_roundtrip(frame);
    }

    #[test]
    fn unknown_type_0x00() {
        let buf = [0x00, 0, 0, 0, 0];
        match ClientFrame::decode(&buf) {
            Err(ProtoError::UnknownType(t)) => assert_eq!(t, 0x00),
            other => panic!("expected UnknownType, got {other:?}"),
        }
        match ServerFrame::decode(&buf) {
            Err(ProtoError::UnknownType(t)) => assert_eq!(t, 0x00),
            other => panic!("expected UnknownType, got {other:?}"),
        }
    }

    #[test]
    fn unknown_type_0x50() {
        let buf = [0x50, 0, 0, 0, 0];
        match ClientFrame::decode(&buf) {
            Err(ProtoError::UnknownType(t)) => assert_eq!(t, 0x50),
            other => panic!("expected UnknownType, got {other:?}"),
        }
        match ServerFrame::decode(&buf) {
            Err(ProtoError::UnknownType(t)) => assert_eq!(t, 0x50),
            other => panic!("expected UnknownType, got {other:?}"),
        }
    }

    #[test]
    fn server_type_rejected_by_client_decoder_and_vice_versa() {
        assert!(matches!(
            ClientFrame::decode(&[0x81, 0, 0, 0, 1, b'x']),
            Err(ProtoError::UnknownType(0x81))
        ));
        assert!(matches!(
            ServerFrame::decode(&[0x01, 0, 0, 0, 1, b'x']),
            Err(ProtoError::UnknownType(0x01))
        ));
    }

    #[test]
    fn trailing_garbage() {
        let mut buf = ClientFrame::Detach.encode();
        buf.push(0xFF);
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));

        let mut buf = ServerFrame::Exit(0).encode();
        buf.extend_from_slice(b"junk");
        assert!(matches!(
            ServerFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));
    }

    #[test]
    fn resize_wrong_payload_length() {
        // 3-byte payload, correctly framed, but RESIZE requires exactly 4.
        let buf = [0x02, 0, 0, 0, 3, 0, 80, 0];
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));
        // 5-byte payload likewise.
        let buf = [0x02, 0, 0, 0, 5, 0, 80, 0, 24, 0];
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));
    }

    #[test]
    fn ping_pong_wrong_payload_length() {
        let buf = [0x04, 0, 0, 0, 7, 1, 2, 3, 4, 5, 6, 7];
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));
        let buf = [0x84, 0, 0, 0, 7, 1, 2, 3, 4, 5, 6, 7];
        assert!(matches!(
            ServerFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));
    }

    #[test]
    fn exit_wrong_payload_length() {
        let buf = [0x83, 0, 0, 0, 2, 0, 1];
        assert!(matches!(
            ServerFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));
    }

    #[test]
    fn detach_kill_nonempty_payload() {
        let buf = [0x06, 0, 0, 0, 1, 0];
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));
        let buf = [0x07, 0, 0, 0, 1, 0];
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::LengthMismatch)
        ));
    }

    #[test]
    fn attach_invalid_json() {
        let payload = b"{not json";
        let mut buf = vec![0x03, 0, 0, 0, payload.len() as u8];
        buf.extend_from_slice(payload);
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::BadPayload(_))
        ));
    }

    #[test]
    fn attach_json_missing_required_field() {
        let payload = br#"{"proto_version":1,"cols":80}"#;
        let mut buf = vec![0x03, 0, 0, 0, payload.len() as u8];
        buf.extend_from_slice(payload);
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::BadPayload(_))
        ));
    }

    #[test]
    fn attached_invalid_json() {
        let payload = b"[]";
        let mut buf = vec![0x82, 0, 0, 0, payload.len() as u8];
        buf.extend_from_slice(payload);
        assert!(matches!(
            ServerFrame::decode(&buf),
            Err(ProtoError::BadPayload(_))
        ));
    }

    #[test]
    fn err_unknown_code_is_bad_payload() {
        let payload = br#"{"code":"NOT_A_CODE","message":"x"}"#;
        let mut buf = vec![0x85, 0, 0, 0, payload.len() as u8];
        buf.extend_from_slice(payload);
        assert!(matches!(
            ServerFrame::decode(&buf),
            Err(ProtoError::BadPayload(_))
        ));
    }

    #[test]
    fn need_unlock_invalid_json() {
        let payload = br#"{"attempts_left":"three"}"#;
        let mut buf = vec![0x86, 0, 0, 0, payload.len() as u8];
        buf.extend_from_slice(payload);
        assert!(matches!(
            ServerFrame::decode(&buf),
            Err(ProtoError::BadPayload(_))
        ));
    }

    #[test]
    fn unlock_invalid_utf8() {
        let buf = [0x05, 0, 0, 0, 2, 0xFF, 0xFE];
        assert!(matches!(
            ClientFrame::decode(&buf),
            Err(ProtoError::BadPayload(_))
        ));
    }

    #[test]
    fn err_json_decodes_known_shape() {
        // Hand-built wire payload, exactly the shape the protocol doc specifies.
        let payload = br#"{"code":"PROTOCOL_VERSION","message":"supported: 1"}"#;
        let mut buf = vec![0x85, 0, 0, 0, payload.len() as u8];
        buf.extend_from_slice(payload);
        let decoded = ServerFrame::decode(&buf).unwrap();
        assert_eq!(
            decoded,
            ServerFrame::Err {
                code: ErrCode::ProtocolVersion,
                message: "supported: 1".into(),
            }
        );
    }
}
