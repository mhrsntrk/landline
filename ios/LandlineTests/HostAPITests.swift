import XCTest
@testable import Landline

/// A stub transport. Each entry answers one request, in order, and every
/// request is recorded so a test can assert on how many were made and what
/// they carried — which for this client is the whole point.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: Data
        init(_ status: Int, _ json: String = "") {
            self.status = status
            self.body = Data(json.utf8)
        }
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [(method: String, path: String, auth: String?, body: String)] = []

    static func reset(_ replies: [Reply]) {
        self.replies = replies
        self.requests = []
    }

    /// Requests to the token endpoint only.
    static var mintCount: Int { requests.filter { $0.path == "/v1/token" }.count }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // `httpBody` is nil for an upload task; the stream carries it instead.
        var body = ""
        if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            body = String(decoding: collected, as: UTF8.self)
        }

        Self.requests.append((
            method: request.httpMethod ?? "?",
            path: request.url?.path ?? "?",
            auth: request.value(forHTTPHeaderField: "Authorization"),
            body: body
        ))

        let reply = Self.replies.isEmpty
            ? Reply(500)
            : Self.replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The HTTP client: how it spends tokens, and how hard it tries.
final class HostAPITests: XCTestCase {
    private var api: HostAPI!
    private var host: Host!

    private static let goodToken = #"{"token":"abc","expires_in":600,"max_bytes":26214400,"features":["sessions","outbox","files"]}"#

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        api = HostAPI(session: URLSession(configuration: config))
        host = Host(name: "studio", hostname: "studio.tail1234.ts.net")
    }

    // MARK: The one that matters

    /// The token endpoint spends the *same* argon2 failure budget as the shell
    /// handshake, and ten failures lock the host for fifteen minutes. So a
    /// client that retried a wrong secret would lock the owner out of their own
    /// machine in ten taps. It must mint exactly once and give up.
    func testAWrongSecretMintsOnceAndStops() async {
        StubURLProtocol.reset([
            .init(401, #"{"error":"bad_secret","attempts_left":7}"#),
        ])

        do {
            _ = try await api.sessions(on: host, secret: "wrong")
            XCTFail("a wrong secret must not succeed")
        } catch {
            XCTAssertEqual(error as? UploadError, .badSecret(attemptsLeft: 7))
        }
        XCTAssertEqual(StubURLProtocol.mintCount, 1,
                       "a wrong secret must never be retried against the unlock budget")
        XCTAssertEqual(StubURLProtocol.requests.count, 1,
                       "and nothing should be attempted with a token that was never minted")
    }

    /// A daemon restart forgets every token, so the 401 on a *spent* token is
    /// routine and not something a person can act on. That one is retried, but
    /// exactly once, and the retry must carry a freshly minted token.
    func testAnExpiredTokenIsRetriedExactlyOnce() async throws {
        StubURLProtocol.reset([
            .init(200, Self.goodToken),          // mint
            .init(401, #"{"error":"bad_token"}"#), // spent token
            .init(200, Self.goodToken),          // re-mint
            .init(200, "[]"),                    // retry succeeds
        ])

        let sessions = try await api.sessions(on: host, secret: "")
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(StubURLProtocol.mintCount, 2, "one mint, then one re-mint")
        XCTAssertEqual(StubURLProtocol.requests.count, 4)
        XCTAssertEqual(StubURLProtocol.requests.last?.auth, "Bearer abc")
    }

    /// A token that is rejected twice is not an expiry, it is something the
    /// retry cannot fix. One retry, then report.
    func testARepeatedlyRejectedTokenGivesUp() async {
        StubURLProtocol.reset([
            .init(200, Self.goodToken),
            .init(401, #"{"error":"bad_token"}"#),
            .init(200, Self.goodToken),
            .init(401, #"{"error":"bad_token"}"#),
        ])

        do {
            _ = try await api.sessions(on: host, secret: "")
            XCTFail("expected the second refusal to surface")
        } catch {
            XCTAssertEqual(error as? UploadError, .server(status: 401))
        }
        XCTAssertEqual(StubURLProtocol.mintCount, 2, "no third mint")
    }

    /// The token outlives one request, so a second call in the same window must
    /// not spend another argon2 verification.
    func testTheTokenIsCachedAcrossCalls() async throws {
        StubURLProtocol.reset([
            .init(200, Self.goodToken),
            .init(200, "[]"),
            .init(200, "[]"),
        ])

        _ = try await api.sessions(on: host, secret: "")
        _ = try await api.outbox(on: host, secret: "")
        XCTAssertEqual(StubURLProtocol.mintCount, 1, "the second call reuses the grant")
    }

    // MARK: Refusals a person can act on

    func testAnUnauthorizedLoginIsReportedNotRetried() async {
        StubURLProtocol.reset([.init(403, #"{"error":"unauthorized"}"#)])
        do {
            _ = try await api.sessions(on: host, secret: "")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? UploadError, .unauthorized)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testALockedOutHostSaysSo() async {
        StubURLProtocol.reset([.init(429, #"{"error":"locked_out"}"#)])
        do {
            _ = try await api.sessions(on: host, secret: "nope")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? UploadError, .lockedOut)
        }
    }

    /// An upload larger than the host advertised is refused before a byte goes
    /// out, so a phone on cellular does not spend the upload to be told no.
    func testAnOversizedUploadIsRefusedLocally() async {
        StubURLProtocol.reset([
            .init(200, #"{"token":"abc","expires_in":600,"max_bytes":16,"features":["files"]}"#),
        ])
        do {
            _ = try await api.upload(data: Data(repeating: 0x41, count: 64),
                                     filename: "big.bin", to: host, secret: "")
            XCTFail("expected a local refusal")
        } catch {
            XCTAssertEqual(error as? UploadError, .tooLarge(maxBytes: 16))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "only the mint went out")
    }

    // MARK: Session and outbox calls

    func testKillingASessionTreatsGoneAsDone() async throws {
        // The caller asked for it not to be running. A 404 means it is not.
        StubURLProtocol.reset([.init(200, Self.goodToken), .init(404, "")])
        try await api.killSession(id: "abc", on: host, secret: "")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")
    }

    func testSessionsDecodeFromTheDaemonsSnakeCase() async throws {
        StubURLProtocol.reset([
            .init(200, Self.goodToken),
            .init(200, #"[{"id":"aaaa-bbbb","shell":"/bin/zsh","created_at":1757000000,"attached":false,"idle_secs":1428}]"#),
        ])
        let sessions = try await api.sessions(on: host, secret: "")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].shellLabel, "zsh")
        XCTAssertEqual(sessions[0].idleSecs, 1428)
        XCTAssertFalse(sessions[0].attached)
    }
}
