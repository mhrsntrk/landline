import Foundation

/// Which colour scheme the terminal renders in.
///
/// One Dark Pro is the product default (PRODUCT.md pins it as a brand
/// commitment) and stays first in the list. The rest are the schemes this
/// app's audience already reads on their own machines, each transcribed from
/// its own repository — see `TerminalPalette` for the hexes and the citations.
/// `matchSystem` is the escape hatch for someone who wants the phone to follow
/// iOS light/dark instead, and it sorts last because it is a rule rather than
/// a palette.
///
/// Only the terminal is themed. The app's own chrome is One Dark Pro whatever
/// this says, because DESIGN.md's chrome tokens carry a measured contrast floor
/// that is calibrated against that one ground.
///
/// Raw values are permanent: they are what `hosts.json` stores. Decoding
/// tolerates raw values this build has never heard of, so a host written by a
/// newer build reads back as the default rather than losing the whole list.
enum TerminalColorScheme: String, Codable, CaseIterable, Identifiable, Hashable {
    case oneDarkPro
    case catppuccinMocha
    case tokyoNight
    case gruvboxDark
    case dracula
    case nord
    case solarizedDark
    case rosePine
    case catppuccinLatte
    case matchSystem

    var id: String { rawValue }

    /// Micro-caps label, already uppercased for the annotation grammar.
    var displayName: String {
        switch self {
        case .oneDarkPro: return "ONE DARK PRO"
        case .catppuccinMocha: return "CATPPUCCIN MOCHA"
        case .tokyoNight: return "TOKYO NIGHT"
        case .gruvboxDark: return "GRUVBOX DARK"
        case .dracula: return "DRACULA"
        case .nord: return "NORD"
        case .solarizedDark: return "SOLARIZED DARK"
        case .rosePine: return "ROSÉ PINE"
        case .catppuccinLatte: return "CATPPUCCIN LATTE"
        case .matchSystem: return "MATCH SYSTEM"
        }
    }

    /// Whether this scheme paints a light ground. Only used to warn, in words,
    /// on the one row that will be blinding at 3am; `matchSystem` is neither
    /// until the phone answers, so it reports false.
    var isLight: Bool { self == .catppuccinLatte }

    /// One sentence a human wrote, for the picker.
    var summary: String {
        switch self {
        case .oneDarkPro:
            return "The scheme your desktops already use, and the app's own."
        case .catppuccinMocha:
            return "Catppuccin's darkest flavour, the one most setups are running right now."
        case .tokyoNight:
            return "Cold blues on near-black, the way the city looks from a plane."
        case .gruvboxDark:
            return "Retro groove: warm, low-saturation, easy on tired eyes."
        case .dracula:
            return "High-contrast pastels on slate. The loudest scheme here."
        case .nord:
            return "Arctic blue-greys, deliberately quiet. Nothing in it shouts."
        case .solarizedDark:
            return "Ethan Schoonover's precision palette. Low contrast on purpose."
        case .rosePine:
            return "Muted pine and rose. Soho vibes, as its authors put it."
        case .catppuccinLatte:
            return "Light ground. For sunlight, not for bed."
        case .matchSystem:
            return "Follow the phone: One Dark Pro in dark, One Light in light."
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

    /// Optional per-host startup command, written as one step per line. Empty
    /// means "use the machine's own default login shell". The steps are joined
    /// with `&&` into the single `cmd` string ATTACH carries, and the daemon
    /// runs that through the login shell interactively (`zsh -l -i -c "<cmd>"`)
    /// so aliases and shell functions resolve.
    ///
    var startCommand: String = ""

    /// Terminal colour scheme for this host.
    var colorScheme: TerminalColorScheme = .oneDarkPro

    /// Family name of the face the terminal renders in, e.g. "Menlo".
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

    /// Point size the terminal renders at, or 0 for "use the app default".
    ///
    /// Per-host for the same reason `colorScheme` and `fontFamily` are: a phone
    /// held at arm's length against a laptop screen wants a different size than
    /// the same phone reading a build log in bed, and the machine you are on is
    /// what decides which of those it is. 0 rather than 13 is the default so an
    /// upgraded host keeps whatever the pinch gesture last left in the app-wide
    /// setting, instead of silently jumping to 13 on first launch of this build.
    ///
    /// `Double` rather than `CGFloat` because this is a stored model value and
    /// `Codable` on `CGFloat` goes through `NSNumber`; the render-time clamp to
    /// 9...22 lives in `TerminalFont.size(forHost:)`.
    var fontSize: Double = 0

    /// This machine's tmux prefix, in tmux's own notation: `C-b`, `C-a`,
    /// `C-Space`, `C-\`, or anything else of the `C-<key>` shape.
    ///
    /// Per host rather than app-wide, because a tmux config belongs to the
    /// machine: one box can be running the stock `C-b` while another has
    /// `set -g prefix C-a` with `C-b` unbound, and a leader key that is right on
    /// one of them and silently wrong on the other is worse than none.
    ///
    /// C-b is the default only because it is tmux's own. Nothing in the app
    /// hardcodes it; `LeaderKey.byte(for:)` resolves whatever is stored, and a
    /// notation that does not resolve disables the LDR key rather than guessing.
    var leaderKey: String = LeaderKey.default

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

    /// Debug screenshot hook, the same idiom as `DemoSeed`: where a demo seed
    /// actually dials, whatever endpoint it *prints*.
    ///
    /// A store frame of the iPad has to show a tailnet name, because the header
    /// band prints `ENDPOINT` and the index row prints `hostname:port`, and a
    /// listing for a Tailscale client that advertises `127.0.0.1:7788` is
    /// telling the reader the wrong thing about the product. The session behind
    /// it still has to be real, and the only daemon a simulator can reach is
    /// the harness one on this machine. So `LANDLINE_DEMO_ENDPOINT=host:port`
    /// redirects every connection there, in plain ws, while the model keeps the
    /// name it displays. Compiled out of release, and inert without the
    /// variable, so a real install can never be redirected anywhere.
    ///
    /// The variable names the host it applies to
    /// (`LANDLINE_DEMO_ENDPOINT=studio.tail4f1a.ts.net@127.0.0.1:7788`) rather
    /// than redirecting everything, because the index probes every row for
    /// reachability and a blanket redirect would draw a filled status square on
    /// machines that do not exist.
    private var demoEndpoint: (host: String, port: Int)? {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["LANDLINE_DEMO_ENDPOINT"],
              let at = value.firstIndex(of: "@"),
              String(value[value.startIndex..<at]) == hostname
        else { return nil }
        let endpoint = value[value.index(after: at)...]
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = Int(endpoint[endpoint.index(after: colon)...])
        else { return nil }
        return (String(endpoint[endpoint.startIndex..<colon]), port)
        #else
        return nil
        #endif
    }

    /// The daemon's single WebSocket endpoint (PROTOCOL.md: `GET /v1/shell`).
    var wsURL: URL {
        var components = URLComponents()
        components.scheme = useTLS ? "wss" : "ws"
        components.host = hostname
        components.port = Int(port)
        components.path = "/v1/shell"
        if let demo = demoEndpoint {
            components.scheme = "ws"
            components.host = demo.host
            components.port = demo.port
        }
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
        if let demo = demoEndpoint {
            components.scheme = "http"
            components.host = demo.host
            components.port = demo.port
        }
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
        case startCommand, colorScheme, fontFamily, fontSize, leaderKey
        case lastShell, lastAttachedAt
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
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0
        leaderKey = try container.decodeIfPresent(String.self, forKey: .leaderKey) ?? LeaderKey.default
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

// MARK: - Startup chain
//
// A startup command written as steps, the way a person writes one down:
//
//     1.  cd ~/project
//     2.  tmux new -A -d -s main
//     3.  tmux attach -t main
//
// Stored as one newline-separated `String` (see `Host.startCommand`) and sent
// as one `&&`-joined `cmd`. `&&` rather than `;` because a failed step must
// stop the chain: a `cd` that failed has to prevent the steps after it from
// running in the wrong directory.

/// Turning what the user wrote into what the daemon runs, and back.
