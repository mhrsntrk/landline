import Foundation

/// A machine running `landlined` behind `tailscale serve`.
struct Host: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    /// e.g. "macbook.tail1234.ts.net"
    var hostname: String = ""
    var port: UInt16 = 443
    var useTLS: Bool = true
    var requireFaceID: Bool = false
    /// Last session id returned by ATTACHED, used to resume. Cleared on SESSION_GONE.
    var lastSessionID: String?

    /// The daemon's single WebSocket endpoint (PROTOCOL.md: `GET /v1/shell`).
    var wsURL: URL {
        var components = URLComponents()
        components.scheme = useTLS ? "wss" : "ws"
        components.host = hostname
        components.port = Int(port)
        components.path = "/v1/shell"
        // A malformed hostname can make URL construction fail; fall back to a
        // guaranteed-parseable placeholder so callers do not have to unwrap.
        return components.url ?? URL(string: "wss://invalid.invalid/v1/shell")!
    }
}
