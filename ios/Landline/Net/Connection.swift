import Foundation

// MARK: - Transport abstraction
//
// The WebSocket lives behind this small protocol so the transport stays
// swappable. If URLSessionWebSocketTask misbehaves (e.g. silent half-open
// sockets across network transitions on the tailnet), an NWConnection-based
// transport slots in here: implement WebSocketTransport with
// NWConnection + NWProtocolWebSocket options, and Connection never notices.

protocol WebSocketTransport: AnyObject {
    /// Called once per received binary message, or with a failure when the
    /// transport dies. After a failure no further callbacks arrive.
    var onMessage: ((Result<Data, Error>) -> Void)? { get set }
    func connect(url: URL)
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func cancel()
}

final class URLSessionWebSocketTransport: NSObject, WebSocketTransport {
    var onMessage: ((Result<Data, Error>) -> Void)?

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default)

    func connect(url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let task = session.webSocketTask(with: request)
        // PROTOCOL.md: daemon max message size is 1 MiB + 5 bytes.
        task.maximumMessageSize = Int(FrameConstants.maxPayload) + FrameConstants.headerLength
        self.task = task
        task.resume()
        receiveLoop()
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        task?.send(.data(data), completionHandler: completion)
    }

    func cancel() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.onMessage?(.success(data))
                    self.receiveLoop()
                case .string:
                    // Text messages are a protocol error (PROTOCOL.md); close 1002.
                    self.task?.cancel(with: .protocolError, reason: nil)
                    self.onMessage?(.failure(ConnectionError.textMessageReceived))
                @unknown default:
                    self.receiveLoop()
                }
            case .failure(let error):
                self.onMessage?(.failure(error))
            }
        }
    }
}

enum ConnectionError: Error {
    case textMessageReceived
    case protocolViolation(FrameError)
}

// MARK: - Connection

/// One logical attach to one host. Owns the transport, drives the handshake,
/// pings while live, and maps server frames to callbacks.
///
/// All callbacks fire on the main queue.
final class Connection {
    enum State {
        case idle
        case connecting
        case attaching
        case needsUnlock(attemptsLeft: Int)
        case live(AttachedResp)
        /// Waiting out a backoff delay before trying again. Distinct from
        /// `connecting`, because the header has to say that this is a retry
        /// rather than a first attempt nobody asked for.
        case reconnecting(attempt: Int, reason: String)
        case closed(reason: String)
    }

    private(set) var state: State = .idle {
        didSet { onState?(state) }
    }

    var onState: ((State) -> Void)?
    var onStdout: ((Data) -> Void)?
    /// Fired when a stored session id turned out to be gone, so the caller can
    /// clear it from persistent storage.
    var onSessionInvalidated: (() -> Void)?

    private let makeTransport: () -> WebSocketTransport
    private var transport: WebSocketTransport?
    private var host: Host?
    private var cols = 80
    private var rows = 24
    /// Session id we are trying to resume on this connection, if any.
    private var resumeSessionID: String?
    /// True after SESSION_GONE already triggered one fresh re-attach; a second
    /// failure closes instead of looping.
    private var retriedAfterSessionGone = false
    private var pingTimer: Timer?
    /// When the last PONG came back. A socket that has stopped answering is the
    /// failure this exists to catch: iOS moves a phone between cellular and
    /// wifi constantly, and the losing side of that is routinely a TCP
    /// connection that is open, writable, and connected to nothing. Without
    /// this the header reads LIVE while the far end has been gone for minutes.
    private var lastPongAt: Date?
    /// Consecutive reconnects, for the backoff delay. Reset by a successful
    /// ATTACHED, so a link that flaps once does not spend the rest of the
    /// session waiting.
    private var reconnectAttempts = 0
    private var reconnectTimer: Timer?
    /// True once this connection has reached ATTACHED at least once, which is
    /// what makes an automatic retry honest. See `close(reason:)`.
    private var everAttached = false
    /// Identifies the live transport. A cancelled URLSessionWebSocketTask still
    /// delivers its failure asynchronously, so without this the old socket's
    /// error tears down the socket that replaced it (seen on the SESSION_GONE
    /// re-attach, where the retry could never succeed on its own).
    private var epoch: UInt64 = 0
    private static let pingInterval: TimeInterval = 25
    /// Two missed pings. One is a stall; two is a socket that is not there.
    /// Cheap to be wrong: a false positive costs a reconnect that resumes the
    /// same session and replays the scrollback.
    private static let pongTimeout: TimeInterval = pingInterval * 2 + 5
    /// Reconnects are automatic, so the ceiling matters more than the floor: a
    /// phone in a tunnel must not spend its battery retrying every second, and
    /// a phone that just moved rooms must not wait a minute.
    private static let reconnectBaseDelay: TimeInterval = 1
    private static let reconnectMaxDelay: TimeInterval = 30
    /// After this many, stop and let the person decide. An app that retries
    /// forever against a host that is genuinely off is an app that is warm in
    /// your pocket.
    private static let maxReconnectAttempts = 6

    init(makeTransport: @escaping () -> WebSocketTransport = { URLSessionWebSocketTransport() }) {
        self.makeTransport = makeTransport
    }

    deinit {
        pingTimer?.invalidate()
        reconnectTimer?.invalidate()
        transport?.cancel()
    }

    // MARK: Public API

    func connect(host: Host, cols: Int, rows: Int) {
        self.host = host
        self.cols = cols
        self.rows = rows
        self.resumeSessionID = host.lastSessionID
        self.retriedAfterSessionGone = false
        self.reconnectAttempts = 0
        self.everAttached = false
        openTransport()
    }

    func send(_ frame: ClientFrame) {
        // Guard against frames fired before the handshake or after teardown;
        // a nil transport would silently drop them otherwise.
        switch state {
        // Nothing to send on. `reconnecting` is deliberately here: there is no
        // socket during the backoff, and a keystroke queued against the one
        // that replaces it would arrive at a prompt that has moved on.
        case .idle, .closed, .reconnecting:
            return
        case .connecting, .attaching, .needsUnlock, .live:
            break
        }
        // The epoch this frame is going out on. A send completion is delivered
        // asynchronously and long after the socket it belonged to can have been
        // replaced: without this, every frame in flight when a socket dies
        // lands as its own `close()`, which multiply-counts reconnect attempts
        // (a burst of queued keys can spend all of them at once) and, worse,
        // can nil out the *replacement* transport that the backoff already
        // opened. `onMessage` has always been guarded this way; this path was
        // not.
        let sendingEpoch = epoch
        transport?.send(frame.encode()) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, self.epoch == sendingEpoch else { return }
                self.close(reason: error.localizedDescription)
            }
        }
    }

    func disconnect(sendDetach: Bool) {
        stopPinging()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if sendDetach, case .live = state {
            // Courtesy only: any transport drop is an implicit DETACH (PROTOCOL.md 6).
            transport?.send(ClientFrame.detach.encode()) { _ in }
        }
        // Retire this epoch so the cancelled socket's asynchronous failure
        // cannot report a disconnect over whatever comes next.
        epoch &+= 1
        transport?.onMessage = nil
        transport?.cancel()
        transport = nil
        state = .closed(reason: "disconnected")
    }

    // MARK: Internals

    private func openTransport() {
        guard let host else { return }
        transport?.onMessage = nil
        transport?.cancel()

        epoch &+= 1
        let myEpoch = epoch

        state = .connecting
        let transport = makeTransport()
        self.transport = transport
        transport.onMessage = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.epoch == myEpoch else { return }
                self.handleMessage(result)
            }
        }
        transport.connect(url: host.wsURL)

        // URLSessionWebSocketTask queues sends until the handshake completes,
        // so ATTACH can go out immediately. It MUST be the first frame.
        state = .attaching
        // Empty means "use whatever this machine defaults to", which the daemon
        // resolves from its own default_cmd and then from a plain login shell.
        let typed = host.startCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let attach = AttachReq(
            sessionID: resumeSessionID,
            cmd: typed.isEmpty ? nil : typed,
            cols: cols,
            rows: rows
        )
        send(.attach(attach))
    }

    private func handleMessage(_ result: Result<Data, Error>) {
        switch result {
        case .failure(let error):
            close(reason: reasonText(for: error))
        case .success(let data):
            do {
                try handleFrame(ServerFrame.decode(data))
            } catch {
                // Unknown/oversized/truncated frames are protocol errors: close.
                transport?.cancel()
                close(reason: "protocol error: \(error)")
            }
        }
    }

    private func handleFrame(_ frame: ServerFrame) throws {
        switch frame {
        case .stdout(let data):
            onStdout?(data)

        case .attached(let resp):
            resumeSessionID = resp.sessionID
            reconnectAttempts = 0
            // The one-shot fresh-attach downgrade is spent per *loss*, not per
            // screen. Left set, a session that was resumed once after a
            // SESSION_GONE would refuse to recover from the next one hours
            // later (a daemon restart, say) and close instead, recoverable only
            // by the manual button.
            retriedAfterSessionGone = false
            everAttached = true
            lastPongAt = Date()
            state = .live(resp)
            startPinging()

        case .needUnlock(let attemptsLeft):
            state = .needsUnlock(attemptsLeft: Int(attemptsLeft))

        case .exit(let code):
            stopPinging()
            state = .closed(reason: "process exited (\(code))")

        case .pong:
            lastPongAt = Date()

        case .err(let code, let message):
            if code == ErrCode.sessionGone, resumeSessionID != nil, !retriedAfterSessionGone {
                // The stored session died server-side. Clear it and re-attach
                // once with a fresh session. The server closes after
                // SESSION_GONE, so this needs a new connection.
                retriedAfterSessionGone = true
                resumeSessionID = nil
                onSessionInvalidated?()
                stopPinging()
                openTransport()
            } else {
                stopPinging()
                transport?.cancel()
                state = .closed(reason: "\(code): \(message)")
            }
        }
    }

    /// A transport failure, which is not the same as an ending.
    ///
    /// Anything that dropped while a session was live is worth retrying, because
    /// the session is still on the daemon and a phone's network drops for
    /// reasons that pass. A failure before ever attaching is not retried the
    /// same way: a wrong hostname does not become right.
    ///
    /// The test for that is whether *this* connection ever reached ATTACHED,
    /// not whether a session id is stored. Keying on the id meant every host
    /// opened even once before would cycle six backoff attempts against a
    /// machine that was renamed or switched off, under a band promising the
    /// session would be resumed, which nothing had checked.
    private func close(reason: String) {
        // Ignore late errors from a socket we already replaced or retired.
        if case .closed = state { return }
        stopPinging()
        // Retire this socket's epoch here, not only when the next one opens.
        // A dying socket delivers a failure per frame still in flight, and
        // every one of them reaches this function: without retiring the epoch
        // now, each counts as its own reconnect attempt and a handful of queued
        // keystrokes can spend the entire budget before the first retry runs.
        epoch &+= 1
        transport?.onMessage = nil
        transport?.cancel()
        transport = nil
        if everAttached {
            scheduleReconnect(reason: reason)
        } else {
            state = .closed(reason: reason)
        }
    }

    private func reasonText(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "host unreachable, check that Tailscale is up"
            case NSURLErrorTimedOut:
                return "connection timed out"
            case NSURLErrorNotConnectedToInternet:
                return "no network"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    // MARK: Ping

    private func startPinging() {
        stopPinging()
        lastPongAt = Date()
        // PROTOCOL.md: PING carries exactly 8 opaque bytes; we send monotonic nanos.
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            guard let self, case .live = self.state else { return }

            // Check before sending, so the timeout is measured against the
            // ping *before* this one rather than against one still in flight.
            if let last = self.lastPongAt, Date().timeIntervalSince(last) > Self.pongTimeout {
                // Not a courtesy DETACH: the point is that this socket is not
                // carrying anything, so nothing would arrive.
                self.transport?.onMessage = nil
                self.transport?.cancel()
                self.transport = nil
                self.stopPinging()
                self.scheduleReconnect(reason: "connection went quiet")
                return
            }

            let nanos = DispatchTime.now().uptimeNanoseconds
            var payload = Data(capacity: 8)
            payload.appendUInt32BE(UInt32(truncatingIfNeeded: nanos >> 32))
            payload.appendUInt32BE(UInt32(truncatingIfNeeded: nanos))
            self.send(.ping(payload))
        }
    }

    private func stopPinging() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    // MARK: Reconnect

    /// Retries after a growing delay, then gives up and says so.
    ///
    /// Resuming is the whole reason this is safe to do automatically: the
    /// session lives on the daemon, so a reconnect reattaches to the same shell
    /// and replays the scrollback rather than starting something new. Without
    /// resume this would be a feature that silently opened extra shells.
    private func scheduleReconnect(reason: String) {
        guard host != nil else { return }
        reconnectTimer?.invalidate()

        guard reconnectAttempts < Self.maxReconnectAttempts else {
            state = .closed(reason: reason)
            return
        }
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = min(Self.reconnectBaseDelay * pow(2, Double(attempt)), Self.reconnectMaxDelay)
        state = .reconnecting(attempt: reconnectAttempts, reason: reason)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.openTransport()
        }
    }

    /// Retry now, whatever the backoff was going to be. What the RECONNECT
    /// button and a foregrounding both want: a person who just walked back into
    /// wifi should not wait out a 30 second timer they cannot see.
    func retryNow() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
        openTransport()
    }
}
