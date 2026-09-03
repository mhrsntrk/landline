import Foundation

/// Which colour scheme the terminal renders in.
///
/// One Dark Pro is the product default (PRODUCT.md pins it as a brand
/// commitment). `matchSystem` is the escape hatch for someone who wants the
/// phone to follow iOS light/dark instead. More palettes get added later, so
/// decoding tolerates raw values this build has never heard of.
enum TerminalColorScheme: String, Codable, CaseIterable, Identifiable, Hashable {
    case oneDarkPro
    case matchSystem

    var id: String { rawValue }

    /// Micro-caps label, already uppercased for the annotation grammar.
    var displayName: String {
        switch self {
        case .oneDarkPro: return "ONE DARK PRO"
        case .matchSystem: return "MATCH SYSTEM"
        }
    }

    /// One sentence a human wrote, for the picker.
    var summary: String {
        switch self {
        case .oneDarkPro: return "The scheme your desktops already use."
        case .matchSystem: return "Follow the phone's light or dark appearance."
        }
    }

    /// A palette written by a newer build must not make an older build refuse
    /// to read the host list; fall back to the default instead of throwing.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TerminalColorScheme(rawValue: raw) ?? .oneDarkPro
    }
}

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

    /// Optional per-host startup command. Empty means "use the machine's own
    /// default login shell". A non-empty value is run by the daemon through the
    /// login shell interactively (`zsh -i -c "<cmd>"`) so aliases and shell
    /// functions resolve, which is how `tmuxon` works.
    var startCommand: String = ""

    /// Terminal colour scheme for this host.
    var colorScheme: TerminalColorScheme = .oneDarkPro

    /// Family name of the face the terminal renders in, e.g. "Berkeley Mono".
    /// Empty means the bundled JetBrains Mono Nerd Font, which is the default
    /// and the only face guaranteed to carry prompt icons.
    ///
    /// A *family* name, not a PostScript name: the regular and bold faces are
    /// picked out of the family by symbolic trait, so a family with only one
    /// weight still works. Stored as a plain string rather than an enum because
    /// the set of installed fonts is whatever configuration profiles the phone
    /// happens to carry; a family that is no longer installed falls back to the
    /// bundled face at render time rather than being rewritten in the store, so
    /// re-installing the profile brings the choice back.
    var fontFamily: String = ""

    // MARK: Daemon-reported cache
    //
    // The daemon is the source of truth (PRODUCT.md); these two are only the
    // last facts it reported in ATTACHED, kept so the index can show what the
    // machine said rather than something the app guessed. Nothing writes them
    // until a session attaches, and nil renders as an em dash.

    /// `shell` from the last ATTACHED response, e.g. "/bin/zsh".
    var lastShell: String?
    /// Wall clock at the last ATTACHED response, used for the session age column.
    var lastAttachedAt: Date?

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

    /// Same origin as `wsURL`, over http(s). Used to probe reachability.
    var httpURL: URL {
        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = hostname
        components.port = Int(port)
        components.path = "/v1/shell"
        return components.url ?? URL(string: "https://invalid.invalid/v1/shell")!
    }

    /// What the index prints in the name column.
    var displayName: String { name.isEmpty ? hostname : name }

    /// Just the shell's basename, because a column is 6 characters wide.
    var shellLabel: String {
        guard let lastShell, !lastShell.isEmpty else { return "—" }
        return (lastShell as NSString).lastPathComponent
    }

    /// Coarse age of the last session, tabular and never wider than 4 glyphs.
    func sessionAgeLabel(now: Date = Date()) -> String {
        guard let lastAttachedAt else { return "—" }
        let seconds = max(0, now.timeIntervalSince(lastAttachedAt))
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

// MARK: - Codable

extension Host {
    enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, useTLS, requireFaceID, lastSessionID
        case startCommand, colorScheme, fontFamily, lastShell, lastAttachedAt
    }

    /// Written by hand, not synthesised, because a `var` with a default still
    /// throws `keyNotFound` under synthesised decoding. Hosts stored by earlier
    /// builds have none of the newer keys, and losing the host list on upgrade
    /// would be unforgivable for a list the user typed in by hand.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let blank = Host()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? blank.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 443
        useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? true
        requireFaceID = try container.decodeIfPresent(Bool.self, forKey: .requireFaceID) ?? false
        lastSessionID = try container.decodeIfPresent(String.self, forKey: .lastSessionID)
        startCommand = try container.decodeIfPresent(String.self, forKey: .startCommand) ?? ""
        colorScheme = try container.decodeIfPresent(TerminalColorScheme.self, forKey: .colorScheme) ?? .oneDarkPro
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
        lastShell = try container.decodeIfPresent(String.self, forKey: .lastShell)
        lastAttachedAt = try container.decodeIfPresent(Date.self, forKey: .lastAttachedAt)
    }

    /// The unit-testable migration path: decode a stored `hosts.json` payload
    /// exactly the way `HostStore` does, so a test can feed it a pre-migration
    /// document and assert the defaults land.
    static func decodeList(from data: Data) throws -> [Host] {
        try JSONDecoder().decode([Host].self, from: data)
    }

    static func encodeList(_ hosts: [Host]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(hosts)
    }
}

// MARK: - Validation

extension Host {
    /// A problem with what the user typed, phrased as problem plus recovery.
    struct ValidationError: Identifiable, Equatable {
        var id: String { field }
        /// Which field to point at.
        let field: String
        let message: String
    }

    static let portRange: ClosedRange<Int> = 1...65535

    /// Empty when the host is safe to save.
    var validationErrors: [ValidationError] {
        var errors: [ValidationError] = []
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespaces)
        if trimmedHostname.isEmpty {
            errors.append(.init(
                field: "hostname",
                message: "No hostname. Enter the machine's tailnet name, the one \(Host.tailnetExample) shape that `tailscale status` prints."
            ))
        } else if trimmedHostname.contains(" ") || trimmedHostname.contains("/") {
            errors.append(.init(
                field: "hostname",
                message: "That hostname has a space or a slash in it. Use the bare name only, no scheme and no path."
            ))
        }
        if !Host.portRange.contains(Int(port)) {
            errors.append(.init(
                field: "port",
                message: "Port \(port) is out of range. Use 1 to 65535; `tailscale serve --https=443` means 443."
            ))
        }
        return errors
    }

    static let tailnetExample = "macbook.tail1234.ts.net"

    var isValid: Bool { validationErrors.isEmpty }
}
