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
    /// Identifies the live transport. A cancelled URLSessionWebSocketTask still
    /// delivers its failure asynchronously, so without this the old socket's
    /// error tears down the socket that replaced it (seen on the SESSION_GONE
    /// re-attach, where the retry could never succeed on its own).
    private var epoch: UInt64 = 0
    private static let pingInterval: TimeInterval = 25

    init(makeTransport: @escaping () -> WebSocketTransport = { URLSessionWebSocketTransport() }) {
        self.makeTransport = makeTransport
    }

    deinit {
        pingTimer?.invalidate()
        transport?.cancel()
    }

    // MARK: Public API

    func connect(host: Host, cols: Int, rows: Int) {
        self.host = host
        self.cols = cols
        self.rows = rows
        self.resumeSessionID = host.lastSessionID
        self.retriedAfterSessionGone = false
        openTransport()
    }

    func send(_ frame: ClientFrame) {
        // Guard against frames fired before the handshake or after teardown;
        // a nil transport would silently drop them otherwise.
        switch state {
        case .idle, .closed:
            return
        case .connecting, .attaching, .needsUnlock, .live:
            break
        }
        transport?.send(frame.encode()) { [weak self] error in
            if let error {
                DispatchQueue.main.async { self?.close(reason: error.localizedDescription) }
            }
        }
    }

    func disconnect(sendDetach: Bool) {
        stopPinging()
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
            state = .live(resp)
            startPinging()

        case .needUnlock(let attemptsLeft):
            state = .needsUnlock(attemptsLeft: Int(attemptsLeft))

        case .exit(let code):
            stopPinging()
            state = .closed(reason: "process exited (\(code))")

        case .pong:
            break // opaque echo; latency measurement could live here

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

    private func close(reason: String) {
        // Treat any failure as closed; ignore late errors after we closed.
        if case .closed = state { return }
        stopPinging()
        transport = nil
        state = .closed(reason: reason)
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
        // PROTOCOL.md: PING carries exactly 8 opaque bytes; we send monotonic nanos.
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            guard let self, case .live = self.state else { return }
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
}
