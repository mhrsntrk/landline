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

/// Sends one file to a host's inbox and hands back the absolute path it landed
/// at, which is the only thing the caller wants: the path is what gets typed
/// into the session.
///
/// The two-step exchange (mint a token, then spend it) exists so the unlock
/// secret is argon2-verified once per session rather than once per upload, and
/// so the upload request itself never carries the secret. Tokens live in memory
/// here and nowhere else.
actor FileUploader {
    private struct Grant {
        let token: String
        let maxBytes: Int
        let expires: Date
    }

    /// Per host, because a phone reaches several and a token is minted for one.
    private var grants: [UUID: Grant] = [:]
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

    /// Forgets this host's token. Called when its stored secret changes, so the
    /// next upload does not spend a grant minted with the old one.
    func forget(host: UUID) {
        grants[host] = nil
    }

    // MARK: Internals

    private func token(for host: Host, secret: String, forceRefresh: Bool) async throws -> Grant {
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
            }
            guard let parsed = try? JSONDecoder.snakeCase.decode(TokenResp.self, from: body) else {
                throw UploadError.server(status: 200)
            }
            let grant = Grant(
                token: parsed.token,
                maxBytes: parsed.maxBytes,
                expires: Date().addingTimeInterval(TimeInterval(parsed.expiresIn))
            )
            grants[host.id] = grant
            return grant
        case 401:
            struct ErrResp: Decodable { let attemptsLeft: Int? }
            let attempts = (try? JSONDecoder.snakeCase.decode(ErrResp.self, from: body))?.attemptsLeft
            throw UploadError.badSecret(attemptsLeft: attempts ?? 0)
        case 403:
            throw UploadError.unauthorized
        case 404:
            throw UploadError.disabled
        case 429:
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

private extension JSONDecoder {
    /// The daemon writes snake_case, as the rest of the wire protocol does.
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
