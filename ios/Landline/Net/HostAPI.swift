import Foundation

/// Why an upload did not happen, in the words the strip prints.
///
/// One case per thing the daemon can answer with, because "upload failed" on a
/// phone is useless: the fix for a locked-out host and the fix for a host whose
/// operator turned the inbox off are not the same fix.
enum UploadError: Error, Equatable {
    /// HTTP 403: this tailnet login is not in the host's `allowed_logins`.
    case unauthorized
    /// HTTP 401 from the token endpoint: the stored unlock secret is wrong.
    case badSecret(attemptsLeft: Int)
    /// HTTP 429: the unlock failure budget is spent.
    case lockedOut
    /// HTTP 404: this host does not serve the inbox.
    case disabled
    /// HTTP 413, or a local file bigger than the host said it would take.
    case tooLarge(maxBytes: Int)
    case server(status: Int)
    case transport(String)
    /// The picker handed back nothing to send.
    case empty

    /// One line, no more than the strip can hold.
    var message: String {
        switch self {
        case .unauthorized:
            return "this login is not allowed on that host"
        case .badSecret(let attemptsLeft):
            return "wrong unlock secret, \(attemptsLeft) tries left"
        case .lockedOut:
            return "host locked out, try again in 15 minutes"
        case .disabled:
            return "that host does not accept files"
        case .tooLarge(let maxBytes):
            return "too big, the host takes \(maxBytes / 1_048_576) MB"
        case .server(let status):
            return "host refused the upload (\(status))"
        case .transport(let reason):
            return reason
        case .empty:
            return "nothing to send"
        }
    }
}

/// The client for everything the daemon serves over HTTP beside the shell:
/// the file inbox, the session list, and the outbox (`docs/HTTP.md`).
///
/// One actor because they share the one thing that is awkward: the token. The
/// two-step exchange (mint a token, then spend it) exists so the unlock secret
/// is argon2-verified once per session rather than once per request, and so no
/// request but the mint itself ever carries the secret. Tokens live in memory
/// here and nowhere else.
actor HostAPI {
    private struct Grant {
        let token: String
        let maxBytes: Int
        let features: Set<String>
        let expires: Date
    }

    /// Per host, because a phone reaches several and a token is minted for one.
    private var grants: [UUID: Grant] = [:]
    /// A failed mint is not retried by background polling with the same secret.
    private var refusals: [UUID: (secret: String, error: UploadError)] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Uploads `data` and returns the absolute path on the host.
    ///
    /// `secret` is the stored unlock secret, or the empty string on a host that
    /// has none. A token that the daemon has already forgotten (a restart, or
    /// simply time) answers 401, which is retried once with a fresh token
    /// rather than surfaced: an expired token is not something a person can act
    /// on.
    func upload(data: Data, filename: String, to host: Host, secret: String) async throws -> String {
        guard !data.isEmpty else { throw UploadError.empty }

        var grant = try await token(for: host, secret: secret, forceRefresh: false)
        if data.count > grant.maxBytes {
            throw UploadError.tooLarge(maxBytes: grant.maxBytes)
        }
        do {
            return try await put(data: data, filename: filename, host: host, grant: grant)
        } catch UploadError.server(status: 401) {
            grant = try await token(for: host, secret: secret, forceRefresh: true)
            return try await put(data: data, filename: filename, host: host, grant: grant)
        }
    }

    // MARK: Sessions

    /// What is running on `host`, newest first.
    func sessions(on host: Host, secret: String) async throws -> [HostSession] {
        try await get([HostSession].self, path: "/v1/sessions", host: host, secret: secret)
    }

    /// Kills one session. Gone means gone: 404 is treated as success, because
    /// the caller asked for it to not be running and it is not running.
    func killSession(id: String, on host: Host, secret: String) async throws {
        _ = try await send(method: "DELETE", path: "/v1/sessions/\(id)",
                           host: host, secret: secret, tolerating404: true)
    }

    // MARK: Outbox

    /// Files the host has offered, newest first.
    func outbox(on host: Host, secret: String) async throws -> [HostOffer] {
        try await get([HostOffer].self, path: "/v1/outbox", host: host, secret: secret)
    }

    /// Downloads one offer to a temporary file and returns where it landed.
    ///
    /// To a file rather than to memory, because what is coming back is whatever
    /// the host felt like sending and the phone has to hand a URL to QuickLook
    /// anyway.
    func fetchOffer(_ offer: HostOffer, on host: Host, secret: String) async throws -> URL {
        var grant = try await token(for: host, secret: secret, forceRefresh: false)
        let downloaded: URL
        do {
            downloaded = try await downloadOffer(offer, host: host, grant: grant)
        } catch UploadError.server(status: 401) {
            grant = try await token(for: host, secret: secret, forceRefresh: true)
            downloaded = try await downloadOffer(offer, host: host, grant: grant)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let slot = Self.offersDirectory.appendingPathComponent(Self.pathSegment(for: offer.id), isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let url = slot.appendingPathComponent(Self.pathSegment(for: offer.name))
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: downloaded, to: url)
        return url
    }

    private func downloadOffer(_ offer: HostOffer, host: Host, grant: Grant) async throws -> URL {
        var request = URLRequest(url: host.apiURL(path: "/v1/outbox/\(offer.id)"))
        request.timeoutInterval = 300
        request.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await session.download(for: request)
        } catch {
            throw UploadError.transport(Self.reason(for: error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            switch status {
            case 403: throw UploadError.unauthorized
            case 404: throw UploadError.disabled
            default: throw UploadError.server(status: status)
            }
        }
        return file
    }

    /// Where fetched offers land.
    static var offersDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("landline-offers", isDirectory: true)
    }

    /// Deletes fetched offers older than a day.
    ///
    /// What a host pushes is routinely the sensitive end of what it holds, and
    /// iOS purges `tmp` on its own unhurried schedule. Nothing here was ever
    /// deleted, so a log or a report fetched once stayed on the phone
    /// indefinitely.
    static func sweepFetchedOffers(olderThan age: TimeInterval = 86_400) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: offersDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? manager.removeItem(at: entry)
        }
    }

    /// Withdraws an offer. The host's own copy is untouched.
    func withdrawOffer(id: String, on host: Host, secret: String) async throws {
        _ = try await send(method: "DELETE", path: "/v1/outbox/\(id)",
                           host: host, secret: secret, tolerating404: true)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(
        _ type: T.Type, path: String, host: Host, secret: String
    ) async throws -> T {
        let body = try await send(method: "GET", path: path, host: host, secret: secret)
        guard let decoded = try? JSONDecoder.snakeCase.decode(T.self, from: body) else {
            throw UploadError.server(status: 200)
        }
        return decoded
    }

    /// One authenticated request, with the same expired-token retry the upload
    /// path has: a token the daemon forgot is not something a person can act
    /// on, so it is replaced rather than reported.
    private func send(
        method: String,
        path: String,
        host: Host,
        secret: String,
        tolerating404: Bool = false
    ) async throws -> Data {
        var grant = try await token(for: host, secret: secret, forceRefresh: false)
        do {
            return try await request(method: method, path: path, host: host,
                                     grant: grant, tolerating404: tolerating404)
        } catch UploadError.server(status: 401) {
            grant = try await token(for: host, secret: secret, forceRefresh: true)
            return try await request(method: method, path: path, host: host,
                                     grant: grant, tolerating404: tolerating404)
        }
    }

    private func request(
        method: String,
        path: String,
        host: Host,
        grant: Grant,
        tolerating404: Bool
    ) async throws -> Data {
        var request = URLRequest(url: host.apiURL(path: path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")

        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            throw UploadError.transport(Self.reason(for: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.transport("unexpected response")
        }
        switch http.statusCode {
        case 200, 201, 204:
            return body
        case 403:
            throw UploadError.unauthorized
        case 404 where tolerating404:
            return Data()
        case 404:
            throw UploadError.disabled
        case let status:
            throw UploadError.server(status: status)
        }
    }

    /// Forgets this host's token. Called when its stored secret changes, so the
    /// next upload does not spend a grant minted with the old one.
    func forget(host: UUID) {
        grants[host] = nil
        refusals[host] = nil
    }

    // MARK: Internals

    private func token(for host: Host, secret: String, forceRefresh: Bool) async throws -> Grant {
        if let refusal = refusals[host.id], refusal.secret == secret {
            throw refusal.error
        }
        refusals[host.id] = nil
        // A 30 second margin: a token that expires mid-upload is a failure the
        // retry path would have to cover anyway, and not using it is cheaper.
        if !forceRefresh, let cached = grants[host.id], cached.expires > Date().addingTimeInterval(30) {
            return cached
        }

        var request = URLRequest(url: host.apiURL(path: "/v1/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let (body, response) = try await perform(request, uploading: Data(secret.utf8))
        switch response.statusCode {
        case 200:
            struct TokenResp: Decodable {
                let token: String
                let expiresIn: Int
                let maxBytes: Int
                /// Absent on a daemon older than the endpoint that reports it,
                /// which is why the app asks rather than assumes.
                let features: [String]?
            }
            guard let parsed = try? JSONDecoder.snakeCase.decode(TokenResp.self, from: body) else {
                throw UploadError.server(status: 200)
            }
            let grant = Grant(
                token: parsed.token,
                maxBytes: parsed.maxBytes,
                features: Set(parsed.features ?? []),
                expires: Date().addingTimeInterval(TimeInterval(parsed.expiresIn))
            )
            grants[host.id] = grant
            return grant
        case 401:
            struct ErrResp: Decodable { let attemptsLeft: Int? }
            let attempts = (try? JSONDecoder.snakeCase.decode(ErrResp.self, from: body))?.attemptsLeft
            let error = UploadError.badSecret(attemptsLeft: attempts ?? 0)
            refusals[host.id] = (secret, error)
            throw error
        case 403:
            throw UploadError.unauthorized
        case 404:
            throw UploadError.disabled
        case 429:
            refusals[host.id] = (secret, .lockedOut)
            throw UploadError.lockedOut
        case let status:
            throw UploadError.server(status: status)
        }
    }

    private func put(data: Data, filename: String, host: Host, grant: Grant) async throws -> String {
        var request = URLRequest(url: host.apiURL(path: "/v1/files/\(Self.pathSegment(for: filename))"))
        request.httpMethod = "PUT"
        // Long, because this is a photo over a phone link and the alternative
        // is a timeout the person reads as "it does not work".
        request.timeoutInterval = 300
        request.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (body, response) = try await perform(request, uploading: data)
        switch response.statusCode {
        case 201:
            struct UploadResp: Decodable { let path: String }
            guard let parsed = try? JSONDecoder.snakeCase.decode(UploadResp.self, from: body),
                  !parsed.path.isEmpty
            else { throw UploadError.server(status: 201) }
            return parsed.path
        case 403:
            throw UploadError.unauthorized
        case 404:
            throw UploadError.disabled
        case 413:
            throw UploadError.tooLarge(maxBytes: grant.maxBytes)
        case let status:
            throw UploadError.server(status: status)
        }
    }

    private func perform(_ request: URLRequest, uploading body: Data) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else {
                throw UploadError.transport("unexpected response")
            }
            return (data, http)
        } catch let error as UploadError {
            throw error
        } catch {
            throw UploadError.transport(Self.reason(for: error))
        }
    }

    private static func reason(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nsError.localizedDescription }
        switch nsError.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "host unreachable, check that Tailscale is up"
        case NSURLErrorTimedOut:
            return "upload timed out"
        case NSURLErrorNotConnectedToInternet:
            return "no network"
        default:
            return nsError.localizedDescription
        }
    }

    /// Reduces a file name to one URL path segment.
    ///
    /// The daemon sanitizes again and owns the final name, so this is not the
    /// security boundary. It exists so the request is well formed and so the
    /// name that survives still looks like the file the person picked.
    static func pathSegment(for filename: String) -> String {
        let last = filename.split(separator: "/").last.map(String.init) ?? filename
        let reduced = String(last.prefix(96)).map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-")
                ? character
                : "-"
        }
        let trimmed = String(reduced).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return trimmed.isEmpty ? "file" : trimmed
    }
}

/// One session on a host, as `GET /v1/sessions` reports it.
struct HostSession: Decodable, Identifiable, Hashable {
    let id: String
    let shell: String
    let createdAt: Int
    let attached: Bool
    let idleSecs: Int

    /// Just the shell's basename, because a column is narrow.
    var shellLabel: String { (shell as NSString).lastPathComponent }

    var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
}

/// One file the host has offered, as `GET /v1/outbox` reports it.
struct HostOffer: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let bytes: Int
    let offeredAt: Int
}

private extension JSONDecoder {
    /// The daemon writes snake_case, as the rest of the wire protocol does.
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
