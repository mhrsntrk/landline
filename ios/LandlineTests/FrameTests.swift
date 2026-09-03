import XCTest
@testable import Landline

/// Wire-format tests against docs/PROTOCOL.md. Server frames are hand-crafted
/// byte-for-byte; client frames are checked byte-exact where the spec fixes
/// the layout, structurally where JSON key order is not guaranteed.
final class FrameTests: XCTestCase {

    // MARK: - Helpers

    /// Builds [u8 type][u32 len BE][payload] by hand.
    private func frame(type: UInt8, payload: [UInt8]) -> Data {
        var data = Data()
        data.append(type)
        let len = UInt32(payload.count)
        data.append(UInt8((len >> 24) & 0xFF))
        data.append(UInt8((len >> 16) & 0xFF))
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(UInt8(len & 0xFF))
        data.append(contentsOf: payload)
        return data
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    // MARK: - Server frame decoding (hand-crafted bytes)

    func testDecodeStdout() throws {
        let payload: [UInt8] = [0x68, 0x65, 0x6c, 0x6c, 0x6f] // "hello"
        let decoded = try ServerFrame.decode(frame(type: 0x81, payload: payload))
        XCTAssertEqual(decoded, .stdout(Data(payload)))
    }

    func testDecodeStdoutEmpty() throws {
        let decoded = try ServerFrame.decode(frame(type: 0x81, payload: []))
        XCTAssertEqual(decoded, .stdout(Data()))
    }

    func testDecodeAttached() throws {
        let json = """
        {"session_id":"5b3f5b1e-0000-4000-8000-000000000001",\
        "cols":120,"rows":40,"replay_bytes":4096,\
        "shell":"/bin/zsh","host":"macbook","created_at":1756900000}
        """
        let decoded = try ServerFrame.decode(frame(type: 0x82, payload: [UInt8](json.utf8)))
        guard case .attached(let resp) = decoded else {
            return XCTFail("expected .attached, got \(decoded)")
        }
        XCTAssertEqual(resp.sessionID, "5b3f5b1e-0000-4000-8000-000000000001")
        XCTAssertEqual(resp.cols, 120)
        XCTAssertEqual(resp.rows, 40)
        XCTAssertEqual(resp.replayBytes, 4096)
        XCTAssertEqual(resp.shell, "/bin/zsh")
        XCTAssertEqual(resp.host, "macbook")
        XCTAssertEqual(resp.createdAt, 1_756_900_000)
    }

    func testDecodeExit() throws {
        // exit code 258 = 0x00000102 big-endian
        let decoded = try ServerFrame.decode(frame(type: 0x83, payload: [0x00, 0x00, 0x01, 0x02]))
        XCTAssertEqual(decoded, .exit(258))
    }

    func testDecodeExitWrongLengthThrows() {
        XCTAssertThrowsError(try ServerFrame.decode(frame(type: 0x83, payload: [0x00, 0x01]))) { error in
            XCTAssertEqual(error as? FrameError, .badPayload(type: 0x83))
        }
    }

    func testDecodePong() throws {
        let payload: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let decoded = try ServerFrame.decode(frame(type: 0x84, payload: payload))
        XCTAssertEqual(decoded, .pong(Data(payload)))
    }

    func testDecodeErr() throws {
        let json = #"{"code":"SESSION_GONE","message":"no such session"}"#
        let decoded = try ServerFrame.decode(frame(type: 0x85, payload: [UInt8](json.utf8)))
        XCTAssertEqual(decoded, .err(code: "SESSION_GONE", message: "no such session"))
    }

    func testDecodeNeedUnlock() throws {
        let json = #"{"attempts_left":3}"#
        let decoded = try ServerFrame.decode(frame(type: 0x86, payload: [UInt8](json.utf8)))
        XCTAssertEqual(decoded, .needUnlock(attemptsLeft: 3))
    }

    func testDecodeUnknownTypeThrows() {
        XCTAssertThrowsError(try ServerFrame.decode(frame(type: 0x42, payload: []))) { error in
            XCTAssertEqual(error as? FrameError, .unknownType(0x42))
        }
    }

    func testDecodeTruncatedHeaderThrows() {
        XCTAssertThrowsError(try ServerFrame.decode(Data([0x81, 0x00]))) { error in
            XCTAssertEqual(error as? FrameError, .truncated)
        }
    }

    func testDecodeTruncatedPayloadThrows() {
        // Declares 10 payload bytes, delivers 2.
        var data = frame(type: 0x81, payload: [])
        data[data.startIndex + 4] = 10
        data.append(contentsOf: [0x61, 0x62])
        XCTAssertThrowsError(try ServerFrame.decode(data)) { error in
            XCTAssertEqual(error as? FrameError, .truncated)
        }
    }

    func testDecodeOversizedThrows() {
        // Declared length 1 MiB + 1: reject before reading the payload.
        let data = Data([0x81, 0x00, 0x10, 0x00, 0x01])
        XCTAssertThrowsError(try ServerFrame.decode(data)) { error in
            XCTAssertEqual(error as? FrameError, .oversized(declared: 1_048_577))
        }
    }

    func testDecodeSliceWithNonZeroStartIndex() throws {
        // Data slices keep the parent's indices; decode must not assume 0.
        var padded = Data([0xFF, 0xFF, 0xFF])
        padded.append(frame(type: 0x84, payload: [8, 7, 6, 5, 4, 3, 2, 1]))
        let slice = padded.dropFirst(3)
        XCTAssertNotEqual(slice.startIndex, 0)
        let decoded = try ServerFrame.decode(Data(slice))
        XCTAssertEqual(decoded, .pong(Data([8, 7, 6, 5, 4, 3, 2, 1])))
    }

    // MARK: - Server frame roundtrips (craft bytes -> decode -> re-encode payload semantics)

    func testAttachedRoundtripThroughCodable() throws {
        let resp = AttachedResp(
            sessionID: "0f0e0d0c-0b0a-4908-8706-050403020100",
            cols: 80, rows: 24, replayBytes: 262_144,
            shell: "/bin/bash", host: "ubuntu", createdAt: 1_756_900_123
        )
        let encoded = try JSONEncoder().encode(resp)
        let decoded = try ServerFrame.decode(frame(type: 0x82, payload: [UInt8](encoded)))
        XCTAssertEqual(decoded, .attached(resp))

        // Field names on the wire must match PROTOCOL.md exactly.
        let keys = Set(try jsonObject(encoded).keys)
        XCTAssertEqual(keys, ["session_id", "cols", "rows", "replay_bytes", "shell", "host", "created_at"])
    }

    // MARK: - Client frame encoding

    func testEncodeStdin() {
        let encoded = ClientFrame.stdin(Data([0x6c, 0x73, 0x0a])).encode() // "ls\n"
        XCTAssertEqual(encoded, Data([0x01, 0x00, 0x00, 0x00, 0x03, 0x6c, 0x73, 0x0a]))
    }

    func testEncodeResizeByteExact() {
        // cols 300 = 0x012C, rows 80 = 0x0050, both big-endian, payload exactly 4.
        let encoded = ClientFrame.resize(cols: 300, rows: 80).encode()
        XCTAssertEqual(encoded, Data([0x02, 0x00, 0x00, 0x00, 0x04, 0x01, 0x2C, 0x00, 0x50]))
    }

    func testEncodeResizeExtremes() {
        let encoded = ClientFrame.resize(cols: 0xFFFF, rows: 0x0001).encode()
        XCTAssertEqual(encoded, Data([0x02, 0x00, 0x00, 0x00, 0x04, 0xFF, 0xFF, 0x00, 0x01]))
    }

    func testEncodeAttachFieldNames() throws {
        let req = AttachReq(
            sessionID: "11111111-2222-4333-8444-555555555555",
            cmd: "/usr/bin/htop",
            cwd: "/home/me",
            cols: 120,
            rows: 40
        )
        let encoded = ClientFrame.attach(req).encode()

        XCTAssertEqual(encoded[encoded.startIndex], 0x03)
        let payload = encoded.dropFirst(5)
        XCTAssertEqual(payload.count, Int(encoded.readUInt32BE(at: encoded.startIndex + 1)))

        let obj = try jsonObject(Data(payload))
        XCTAssertEqual(Set(obj.keys), ["proto_version", "session_id", "cmd", "cwd", "cols", "rows"])
        XCTAssertEqual(obj["proto_version"] as? Int, 1)
        XCTAssertEqual(obj["session_id"] as? String, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(obj["cmd"] as? String, "/usr/bin/htop")
        XCTAssertEqual(obj["cwd"] as? String, "/home/me")
        XCTAssertEqual(obj["cols"] as? Int, 120)
        XCTAssertEqual(obj["rows"] as? Int, 40)
    }

    func testEncodeAttachOmitsNilOptionals() throws {
        // "session_id": "uuid, omit to create a new session" — omit, not null.
        let req = AttachReq(cols: 80, rows: 24)
        let payload = Data(ClientFrame.attach(req).encode().dropFirst(5))
        let obj = try jsonObject(payload)
        XCTAssertEqual(Set(obj.keys), ["proto_version", "cols", "rows"])
        XCTAssertEqual(obj["proto_version"] as? Int, 1)
    }

    func testEncodePing() {
        let payload = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let encoded = ClientFrame.ping(payload).encode()
        XCTAssertEqual(encoded, Data([0x04, 0x00, 0x00, 0x00, 0x08]) + payload)
    }

    func testEncodeUnlock() {
        let encoded = ClientFrame.unlock("hunter2").encode()
        XCTAssertEqual(encoded, Data([0x05, 0x00, 0x00, 0x00, 0x07]) + Data("hunter2".utf8))
    }

    func testEncodeUnlockNonASCII() {
        let secret = "gizli-şifre"
        let utf8 = Data(secret.utf8)
        let encoded = ClientFrame.unlock(secret).encode()
        var expected = Data([0x05])
        expected.appendUInt32BE(UInt32(utf8.count))
        expected.append(utf8)
        XCTAssertEqual(encoded, expected)
    }

    func testEncodeDetach() {
        XCTAssertEqual(ClientFrame.detach.encode(), Data([0x06, 0x00, 0x00, 0x00, 0x00]))
    }

    func testEncodeKill() {
        XCTAssertEqual(ClientFrame.kill.encode(), Data([0x07, 0x00, 0x00, 0x00, 0x00]))
    }
}
