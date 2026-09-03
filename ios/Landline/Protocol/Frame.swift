import Foundation

// Swift mirror of docs/PROTOCOL.md, version 1. That file is normative;
// code disagreeing with it is wrong.
//
// Frame encoding: [u8 type][u32 payload_length, big-endian][payload bytes]
// Max payload 1 MiB. Every WebSocket message contains exactly one frame.

enum FrameError: Error, Equatable {
    /// Fewer bytes than the 5-byte header, or payload shorter than the declared length.
    case truncated
    /// Declared length exceeds the 1 MiB maximum.
    case oversized(declared: UInt32)
    /// Trailing bytes after the declared payload — "exactly one frame" violated.
    case trailingBytes
    /// A type byte this protocol version does not know.
    case unknownType(UInt8)
    /// Payload present but malformed for its type (bad JSON, wrong fixed length).
    case badPayload(type: UInt8)
}

enum FrameConstants {
    static let maxPayload: UInt32 = 1_048_576
    static let headerLength = 5
}

// MARK: - JSON payloads

/// ATTACH payload. CodingKeys match PROTOCOL.md field names exactly.
struct AttachReq: Codable, Equatable {
    var protoVersion: Int = 1
    var sessionID: String?
    var cmd: String?
    var cwd: String?
    var cols: Int
    var rows: Int

    enum CodingKeys: String, CodingKey {
        case protoVersion = "proto_version"
        case sessionID = "session_id"
        case cmd
        case cwd
        case cols
        case rows
    }
}

/// ATTACHED payload. CodingKeys match PROTOCOL.md field names exactly.
struct AttachedResp: Codable, Equatable {
    var sessionID: String
    var cols: Int
    var rows: Int
    var replayBytes: Int
    var shell: String
    var host: String
    var createdAt: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cols
        case rows
        case replayBytes = "replay_bytes"
        case shell
        case host
        case createdAt = "created_at"
    }
}

private struct ErrPayload: Codable {
    var code: String
    var message: String
}

private struct NeedUnlockPayload: Codable {
    var attemptsLeft: UInt32
    enum CodingKeys: String, CodingKey {
        case attemptsLeft = "attempts_left"
    }
}

/// Error codes the daemon can send in ERR frames.
enum ErrCode {
    static let sessionGone = "SESSION_GONE"
    static let sessionReplaced = "SESSION_REPLACED"
    static let unauthorized = "UNAUTHORIZED"
    static let lockedOut = "LOCKED_OUT"
    static let tooManySessions = "TOO_MANY_SESSIONS"
    static let spawnFailed = "SPAWN_FAILED"
    static let protocolVersion = "PROTOCOL_VERSION"
    static let clientTooSlow = "CLIENT_TOO_SLOW"
}

// MARK: - Client -> server

enum ClientFrame {
    case stdin(Data)                        // 0x01 raw bytes for the PTY
    case resize(cols: UInt16, rows: UInt16) // 0x02 [u16 cols BE][u16 rows BE]
    case attach(AttachReq)                  // 0x03 JSON
    case ping(Data)                         // 0x04 exactly 8 opaque bytes
    case unlock(String)                     // 0x05 UTF-8 secret
    case detach                             // 0x06 empty
    case kill                               // 0x07 empty

    var type: UInt8 {
        switch self {
        case .stdin: 0x01
        case .resize: 0x02
        case .attach: 0x03
        case .ping: 0x04
        case .unlock: 0x05
        case .detach: 0x06
        case .kill: 0x07
        }
    }

    /// Produces [u8 type][u32 len BE][payload].
    func encode() -> Data {
        let payload: Data
        switch self {
        case .stdin(let data):
            payload = data
        case .resize(let cols, let rows):
            var bytes = Data(capacity: 4)
            bytes.appendUInt16BE(cols)
            bytes.appendUInt16BE(rows)
            payload = bytes
        case .attach(let req):
            // Encoding a value type of plain Codable fields cannot fail.
            payload = (try? JSONEncoder().encode(req)) ?? Data()
        case .ping(let data):
            payload = data
        case .unlock(let secret):
            payload = Data(secret.utf8)
        case .detach, .kill:
            payload = Data()
        }

        var frame = Data(capacity: FrameConstants.headerLength + payload.count)
        frame.append(type)
        frame.appendUInt32BE(UInt32(payload.count))
        frame.append(payload)
        return frame
    }
}

// MARK: - Server -> client

enum ServerFrame: Equatable {
    case stdout(Data)                                // 0x81 raw PTY output
    case attached(AttachedResp)                      // 0x82 JSON
    case exit(UInt32)                                // 0x83 [u32 exit_code BE]
    case pong(Data)                                  // 0x84 echo of PING payload
    case err(code: String, message: String)          // 0x85 JSON {code, message}
    case needUnlock(attemptsLeft: UInt32)            // 0x86 JSON {attempts_left}

    static func decode(_ data: Data) throws -> ServerFrame {
        guard data.count >= FrameConstants.headerLength else { throw FrameError.truncated }

        // Data slices can have a nonzero startIndex; normalize with offsets.
        let start = data.startIndex
        let type = data[start]
        let length = data.readUInt32BE(at: start + 1)

        guard length <= FrameConstants.maxPayload else {
            throw FrameError.oversized(declared: length)
        }
        let total = FrameConstants.headerLength + Int(length)
        guard data.count >= total else { throw FrameError.truncated }
        guard data.count == total else { throw FrameError.trailingBytes }

        let payload = Data(data[(start + FrameConstants.headerLength)...])

        switch type {
        case 0x81:
            return .stdout(payload)
        case 0x82:
            guard let resp = try? JSONDecoder().decode(AttachedResp.self, from: payload) else {
                throw FrameError.badPayload(type: type)
            }
            return .attached(resp)
        case 0x83:
            guard payload.count == 4 else { throw FrameError.badPayload(type: type) }
            return .exit(payload.readUInt32BE(at: payload.startIndex))
        case 0x84:
            return .pong(payload)
        case 0x85:
            guard let err = try? JSONDecoder().decode(ErrPayload.self, from: payload) else {
                throw FrameError.badPayload(type: type)
            }
            return .err(code: err.code, message: err.message)
        case 0x86:
            guard let need = try? JSONDecoder().decode(NeedUnlockPayload.self, from: payload) else {
                throw FrameError.badPayload(type: type)
            }
            return .needUnlock(attemptsLeft: need.attemptsLeft)
        default:
            throw FrameError.unknownType(type)
        }
    }
}

// MARK: - Explicit big-endian helpers

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    /// Reads a big-endian u32 at an absolute index. Caller guarantees bounds.
    func readUInt32BE(at index: Index) -> UInt32 {
        UInt32(self[index]) << 24
            | UInt32(self[index + 1]) << 16
            | UInt32(self[index + 2]) << 8
            | UInt32(self[index + 3])
    }
}
