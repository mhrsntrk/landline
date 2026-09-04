import Foundation

// What the special-key row contains, and what each of its keys does.
//
// The layout is app-wide rather than per host, because the row is a keypad: the
// point of arranging it is muscle memory, and muscle memory does not change
// when you reach a different machine. The tmux leader is the opposite and stays
// on the host, because a tmux config does differ per machine.

// MARK: - Action

/// What pressing one key in the bar does.
enum KeyBarAction: Hashable {
    /// Sends these bytes immediately, through the same input path as the
    /// software keyboard, so a latched modifier still folds them.
    case send([UInt8])
    /// Latches instead of sending. The next key is folded, prefixed, or
    /// preceded by the host's leader byte, then the latch clears.
    case latchCtrl
    case latchAlt
    case latchLeader

    var isLatch: Bool {
        if case .send = self { return false }
        return true
    }
}

// MARK: - Catalog

/// One key the bar can be given. The `id` is permanent: it is what a stored
/// layout holds.
struct KeyBarCatalogEntry: Identifiable, Hashable {
    /// Stored in `settings.json`. Never renamed.
    let id: String
    /// What the bar prints on the cell. Short, because a cell is 44pt wide.
    let label: String
    /// The name a person would say, for the row in the picker and for VoiceOver.
    let name: String
    let action: KeyBarAction
}

/// Everything the bar can be built from, grouped the way the picker lists it.
enum KeyBarCatalog {
    struct Group: Identifiable, Hashable {
        /// The micro-caps section title, and the id.
        let id: String
        let entries: [KeyBarCatalogEntry]
    }

    static let groups: [Group] = [
        Group(id: "KEYS", entries: [
            .init(id: "esc", label: "ESC", name: "escape", action: .send([0x1b])),
            .init(id: "tab", label: "TAB", name: "tab", action: .send([0x09])),
            // Forward delete, not backspace: the software keyboard already has
            // backspace, and the key it cannot produce is this one.
            .init(id: "delete", label: "DEL", name: "forward delete", action: .send([0x1b, 0x5b, 0x33, 0x7e])),
            .init(id: "home", label: "HOME", name: "home", action: .send([0x1b, 0x5b, 0x48])),
            .init(id: "end", label: "END", name: "end", action: .send([0x1b, 0x5b, 0x46])),
            .init(id: "pageup", label: "PGUP", name: "page up", action: .send([0x1b, 0x5b, 0x35, 0x7e])),
            .init(id: "pagedown", label: "PGDN", name: "page down", action: .send([0x1b, 0x5b, 0x36, 0x7e])),
        ]),
        Group(id: "MODIFIERS", entries: [
            .init(id: "ctrl", label: "CTRL", name: "control", action: .latchCtrl),
            .init(id: "alt", label: "ALT", name: "alt", action: .latchAlt),
            .init(id: "leader", label: "LDR", name: "leader", action: .latchLeader),
        ]),
        Group(id: "ARROWS", entries: [
            // CSI D/B/A/C. Arrow glyphs, not words: these are the only
            // pictographic labels the bar allows, because every terminal draws
            // them this way.
            .init(id: "arrow.left", label: "\u{2190}", name: "left arrow", action: .send([0x1b, 0x5b, 0x44])),
            .init(id: "arrow.down", label: "\u{2193}", name: "down arrow", action: .send([0x1b, 0x5b, 0x42])),
            .init(id: "arrow.up", label: "\u{2191}", name: "up arrow", action: .send([0x1b, 0x5b, 0x41])),
            .init(id: "arrow.right", label: "\u{2192}", name: "right arrow", action: .send([0x1b, 0x5b, 0x43])),
        ]),
        Group(id: "CONTROL CODES", entries: [
            .init(id: "ctrl.c", label: "^C", name: "control C, interrupt", action: .send([0x03])),
            .init(id: "ctrl.d", label: "^D", name: "control D, end of file", action: .send([0x04])),
            .init(id: "ctrl.z", label: "^Z", name: "control Z, suspend", action: .send([0x1a])),
            .init(id: "ctrl.l", label: "^L", name: "control L, clear", action: .send([0x0c])),
            .init(id: "ctrl.r", label: "^R", name: "control R, reverse search", action: .send([0x12])),
        ]),
        Group(id: "PUNCTUATION", entries: symbols.map { symbol in
            .init(id: "sym.\(symbol.id)",
                  label: String(symbol.character),
                  name: symbol.name,
                  action: .send(Array(String(symbol.character).utf8)))
        }),
    ]

    /// The punctuation a shell needs and a phone keyboard buries a layer deep.
    private static let symbols: [(id: String, character: Character, name: String)] = [
        ("tilde", "~", "tilde"),
        ("pipe", "|", "pipe"),
        ("slash", "/", "slash"),
        ("hyphen", "-", "hyphen"),
        ("underscore", "_", "underscore"),
        ("equal", "=", "equals"),
        ("plus", "+", "plus"),
        ("colon", ":", "colon"),
        ("semicolon", ";", "semicolon"),
        ("quote", "'", "single quote"),
        ("doublequote", "\"", "double quote"),
        ("backtick", "`", "backtick"),
        ("dollar", "$", "dollar"),
        ("ampersand", "&", "ampersand"),
        ("asterisk", "*", "asterisk"),
        ("lparen", "(", "open paren"),
        ("rparen", ")", "close paren"),
        ("lbracket", "[", "open bracket"),
        ("rbracket", "]", "close bracket"),
        ("lbrace", "{", "open brace"),
        ("rbrace", "}", "close brace"),
        ("lessthan", "<", "less than"),
        ("greaterthan", ">", "greater than"),
    ]

    static let all: [KeyBarCatalogEntry] = groups.flatMap(\.entries)

    private static let index: [String: KeyBarCatalogEntry] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func entry(id: String) -> KeyBarCatalogEntry? { index[id] }
}

// MARK: - Stored key

/// One slot in the stored layout: either a catalog key, or a key the user wrote
/// themselves.
///
/// Custom keys keep their *source text* rather than their bytes, so the editor
/// can reopen what was typed and the syntax stays the thing being edited. The
/// bytes are re-derived on every read, which costs nothing and means a stored
/// key can never disagree with what it says it does.
struct KeyBarKey: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    /// A `KeyBarCatalog` id, or nil for a custom key.
    var catalogID: String?
    /// Custom keys only: what the cell prints.
    var label: String = ""
    /// Custom keys only: the bytes, in `KeySequence` syntax.
    var sequence: String = ""

    var isCustom: Bool { catalogID == nil }

    init(id: UUID = UUID(), catalogID: String? = nil, label: String = "", sequence: String = "") {
        self.id = id
        self.catalogID = catalogID
        self.label = label
        self.sequence = sequence
    }

    /// Tolerant on purpose, for the same reason `Host` is: a layout written by a
    /// newer build must not make this one refuse to read the file.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        catalogID = try container.decodeIfPresent(String.self, forKey: .catalogID)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        sequence = try container.decodeIfPresent(String.self, forKey: .sequence) ?? ""
    }

    /// The default row: exactly the keys the bar has always had, plus the
    /// leader, so an existing user opens this build and sees no regression.
    static let defaultLayout: [KeyBarKey] = [
        "esc", "tab",
        "ctrl", "alt", "leader",
        "arrow.left", "arrow.down", "arrow.up", "arrow.right",
        "sym.tilde", "sym.pipe", "sym.slash", "sym.hyphen",
    ].map { KeyBarKey(catalogID: $0) }
}

// MARK: - Resolution

/// A key with its bytes already worked out, which is all the bar itself needs.
struct ResolvedKey: Identifiable, Hashable {
    let id: UUID
    let label: String
    let accessibility: String
    let action: KeyBarAction
}

extension KeyBarKey {
    /// The key as the bar will draw it, or nil when it cannot be drawn: a
    /// catalog id this build has never heard of, or a custom sequence that no
    /// longer parses. Both are dropped from the *rendered* bar and kept in the
    /// stored file, so a downgrade-then-upgrade does not quietly delete a row,
    /// and a key that would send nothing is never offered to a thumb.
    var resolved: ResolvedKey? {
        if let catalogID {
            guard let entry = KeyBarCatalog.entry(id: catalogID) else { return nil }
            return ResolvedKey(id: id, label: entry.label,
                               accessibility: entry.name, action: entry.action)
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, let bytes = KeySequence.bytes(sequence) else { return nil }
        return ResolvedKey(id: id, label: trimmedLabel,
                           accessibility: "\(trimmedLabel), custom key", action: .send(bytes))
    }

    /// The name the settings list prints for this key.
    var settingsName: String {
        if let catalogID {
            return KeyBarCatalog.entry(id: catalogID)?.name ?? "unknown key"
        }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "unnamed custom key" : trimmed
    }

    /// The measured fact under the name: what the key actually puts on the wire.
    var settingsDetail: String {
        switch resolved?.action {
        case .send(let bytes): return KeySequence.hex(bytes)
        case .latchCtrl, .latchAlt, .latchLeader: return "LATCHES"
        case .none: return "UNRESOLVED"
        }
    }
}

// MARK: - Settings document

/// Everything the app stores that is not about one machine. One key today; the
/// shape exists so the second one does not need a migration.
struct AppSettings: Codable, Equatable {
    var keyBar: [KeyBarKey] = KeyBarKey.defaultLayout

    init(keyBar: [KeyBarKey] = KeyBarKey.defaultLayout) {
        self.keyBar = keyBar
    }

    /// A missing `keyBar` means "this file predates the setting", which is the
    /// default row. An *empty* one means the user removed every key, which is a
    /// choice and is kept.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyBar = try container.decodeIfPresent([KeyBarKey].self, forKey: .keyBar)
            ?? KeyBarKey.defaultLayout
    }

    static func decode(from data: Data) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: data)
    }

    static func encode(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }
}
