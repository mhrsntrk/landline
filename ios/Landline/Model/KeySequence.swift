import Foundation

// Turning what a person writes down into the bytes a terminal actually reads.
//
// Three related jobs live here, and they share one table on purpose:
//
//   * `ControlFold`  — what Ctrl plus a key produces.
//   * `LeaderKey`    — a tmux prefix written in tmux's own notation (`C-a`).
//   * `KeySequence`  — the little syntax a custom key's bytes are written in.
//
// All three are pure functions over strings and bytes, with no SwiftUI and no
// I/O, because every one of them is a place where being *almost* right sends
// the wrong byte to a live shell and says nothing about it.

// MARK: - Control fold

enum ControlFold {
    /// The fold applied to the first byte of a payload while CTRL is latched.
    ///
    /// Kept exactly as `TerminalScreen.sendUserInput` has always applied it, so
    /// extracting it changed no key's behaviour. It is deliberately narrower
    /// than `byte(forControlCharacter:)`: this one runs over arbitrary typed
    /// bytes, including whole multi-byte payloads, and must leave anything it
    /// does not recognise alone.
    static func fold(firstByte byte: UInt8) -> UInt8 {
        switch byte {
        case 0x20:
            // Ctrl-Space is NUL, which the mask alone would not produce.
            return 0x00
        case 0x3f...0x7f:
            // @ A..Z [ \ ] ^ _ and the lowercase run: k & 0x1f.
            return byte & 0x1f
        default:
            return byte
        }
    }

    /// The byte Ctrl plus one written character stands for, or nil when that
    /// character has no control code.
    ///
    /// This is the table a *human writing a key down* means: `^?` is DEL, the
    /// way every terminal sends it, rather than the 0x1F that a bare `& 0x1f`
    /// would produce. Nothing typed at a live shell goes through here — only
    /// notation being parsed — so the two tables are allowed to differ and the
    /// more correct one belongs where a person is reading it back.
    static func byte(forControlCharacter character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7a: return ascii - 0x60   // a-z
        case 0x41...0x5a: return ascii - 0x40   // A-Z
        case 0x40: return 0x00                  // @  -> NUL
        case 0x5b...0x5f: return ascii - 0x40   // [ \ ] ^ _
        case 0x3f: return 0x7f                  // ?  -> DEL
        case 0x20: return 0x00                  // space -> NUL
        default: return nil
        }
    }
}

// MARK: - Leader key

/// A tmux prefix, written the way tmux writes it and resolved to the one byte
/// it actually sends.
///
/// Ctrl-B is the default here only because it is tmux's own default. It is not
/// wired in anywhere: the owner of this app runs `set -g prefix C-a` with `C-b`
/// unbound, and a build that assumed C-b would silently do nothing on his
/// machines. Every path reads the host's stored notation and resolves it.
enum LeaderKey {
    /// tmux's own default, and therefore this app's.
    static let `default` = "C-b"

    /// The prefixes worth offering as rows. Anything else is typed in.
    static let presets: [String] = ["C-b", "C-a", "C-Space", "C-\\", "C-o"]

    /// The byte a notation resolves to, or nil when it is not a prefix this
    /// understands. Strict `C-<key>` on purpose: `M-x` is a real tmux notation
    /// for a *binding* but not for a prefix byte, and accepting it here would
    /// promise something the wire cannot carry.
    static func byte(for notation: String) -> UInt8? {
        let trimmed = notation.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }
        guard trimmed.lowercased().hasPrefix("c-") else { return nil }
        let rest = String(trimmed.dropFirst(2))
        if rest.lowercased() == "space" { return 0x00 }
        guard rest.count == 1, let character = rest.first else { return nil }
        return ControlFold.byte(forControlCharacter: character)
    }

    /// `0x01`. The one fact that makes a wrong prefix visible instead of silent.
    ///
    /// For a `llValue` readout, where the string is printed as typed.
    static func hex(for notation: String) -> String? {
        byte(for: notation).map { String(format: "0x%02X", $0) }
    }

    /// `BYTE 01`, for a micro-caps slot. `MicroLabel` uppercases what it is
    /// given, which would turn `0x01` into `0X01` — a notation nobody writes.
    /// So the annotation grammar gets a form that survives being uppercased.
    static func byteLabel(for notation: String) -> String {
        guard let byte = byte(for: notation) else { return "BYTE \(unresolvedHex)" }
        return String(format: "BYTE %02X", byte)
    }

    static func isValid(_ notation: String) -> Bool { byte(for: notation) != nil }

    /// What to print when the stored notation does not resolve.
    static let unresolvedHex = "——"
}

// MARK: - Latches

/// The three sticky modifiers, and the one function that turns them plus a
/// keypress into the bytes that leave.
///
/// It lives in the model rather than inside `TerminalScreen` so it can be tested
/// as what it is — a state machine — instead of only being reachable through a
/// SwiftUI view. Composition order and the snapshot-before-clear rule are the
/// two things it exists to get right; both have been wrong here before.
struct LatchState: Equatable {
    var ctrl = false
    var alt = false
    var leader = false

    var isAnyArmed: Bool { ctrl || alt || leader }

    mutating func clear() {
        ctrl = false
        alt = false
        leader = false
    }

    /// Consume the armed latches and produce the bytes for one keypress.
    ///
    /// In the order they leave:
    ///
    ///   1. Leader emits the host's prefix byte **on its own** — unfolded and
    ///      unprefixed. It is a key tmux reads and then stops reading, so
    ///      folding it would send a different prefix.
    ///   2. Ctrl folds the first byte of the payload.
    ///   3. Alt puts ESC in front of the folded payload, not in front of the
    ///      prefix, so Leader + Alt + `x` is `<prefix> ESC x`.
    ///
    /// So Leader + Ctrl + `o` under `set -g prefix C-a` is `01 0F`, which is
    /// exactly what the binding `C-a C-o` means.
    ///
    /// Every latch is read out of `self` before any is cleared, and all three
    /// clear together: reading one after clearing another is a read-after-write
    /// on the same SwiftUI update pass, which is how Ctrl+Alt once lost its ESC.
    ///
    /// `leaderByte` nil means the host's stored notation does not resolve. The
    /// leader then contributes nothing rather than guessing at C-b, which is
    /// also why the LDR key is disabled in that state.
    mutating func consume(_ payload: [UInt8], leaderByte: UInt8?) -> [UInt8] {
        guard !payload.isEmpty else { return [] }

        let leader = self.leader
        let ctrl = self.ctrl
        let alt = self.alt
        clear()

        var body = payload
        if ctrl {
            body[0] = ControlFold.fold(firstByte: body[0])
        }

        var out: [UInt8] = []
        if leader, let leaderByte {
            out.append(leaderByte)
        }
        if alt {
            // Alt is the ESC prefix, which is what every terminal actually
            // sends for Meta.
            out.append(0x1b)
        }
        out.append(contentsOf: body)
        return out
    }
}

// MARK: - Custom key sequences

/// The syntax a custom key's bytes are written in, and the parser that refuses
/// anything it cannot resolve.
///
/// A custom key that silently sends the wrong bytes is worse than no custom key
/// at all, so this parser has exactly two outcomes — a byte string, or a
/// sentence saying what is wrong with what was typed — and the editor will not
/// save a key that produced the second one.
enum KeySequence {
    struct ParseError: Error, Equatable {
        /// Problem plus recovery, in one sentence a human wrote.
        let message: String
    }

    /// The whole syntax, in the order the editor prints it.
    static let syntaxRows: [(token: String, meaning: String)] = [
        ("abc", "Sent as itself, one byte per ASCII character."),
        ("^X", "The control byte for X. `^C` is 0x03, `^?` is 0x7F."),
        ("\\e", "Escape, 0x1B. `\\e[A` is the up arrow."),
        ("\\xNN", "One byte written in hex, as in `\\x7f`."),
        ("\\n \\r \\t \\0", "Newline, carriage return, tab, NUL."),
        ("\\\\ \\^", "A literal backslash, a literal caret."),
    ]

    static func parse(_ text: String) -> Result<[UInt8], ParseError> {
        guard !text.isEmpty else {
            return .failure(ParseError(
                message: "Nothing to send. Type the text this key produces, or an escape like `\\e[A`."
            ))
        }

        var out: [UInt8] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            switch characters[index] {
            case "\\":
                guard index + 1 < characters.count else {
                    return .failure(ParseError(
                        message: "The sequence ends with a lone `\\`. Write `\\\\` for a literal backslash."
                    ))
                }
                let escape = characters[index + 1]
                index += 2
                switch escape {
                case "e": out.append(0x1b)
                case "n": out.append(0x0a)
                case "r": out.append(0x0d)
                case "t": out.append(0x09)
                case "0": out.append(0x00)
                case "\\": out.append(0x5c)
                case "^": out.append(0x5e)
                case "x", "X":
                    guard index + 1 < characters.count,
                          let high = characters[index].hexDigitValue,
                          let low = characters[index + 1].hexDigitValue else {
                        return .failure(ParseError(
                            message: "`\\x` needs exactly two hex digits after it, as in `\\x1b`."
                        ))
                    }
                    out.append(UInt8(high << 4 | low))
                    index += 2
                default:
                    return .failure(ParseError(
                        message: "`\\\(escape)` is not an escape this understands. The escapes are `\\e`, `\\n`, `\\r`, `\\t`, `\\0`, `\\\\`, `\\^`, and `\\xNN`."
                    ))
                }

            case "^":
                guard index + 1 < characters.count else {
                    return .failure(ParseError(
                        message: "The sequence ends with a lone `^`. Follow it with the key, as in `^C`, or write `\\^` for a literal caret."
                    ))
                }
                let keyCharacter = characters[index + 1]
                guard let byte = ControlFold.byte(forControlCharacter: keyCharacter) else {
                    return .failure(ParseError(
                        message: "`^\(keyCharacter)` is not a control key. Use a letter, or one of `@ [ \\ ] ^ _ ?`."
                    ))
                }
                out.append(byte)
                index += 2

            case let character:
                // Anything else is itself. UTF-8 rather than ASCII, so a key
                // labelled with a box-drawing character or an accented letter
                // sends what it says rather than being refused.
                out.append(contentsOf: Array(String(character).utf8))
                index += 1
            }
        }

        return .success(out)
    }

    /// The bytes, or nil. For callers that only need to know whether it works.
    static func bytes(_ text: String) -> [UInt8]? {
        switch parse(text) {
        case .success(let bytes): return bytes
        case .failure: return nil
        }
    }

    /// `1B 5B 41`. Uppercase, space-separated, tabular by construction: this is
    /// the readout that makes a wrong sequence visible before it is saved.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
