import Foundation

/// A piece of text kept to be typed later.
///
/// The phone keyboard is the bottleneck this app cannot fix. A long command is
/// slow to type, easy to get wrong, and painful to correct with no arrow keys,
/// and an agent prompt is worse: it is prose, it is long, and it is the thing
/// people increasingly want to send from a phone. So the app keeps the text and
/// the thumb picks it.
///
/// App-wide rather than per host, for the same reason the key bar is: what you
/// want to type does not change when you reach a different machine.
struct Snippet: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    /// What the picker lists. Empty falls back to the first line of the body,
    /// because naming a snippet is a chore and skipping it should not cost a
    /// blank row.
    var name: String = ""
    /// The text, verbatim. Newlines included, which is the point: a snippet can
    /// be several commands.
    var text: String = ""
    /// Whether inserting it should also press return.
    ///
    /// Off by default, and that is the safety rather than an oversight. A
    /// snippet lands at whatever prompt happens to be there, which might be a
    /// root shell, a confirmation, or an editor in insert mode. Text is
    /// recoverable; text plus a newline has already happened.
    var runsImmediately: Bool = false

    init(id: UUID = UUID(), name: String = "", text: String = "", runsImmediately: Bool = false) {
        self.id = id
        self.name = name
        self.text = text
        self.runsImmediately = runsImmediately
    }

    /// Tolerant on purpose, like `KeyBarKey`: a file written by a newer build
    /// must not make this one refuse to read the list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        runsImmediately = try container.decodeIfPresent(Bool.self, forKey: .runsImmediately) ?? false
    }

    /// The row's title: the name, or the first line of the text.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let condensed = firstLine.trimmingCharacters(in: .whitespaces)
        return condensed.isEmpty ? "untitled" : condensed
    }

    /// One line of the body for the row's second line, with newlines shown
    /// rather than silently flattened: a snippet that runs three commands looks
    /// nothing like one that runs a long one, and the row should say which.
    var summary: String {
        let lines = text.split(separator: "\n").count
        let condensed = text
            .replacingOccurrences(of: "\n", with: " \u{23CE} ")
            .trimmingCharacters(in: .whitespaces)
        let prefix = lines > 1 ? "\(lines) LINES / " : ""
        return prefix + condensed
    }

    /// Whether this is worth storing. A snippet with no text types nothing.
    var isUsable: Bool { !text.isEmpty }

    /// The bytes this puts on the wire.
    ///
    /// Wrapped in bracketed paste when the far end asked for it, exactly as an
    /// inserted file path is (`PathInsertion`), and for the same reason: a
    /// prompt that submits on newline must see a paste rather than typing, or a
    /// three-line snippet becomes three commands nobody reviewed.
    func bytes(bracketedPaste: Bool) -> [UInt8] {
        let body = Array(text.utf8)
        guard !body.isEmpty else { return [] }
        var out: [UInt8] = []
        if bracketedPaste {
            out += [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] // ESC [ 200 ~
            out += body
            out += [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e] // ESC [ 201 ~
        } else {
            out += body
        }
        // Outside the brackets on purpose: inside, it is text being pasted, and
        // the whole point of asking is that it should be pressed.
        if runsImmediately { out.append(0x0d) }
        return out
    }
}
