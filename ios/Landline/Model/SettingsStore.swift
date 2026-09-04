import Foundation
import Observation

// MARK: - Scroll speed

/// How far the terminal scrolls for a given amount of finger travel.
///
/// Steps rather than a number, because what is being set is a feel: nobody can
/// predict what "42 points per notch" does to their thumb, but everybody can
/// try the step above and the step below. Each step is a stated multiple of the
/// slowest one, so the label *is* the setting.
///
/// The arithmetic all hangs off `slowestCellHeightsPerNotch`. One notch at 1x
/// costs three cell heights of travel, which is what every build before this one
/// charged, so 1x is exactly the old behaviour and every other step is honestly
/// described as a multiple of it. Deriving the cost from the cell height rather
/// than from a point constant is what makes a 9pt font scroll the same distance
/// per swipe as a 22pt one.
///
/// Raw values are permanent: they are what `settings.json` stores.
enum TerminalScrollSpeed: Int, CaseIterable, Codable, Identifiable, Hashable {
    case x1 = 1
    case x2 = 2
    case x3 = 3
    case x4 = 4
    case x5 = 5

    /// Three cell heights per notch was the shipped speed and is far too slow on
    /// a phone: a thumb's worth of travel buys about a third of a screen. One
    /// cell height per notch is one line of travel per notch, which measured out
    /// at roughly three times the text for the same swipe, so the default moves
    /// to 3x and the old speed stays reachable as 1x.
    static let `default` = TerminalScrollSpeed.x3

    /// Cell heights of finger travel one notch costs at 1x.
    static let slowestCellHeightsPerNotch: CGFloat = 3

    var id: Int { rawValue }

    /// The label printed on the cell, and the whole of what the user has to
    /// understand about the setting.
    var label: String { "\(rawValue)x" }

    /// Cell heights of finger travel one wheel notch costs at this step.
    var cellHeightsPerNotch: CGFloat {
        Self.slowestCellHeightsPerNotch / CGFloat(rawValue)
    }

    /// The end of the range this step sits at, or that it is the shipped
    /// default. Nothing for the steps in between: an annotation on every cell
    /// would be texture rather than marking.
    var endpointNote: String? {
        switch self {
        case .x1: return "SLOWEST"
        case .x5: return "FASTEST"
        case Self.default: return "DEFAULT"
        default: return nil
        }
    }

    /// The setting stated as the measurement it actually is, for the readout
    /// under the row. Two decimals because 3x is 1.00 and 4x is 0.75.
    var travelNote: String {
        String(format: "1 NOTCH / %.2f LINES OF TRAVEL", Double(cellHeightsPerNotch))
    }

    /// A step written by a newer build must not make this build refuse to read
    /// the whole settings file; fall back to the default instead of throwing.
    /// Same rule `TerminalColorScheme` follows for a palette it has never heard
    /// of, and for the same reason.
    init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(Int.self)
        self = raw.flatMap(TerminalScrollSpeed.init(rawValue:)) ?? .default
    }
}

// MARK: - The document on disk

/// `settings.json` as it is actually written: `AppSettings`' keys plus the ones
/// that belong to the terminal gesture rather than to the key bar.
///
/// Flat, not nested, and encoded through `AppSettings` itself rather than beside
/// it, so a file written by the previous build reads back unchanged and a file
/// written by this one is still a valid `AppSettings` document. A missing
/// `scrollSpeed` means "this file predates the setting", which takes the new
/// default; that is the same migration rule `keyBar` already carries.
struct SettingsDocument: Codable, Equatable {
    var app: AppSettings
    var scrollSpeed: TerminalScrollSpeed

    init(app: AppSettings = AppSettings(), scrollSpeed: TerminalScrollSpeed = .default) {
        self.app = app
        self.scrollSpeed = scrollSpeed
    }

    private enum CodingKeys: String, CodingKey { case scrollSpeed }

    init(from decoder: any Decoder) throws {
        app = try AppSettings(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `decodeIfPresent` rather than `decode`, and the speed's own decoder
        // tolerates a value it does not recognise, so neither an old file nor a
        // newer one can cost the user their key bar.
        scrollSpeed = try container.decodeIfPresent(TerminalScrollSpeed.self, forKey: .scrollSpeed)
            ?? .default
    }

    func encode(to encoder: any Encoder) throws {
        try app.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scrollSpeed, forKey: .scrollSpeed)
    }

    static func decode(from data: Data) throws -> SettingsDocument {
        try JSONDecoder().decode(SettingsDocument.self, from: data)
    }

    static func encode(_ document: SettingsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
}

// MARK: - Store

/// Loads and saves the app-wide settings as JSON in Documents, alongside
/// `hosts.json`. Same pattern as `HostStore`, deliberately: one small
/// `@Observable`, one file, written atomically on every mutation.
@Observable
final class SettingsStore {
    private(set) var settings: AppSettings
    /// How far a swipe over the terminal scrolls. App-wide, like the key bar:
    /// it is a property of the thumb, not of the machine at the far end.
    private(set) var scrollSpeed: TerminalScrollSpeed

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("settings.json")
        let document = (try? Data(contentsOf: self.fileURL))
            .flatMap { try? SettingsDocument.decode(from: $0) }
            ?? SettingsDocument()
        settings = document.app
        scrollSpeed = document.scrollSpeed
        settings.keyBar = Self.demoKeyBar ?? settings.keyBar
    }

    /// Debug screenshot hook, the same idiom as `DemoSeed`: a row carrying a
    /// couple of tmux keys, so the bar can be photographed as it is used rather
    /// than as it ships. In memory only, never written back, and compiled out of
    /// release.
    private static var demoKeyBar: [KeyBarKey]? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LANDLINE_DEMO_KEYBAR"] == "tmux" else {
            return nil
        }
        return ["esc", "ctrl", "leader",
                "tmux.new", "tmux.window.1", "tmux.window.2", "tmux.next", "tmux.zoom",
                "arrow.up", "arrow.down", "sym.pipe"].map { KeyBarKey(catalogID: $0) }
        #else
        return nil
        #endif
    }

    // MARK: - Key bar

    var keyBar: [KeyBarKey] { settings.keyBar }

    /// The bar as it will actually draw: unresolvable slots dropped. See
    /// `KeyBarKey.resolved` for why they are dropped here rather than on load.
    var resolvedKeyBar: [ResolvedKey] { settings.keyBar.compactMap(\.resolved) }

    func append(_ key: KeyBarKey) {
        settings.keyBar.append(key)
        save()
    }

    func remove(id: UUID) {
        settings.keyBar.removeAll { $0.id == id }
        save()
    }

    func replace(_ key: KeyBarKey) {
        guard let index = settings.keyBar.firstIndex(where: { $0.id == key.id }) else { return }
        settings.keyBar[index] = key
        save()
    }

    func key(id: UUID) -> KeyBarKey? {
        settings.keyBar.first { $0.id == id }
    }

    /// Drag reordering, the `List` shape.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        settings.keyBar.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// One step along the row. The buttons exist because which keys sit under
    /// the thumb is the whole point of this screen, and a one-handed nudge has
    /// to work without a drag gesture.
    func nudge(id: UUID, by delta: Int) {
        guard let index = settings.keyBar.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard settings.keyBar.indices.contains(target) else { return }
        settings.keyBar.swapAt(index, target)
        save()
    }

    func resetKeyBar() {
        // Fresh ids: the identity of a slot is the slot, not the key in it.
        settings.keyBar = KeyBarKey.defaultLayout.map {
            KeyBarKey(catalogID: $0.catalogID, label: $0.label, sequence: $0.sequence)
        }
        save()
    }

    var isDefaultKeyBar: Bool {
        settings.keyBar.map { [$0.catalogID, $0.label, $0.sequence] }
            == KeyBarKey.defaultLayout.map { [$0.catalogID, $0.label, $0.sequence] }
    }

    // MARK: - Scroll speed

    /// Set from the settings screen. The terminal reads this at the start of
    /// every swipe rather than latching it, so the change is live on the next
    /// gesture and not on the next time the terminal is opened.
    func setScrollSpeed(_ speed: TerminalScrollSpeed) {
        guard speed != scrollSpeed else { return }
        scrollSpeed = speed
        save()
    }

    var isDefaultScrollSpeed: Bool { scrollSpeed == .default }

    // MARK: - Persistence

    private func save() {
        let document = SettingsDocument(app: settings, scrollSpeed: scrollSpeed)
        guard let data = try? SettingsDocument.encode(document) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
