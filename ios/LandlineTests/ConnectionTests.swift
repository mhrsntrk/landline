import XCTest
@testable import Landline

/// A transport a test drives by hand: it records what was sent and delivers
/// whatever the test decides arrived.
final class FakeTransport: WebSocketTransport {
    var onMessage: ((Result<Data, Error>) -> Void)?

    private(set) var cancelled = false
    private(set) var connectedTo: URL?

    /// Every transport this test run created, in order, so a test can assert on
    /// how many sockets a reconnect actually opened.
    nonisolated(unsafe) static var all: [FakeTransport] = []

    static func reset() { all = [] }

    static func make() -> WebSocketTransport {
        let transport = FakeTransport()
        all.append(transport)
        return transport
    }

    func connect(url: URL) { connectedTo = url }

    /// The raw frames the connection wrote, so a test can assert on the wire
    /// rather than on an interpretation of it.
    private(set) var sentRaw: [Data] = []

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        sentRaw.append(data)
        completion(nil)
    }

    func cancel() { cancelled = true }

    /// Delivers a server frame as if it had arrived on the wire. Framed by
    /// hand, the way `FrameTests` does, so the test exercises the real decoder.
    func deliver(type: UInt8, payload: [UInt8]) {
        var data = Data([type])
        let length = UInt32(payload.count)
        data.append(contentsOf: [
            UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
        ])
        data.append(contentsOf: payload)
        onMessage?(.success(data))
    }

    func deliverJSON(type: UInt8, _ json: String) {
        deliver(type: type, payload: Array(json.utf8))
    }

    /// The type byte of each frame this transport was given.
    var sentTypes: [UInt8] { sentRaw.compactMap(\.first) }

    /// The ATTACH payload, decoded, if one was sent.
    var attachRequest: [String: Any]? {
        guard let raw = sentRaw.first(where: { $0.first == 0x03 }), raw.count > 5 else { return nil }
        return try? JSONSerialization.jsonObject(with: raw.dropFirst(5)) as? [String: Any]
    }

    /// Fails the socket, the way a dropped link does.
    func fail(_ message: String = "socket died") {
        onMessage?(.failure(NSError(domain: "test", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: message])))
    }
}

/// The connection state machine: the reconnect and keepalive behavior added
/// most recently, which is the least covered and the easiest to break.
@MainActor
final class ConnectionTests: XCTestCase {
    private var connection: Connection!
    private var host: Host!

    override func setUp() {
        super.setUp()
        FakeTransport.reset()
        connection = Connection(makeTransport: FakeTransport.make)
        host = Host(name: "studio", hostname: "studio.tail1234.ts.net")
    }

    /// Retires the connection between tests.
    ///
    /// Without this a test that ends mid-backoff leaves a live reconnect timer
    /// on a `Connection` nothing has released, and the *next* test's run-loop
    /// pump fires it: a socket appears on the shared counter that the running
    /// test never asked for. It passed locally, where the timing rarely lined
    /// up, and failed in CI, which is exactly the failure this job exists to
    /// catch.
    override func tearDown() {
        connection?.disconnect(sendDetach: false)
        connection = nil
        FakeTransport.reset()
        super.tearDown()
    }

    private func attach(_ transport: FakeTransport, session: String = "s-1") {
        transport.deliverJSON(type: 0x82, """
        {"session_id":"\(session)","cols":80,"rows":24,"replay_bytes":0,        "shell":"/bin/zsh","host":"studio","created_at":0}
        """)
    }

    private func sessionGone(_ transport: FakeTransport) {
        transport.deliverJSON(type: 0x85, #"{"code":"SESSION_GONE","message":"gone"}"#)
        settle()
    }

    private var live: FakeTransport { FakeTransport.all.last! }

    /// Lets queued main-queue work run.
    ///
    /// `Connection` hands every transport callback to `DispatchQueue.main`
    /// before touching its state, so nothing a test delivers has taken effect
    /// by the time the delivering line returns.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    // MARK: Retry only what deserves it

    /// A link that never attached is not retried: a wrong hostname does not
    /// become right, and six silent attempts under a band promising the session
    /// "will be resumed" would be a claim nothing had checked.
    func testAFailureBeforeAttachingClosesRatherThanRetrying() {
        connection.connect(host: host, cols: 80, rows: 24)
        live.fail("host unreachable")
        settle()

        guard case .closed = connection.state else {
            return XCTFail("expected closed, got \(connection.state)")
        }
        XCTAssertEqual(FakeTransport.all.count, 1, "no retry socket should have been opened")
    }

    /// A link that *did* attach is retried, because the session is still on the
    /// daemon and a phone's network drops for reasons that pass.
    func testAFailureAfterAttachingSchedulesAReconnect() {
        connection.connect(host: host, cols: 80, rows: 24)
        attach(live)
        live.fail()
        settle()

        guard case .reconnecting(let attempt, _) = connection.state else {
            return XCTFail("expected reconnecting, got \(connection.state)")
        }
        XCTAssertEqual(attempt, 1)
    }

    // MARK: The epoch guard

    /// Frames in flight when a socket dies each deliver their own failure. Left
    /// unguarded they re-enter the close path, multiply-counting attempts (a
    /// burst of queued keys could spend every one at once) and potentially
    /// nilling a replacement socket the backoff had already opened.
    func testStaleSendFailuresDoNotCountAsExtraAttempts() {
        connection.connect(host: host, cols: 80, rows: 24)
        let first = live
        attach(first)

        first.fail()
        settle()
        guard case .reconnecting(let afterOne, _) = connection.state else {
            return XCTFail("expected reconnecting")
        }
        XCTAssertEqual(afterOne, 1)

        // Three more failures from the same dead socket.
        first.fail()
        first.fail()
        first.fail()
        settle()

        guard case .reconnecting(let afterMany, _) = connection.state else {
            return XCTFail("expected still reconnecting, got \(connection.state)")
        }
        XCTAssertEqual(afterMany, 1, "a dead socket's late failures are not new attempts")
    }

    // MARK: SESSION_GONE

    /// A stored id the daemon has forgotten is retried once, fresh. The second
    /// time in a row it is a real error rather than a loop.
    func testSessionGoneRetriesOnceThenReports() {
        connection.connect(host: host, cols: 80, rows: 24)
        attach(live, session: "s-1")

        sessionGone(live)
        XCTAssertEqual(FakeTransport.all.count, 2, "a fresh attach socket should have opened")
        // The fresh attach carries no session id.
        let retry = FakeTransport.all[1].attachRequest
        XCTAssertNotNil(retry, "expected an ATTACH on the retry socket")
        XCTAssertNil(retry?["session_id"], "the retry must not resume the dead id")

        sessionGone(FakeTransport.all[1])
        guard case .closed = connection.state else {
            return XCTFail("a second SESSION_GONE should close, got \(connection.state)")
        }
    }

    /// The one-shot downgrade is spent per loss, not per screen: a session that
    /// recovered once must still recover from the next daemon restart.
    func testSessionGoneRearmsAfterASuccessfulAttach() {
        connection.connect(host: host, cols: 80, rows: 24)
        attach(live, session: "s-1")
        sessionGone(live)

        // The fresh attach succeeds, which re-arms the one-shot.
        attach(FakeTransport.all[1], session: "s-2")
        sessionGone(FakeTransport.all[1])

        XCTAssertEqual(FakeTransport.all.count, 3,
                       "a later SESSION_GONE should get its own fresh attach")
    }

    // MARK: Sends

    /// There is no socket during a backoff, and a keystroke queued against the
    /// one that replaces it would arrive at a prompt that has moved on.
    func testKeystrokesAreDroppedWhileReconnecting() {
        connection.connect(host: host, cols: 80, rows: 24)
        attach(live)
        let attached = live
        attached.fail()
        settle()

        let before = attached.sentRaw.count
        connection.send(.stdin(Data("ls\n".utf8)))
        XCTAssertEqual(attached.sentRaw.count, before, "nothing should reach a retired socket")
    }

    func testRetryNowOpensASocketImmediately() {
        connection.connect(host: host, cols: 80, rows: 24)
        attach(live)
        live.fail()
        settle()
        XCTAssertEqual(FakeTransport.all.count, 1, "the backoff has not fired yet")

        connection.retryNow()
        XCTAssertEqual(FakeTransport.all.count, 2, "retry now does not wait out the delay")
    }

    // MARK: Handshake

    func testTheFirstFrameIsAlwaysAttach() {
        connection.connect(host: host, cols: 120, rows: 40)
        XCTAssertEqual(live.sentTypes.first, 0x03, "ATTACH must be first (PROTOCOL.md 1)")
        let req = live.attachRequest
        XCTAssertEqual(req?["cols"] as? Int, 120)
        XCTAssertEqual(req?["rows"] as? Int, 40)
    }

    func testAStoredSessionIdIsResumed() {
        var resuming = host!
        resuming.lastSessionID = "s-stored"
        connection.connect(host: resuming, cols: 80, rows: 24)
        XCTAssertEqual(live.attachRequest?["session_id"] as? String, "s-stored")
    }

    func testDisconnectRetiresTheSocketAndStopsRetrying() {
        connection.connect(host: host, cols: 80, rows: 24)
        attach(live)
        let attached = live

        connection.disconnect(sendDetach: true)
        XCTAssertTrue(attached.cancelled)

        // A late failure from the retired socket must not resurrect anything.
        attached.fail()
        settle()
        XCTAssertEqual(FakeTransport.all.count, 1)
        guard case .closed = connection.state else {
            return XCTFail("expected closed, got \(connection.state)")
        }
    }
}
