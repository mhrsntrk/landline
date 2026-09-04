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
    /// Sends this sequence immediately, through the same input path as the
    /// software keyboard, so a latched modifier still folds it.
    ///
    /// A template rather than bytes, because a key written with `\L` cannot know
    /// its own bytes: the leader is a per-host fact and this layout is app-wide.
    /// The bar resolves it against the host it is drawn on, at the moment the
    /// key is pressed.
    case send(KeySequence.Template)
    /// Latches instead of sending. The next key is folded, prefixed, or
    /// preceded by the host's leader byte, then the latch clears.
    case latchCtrl
    case latchAlt
    case latchLeader

    /// A key whose bytes are fixed. Most of the catalog is this, and writing it
    /// out is what keeps those entries readable as the byte strings they are.
    static func send(_ bytes: [UInt8]) -> KeyBarAction {
        .send(KeySequence.Template(bytes))
    }

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
    /// Holding this key repeats it, at the rate `KeyRepeatState` sets.
    ///
    /// Off for everything by default, and that is the decision rather than an
    /// oversight. Repeat is only wanted where the key is a *motion* — one more
    /// character gone, one more line back — and it is actively dangerous
    /// everywhere else: a held `^C` is a signal storm, a held `^D` closes the
    /// shell and then logs the session out, a held tmux leader key opens twenty
    /// windows, and a held `~` types a line of tildes into a live prompt. So the
    /// set is backspace, forward delete, the four arrows, and page up and down.
    /// Custom keys never repeat, because nothing here can know what they do.
    var repeats: Bool = false
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
            // The software keyboard has a backspace of its own, so this one is
            // not about reaching the byte. It is about the *rate*: every 0x7F is
            // a round trip to the daemon and the shell echoes the erase back, so
            // the system key deletes at the speed of the link. This bar owns its
            // own repeat clock (`KeyRepeatState`), which is the one thing the
            // system keyboard will not give up.
            .init(id: "backspace", label: "BKSP", name: "backspace", action: .send([0x7f]), repeats: true),
            // Forward delete, which the software keyboard cannot produce at all.
            .init(id: "delete", label: "DEL", name: "forward delete", action: .send([0x1b, 0x5b, 0x33, 0x7e]), repeats: true),
            .init(id: "home", label: "HOME", name: "home", action: .send([0x1b, 0x5b, 0x48])),
            .init(id: "end", label: "END", name: "end", action: .send([0x1b, 0x5b, 0x46])),
            .init(id: "pageup", label: "PGUP", name: "page up", action: .send([0x1b, 0x5b, 0x35, 0x7e]), repeats: true),
            .init(id: "pagedown", label: "PGDN", name: "page down", action: .send([0x1b, 0x5b, 0x36, 0x7e]), repeats: true),
        ]),
        // Second, ahead of everything except the plain keys, because this is
        // what the row is actually used for: a tmux session with a status bar,
        // and windows being switched all day. Buried at the bottom of the
        // catalog these would not be found.
        Group(id: "TMUX", entries: tmuxEntries),
        Group(id: "MODIFIERS", entries: [
            .init(id: "ctrl", label: "CTRL", name: "control", action: .latchCtrl),
            .init(id: "alt", label: "ALT", name: "alt", action: .latchAlt),
            .init(id: "leader", label: "LDR", name: "leader", action: .latchLeader),
        ]),
        Group(id: "ARROWS", entries: [
            // CSI D/B/A/C. Arrow glyphs, not words: these are the only
            // pictographic labels the bar allows, because every terminal draws
            // them this way.
            // Arrows repeat: holding left walks the cursor across a long path
            // and holding up walks back through history, which is the same
            // motion a desktop keyboard gives and the reason repeat exists.
            .init(id: "arrow.left", label: "\u{2190}", name: "left arrow", action: .send([0x1b, 0x5b, 0x44]), repeats: true),
            .init(id: "arrow.down", label: "\u{2193}", name: "down arrow", action: .send([0x1b, 0x5b, 0x42]), repeats: true),
            .init(id: "arrow.up", label: "\u{2191}", name: "up arrow", action: .send([0x1b, 0x5b, 0x41]), repeats: true),
            .init(id: "arrow.right", label: "\u{2192}", name: "right arrow", action: .send([0x1b, 0x5b, 0x43]), repeats: true),
        ]),
        // The answer to a held backspace that nobody thinks of on a phone: one
        // keystroke instead of forty. Every one of these is a readline default,
        // so they work unchanged in zsh, in bash, and at Claude Code's prompt.
        // None of them repeats: `^U` and `^A` are idempotent, and a held `^W`
        // eating a whole command line is exactly the accident this group exists
        // to prevent.
        Group(id: "LINE EDITING", entries: [
            .init(id: "ctrl.w", label: "^W", name: "control W, delete word before the cursor", action: .send([0x17])),
            .init(id: "ctrl.u", label: "^U", name: "control U, kill to the start of the line", action: .send([0x15])),
            .init(id: "ctrl.k", label: "^K", name: "control K, kill to the end of the line", action: .send([0x0b])),
            // `^A` is 0x01, which is also what `set -g prefix C-a` binds. On a
            // host configured that way tmux eats this key and it never reaches
            // readline; that host wants `^E` plus the arrows, or tmux's own
            // `prefix a` passthrough. The byte is correct either way, and
            // inventing a different one would be worse.
            .init(id: "ctrl.a", label: "^A", name: "control A, start of line", action: .send([0x01])),
            .init(id: "ctrl.e", label: "^E", name: "control E, end of line", action: .send([0x05])),
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

    /// One tap for what is otherwise a latch plus a keystroke.
    ///
    /// Every one of these is written in `KeySequence` syntax with `\L` standing
    /// in for the prefix, so the same bar is correct on a machine running
    /// `set -g prefix C-a` and on one left at tmux's `C-b`. Nothing here
    /// hardcodes a prefix byte, which is the whole point: the layout is
    /// app-wide, the leader is per host.
    ///
    /// Labels carry the `L` because the cell is 44pt and a bare `c` beside the
    /// punctuation keys reads as the letter c. `Lc` reads as leader-then-c, and
    /// wears the same three letters as the `LDR` latch it stands for. The name a
    /// person would say stays in the catalog list and in VoiceOver, where there
    /// is room for it.
    private static let tmuxEntries: [KeyBarCatalogEntry] = ([
        ("new", "c", "new window", "\\Lc"),
        ("next", "n", "next window", "\\Ln"),
        ("prev", "p", "previous window", "\\Lp"),
        ("last", "l", "last window", "\\Ll"),
        ("list", "w", "list windows", "\\Lw"),
        ("split.vertical", "%", "split vertical", "\\L%"),
        ("split.horizontal", "\"", "split horizontal", "\\L\""),
        ("zoom", "z", "zoom pane", "\\Lz"),
        ("detach", "d", "detach", "\\Ld"),
    ] + (1...9).map { number in
        // The direct answer to "switch to that window", which is the thing the
        // status bar is being read for in the first place.
        ("window.\(number)", "\(number)", "window \(number)", "\\L\(number)")
    }).map { entry in
        KeyBarCatalogEntry(id: "tmux.\(entry.0)",
                           label: "L\(entry.1)",
                           name: "tmux \(entry.2)",
                           action: .send(sequence(entry.3)))
    }

    /// A catalog entry written in the user's own syntax. An empty template is
    /// unreachable — every string above is asserted in `KeyBarLayoutTests` — and
    /// an empty one would draw a key that sends nothing rather than crash a
    /// running app.
    private static func sequence(_ text: String) -> KeySequence.Template {
        KeySequence.template(text) ?? KeySequence.Template([])
    }

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
    /// Holding the cell repeats the key. See `KeyBarCatalogEntry.repeats` for
    /// which keys earn this and why the rest do not.
    var repeats: Bool = false
}

// MARK: - Press and hold

/// The press-and-hold repeat clock, as a pure function of a clock reading.
///
/// This exists because the latency it is answering cannot be removed. Every
/// `0x7F` is a round trip to the daemon and the shell echoes the erase back, so
/// a held system backspace deletes at the speed of the link rather than at the
/// speed of the keyboard, and no amount of local cleverness changes that. What
/// *can* change is how many keystrokes one hold is worth, and since this app
/// draws its own keypad it owns the repeat rate outright, which the system
/// keyboard will never hand over.
///
/// Clock-free on purpose: every entry point takes `now`, so the four things that
/// decide whether a hold feels right — the initial delay, the repeat interval,
/// that a release stops it, and that a finger leaving the cell stops it too —
/// are testable without a device, a timer, or a running run loop.
struct KeyRepeatState: Equatable {
    /// Long enough that a normal tap never repeats, short enough that a hold
    /// does not feel stuck. Roughly what iOS itself uses.
    static let initialDelay: TimeInterval = 0.4
    /// 25 a second, which is already faster than the system keyboard.
    static let interval: TimeInterval = 0.04
    /// 50 a second, once the hold has clearly been deliberate for a while. This
    /// is the acceleration: a short hold nudges, a long one sweeps.
    static let fastInterval: TimeInterval = 0.02
    /// Repeats at the slow rate before the fast one takes over. Eight repeats at
    /// 40ms is about a third of a second of holding past the initial delay.
    static let accelerateAfter = 8
    /// The most repeats one `due(now:)` may hand back. A stalled main thread — a
    /// 4 MiB `cat` landing mid-hold — must not be paid back as forty backspaces
    /// in one frame.
    static let maxCatchUp = 4

    private(set) var isHeld = false
    /// How many repeats this hold has produced. Survives the release, so the
    /// release can tell a tap from a hold and not send one extra key.
    private(set) var repeats = 0
    private var dueAt: TimeInterval = 0

    /// The interval owed after `repeats` repeats have already gone out.
    static func interval(afterRepeats repeats: Int) -> TimeInterval {
        repeats >= accelerateAfter ? fastInterval : interval
    }

    /// The finger went down. Nothing is sent here: the tap itself is the
    /// button's own business, and repeating starts only after `initialDelay`.
    mutating func press(now: TimeInterval) {
        isHeld = true
        repeats = 0
        dueAt = now + Self.initialDelay
    }

    /// The finger came up, or left the cell. Same answer either way, which is
    /// the point: a key that keeps firing after the thumb has slid off it is
    /// worse than one that does not repeat at all.
    mutating func release() {
        isHeld = false
    }

    /// How many repeats are owed at `now`, advancing the schedule by that many.
    mutating func due(now: TimeInterval) -> Int {
        guard isHeld else { return 0 }
        var count = 0
        while now >= dueAt && count < Self.maxCatchUp {
            count += 1
            repeats += 1
            dueAt += Self.interval(afterRepeats: repeats)
        }
        // Whatever the catch-up ceiling refused is dropped rather than carried:
        // the schedule restarts from now, so a stall costs keystrokes instead of
        // producing a burst after it.
        if count == Self.maxCatchUp, now >= dueAt {
            dueAt = now + Self.interval(afterRepeats: repeats)
        }
        return count
    }

    /// True once this hold has sent at least one repeat, which is how the
    /// release knows not to send one more.
    var didRepeat: Bool { repeats > 0 }
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
                               accessibility: entry.name, action: entry.action,
                               repeats: entry.repeats)
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        // The template, not the bytes: a sequence written with `\L` only becomes
        // bytes once the bar knows which host it is drawn on. Failing to parse
        // still drops the key, exactly as before.
        guard !trimmedLabel.isEmpty,
              let template = KeySequence.template(sequence),
              !template.isEmpty else { return nil }
        return ResolvedKey(id: id, label: trimmedLabel,
                           accessibility: "\(trimmedLabel), custom key", action: .send(template))
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
    /// A leader slot prints as `LDR` rather than as a byte, because these
    /// settings are app-wide and have no host to ask.
    var settingsDetail: String {
        switch resolved?.action {
        case .send(let template): return KeySequence.hex(template)
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
