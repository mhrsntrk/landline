import XCTest
@testable import Landline

/// The tmux prefix, resolved to the byte it actually sends.
///
/// A wrong prefix is completely silent — tmux simply never enters command mode
/// — so every offered prefix is asserted against its byte here rather than
/// being checked by eye on a device.
final class LeaderKeyTests: XCTestCase {

    func testEveryOfferedPresetResolves() {
        XCTAssertEqual(LeaderKey.byte(for: "C-b"), 0x02)
        XCTAssertEqual(LeaderKey.byte(for: "C-a"), 0x01)
        XCTAssertEqual(LeaderKey.byte(for: "C-Space"), 0x00)
        XCTAssertEqual(LeaderKey.byte(for: "C-\\"), 0x1c)
        XCTAssertEqual(LeaderKey.byte(for: "C-o"), 0x0f)
    }

    /// The list on the screen and the table behind it cannot drift apart: every
    /// row that is offered has to resolve, or the picker offers a dead prefix.
    func testPresetsAreExactlyTheOnesTested() {
        XCTAssertEqual(LeaderKey.presets, ["C-b", "C-a", "C-Space", "C-\\", "C-o"])
        for preset in LeaderKey.presets {
            XCTAssertNotNil(LeaderKey.byte(for: preset), "\(preset) is offered but does not resolve")
        }
    }

    func testDefaultIsTmuxOwnDefault() {
        XCTAssertEqual(LeaderKey.default, "C-b")
        XCTAssertEqual(LeaderKey.byte(for: LeaderKey.default), 0x02)
    }

    func testCustomNotationsResolve() {
        XCTAssertEqual(LeaderKey.byte(for: "C-g"), 0x07)
        XCTAssertEqual(LeaderKey.byte(for: "C-z"), 0x1a)
        // Case of the key does not matter: C-A and C-a are the same byte.
        XCTAssertEqual(LeaderKey.byte(for: "C-A"), 0x01)
        // Case of the prefix does not either.
        XCTAssertEqual(LeaderKey.byte(for: "c-a"), 0x01)
        XCTAssertEqual(LeaderKey.byte(for: "C-space"), 0x00)
        XCTAssertEqual(LeaderKey.byte(for: "  C-a  "), 0x01, "surrounding space is not a typo worth refusing")
        XCTAssertEqual(LeaderKey.byte(for: "C-]"), 0x1d)
        XCTAssertEqual(LeaderKey.byte(for: "C-@"), 0x00)
        XCTAssertEqual(LeaderKey.byte(for: "C-?"), 0x7f, "Ctrl-? is DEL, which is what a terminal sends")
    }

    func testNonsenseIsRefusedRatherThanGuessedAt() {
        for nonsense in ["", " ", "b", "C", "C-", "-a", "M-a", "C-ab", "ctrl-a", "^a",
                         "C-1", "C-Escape", "Space", "0x01", "C--"] {
            XCTAssertNil(LeaderKey.byte(for: nonsense), "\(nonsense) must not resolve")
            XCTAssertFalse(LeaderKey.isValid(nonsense))
        }
    }

    func testHexIsWhatTheScreenPrints() {
        XCTAssertEqual(LeaderKey.hex(for: "C-a"), "0x01")
        XCTAssertEqual(LeaderKey.hex(for: "C-Space"), "0x00")
        XCTAssertEqual(LeaderKey.hex(for: "C-\\"), "0x1C")
        XCTAssertNil(LeaderKey.hex(for: "M-x"))
    }
}

// MARK: - Latches

/// The state machine behind CTRL, ALT and LDR.
///
/// Every one of these is a byte that goes to a live shell, so the composition
/// order and the disarming behaviour are asserted rather than looked at.
final class LatchStateTests: XCTestCase {

    private let leader: UInt8 = 0x01 // set -g prefix C-a

    func testNoLatchPassesThrough() {
        var latches = LatchState()
        XCTAssertEqual(latches.consume([0x6f], leaderByte: leader), [0x6f])
        XCTAssertFalse(latches.isAnyArmed)
    }

    func testCtrlFoldsAndUnlatches() {
        var latches = LatchState()
        latches.ctrl = true
        XCTAssertEqual(latches.consume([0x63], leaderByte: leader), [0x03], "ctrl-c")
        XCTAssertFalse(latches.ctrl, "the latch clears after one key")
        // And the key after it is untouched.
        XCTAssertEqual(latches.consume([0x63], leaderByte: leader), [0x63])
    }

    func testAltPrefixesEscape() {
        var latches = LatchState()
        latches.alt = true
        XCTAssertEqual(latches.consume([0x66], leaderByte: leader), [0x1b, 0x66], "alt-f")
        XCTAssertFalse(latches.alt)
    }

    /// The bug this snapshot-before-clear rule exists for: reading one latch
    /// after clearing another used to drop the ESC.
    func testCtrlAndAltCompose() {
        var latches = LatchState()
        latches.ctrl = true
        latches.alt = true
        XCTAssertEqual(latches.consume([0x63], leaderByte: leader), [0x1b, 0x03], "alt+ctrl-c")
        XCTAssertFalse(latches.isAnyArmed)
    }

    func testLeaderSendsThePrefixThenTheKey() {
        var latches = LatchState()
        latches.leader = true
        XCTAssertEqual(latches.consume([0x63], leaderByte: leader), [0x01, 0x63], "prefix then c")
        XCTAssertFalse(latches.leader)
    }

    /// `C-a C-o` is a real tmux binding: the prefix goes out raw and the key
    /// after it is control-folded, not the other way round.
    func testLeaderComposesWithCtrl() {
        var latches = LatchState()
        latches.leader = true
        latches.ctrl = true
        XCTAssertEqual(latches.consume([0x6f], leaderByte: leader), [0x01, 0x0f])
        XCTAssertFalse(latches.isAnyArmed, "both latches clear together")
    }

    /// The prefix byte itself is never folded. Folding it would send a
    /// different prefix, which is exactly the silent failure this feature is
    /// meant to remove.
    func testLeaderByteIsNotFoldedByCtrl() {
        var latches = LatchState()
        latches.leader = true
        latches.ctrl = true
        // C-Space as the prefix: 0x00. Folding it again would still be 0x00, so
        // use C-\ (0x1C), whose fold would be 0x1C & 0x1f = 0x1C — pick a case
        // where a second fold is observable instead: the payload, not the prefix.
        XCTAssertEqual(latches.consume([0x20], leaderByte: 0x1c), [0x1c, 0x00],
                       "prefix raw, then ctrl-space as NUL")
    }

    func testLeaderComposesWithAlt() {
        var latches = LatchState()
        latches.leader = true
        latches.alt = true
        XCTAssertEqual(latches.consume([0x78], leaderByte: leader), [0x01, 0x1b, 0x78],
                       "ESC goes in front of the key, not in front of the prefix")
    }

    func testAllThreeCompose() {
        var latches = LatchState()
        latches.leader = true
        latches.ctrl = true
        latches.alt = true
        XCTAssertEqual(latches.consume([0x6f], leaderByte: leader), [0x01, 0x1b, 0x0f])
    }

    /// Tapping an armed latch disarms it. There has to be a way out of a wrong
    /// one, or the next keystroke is guaranteed to be wrong.
    func testDisarming() {
        var latches = LatchState()
        latches.leader = true
        XCTAssertTrue(latches.isAnyArmed)
        latches.leader = false
        XCTAssertFalse(latches.isAnyArmed)
        XCTAssertEqual(latches.consume([0x63], leaderByte: leader), [0x63], "no prefix once disarmed")
    }

    func testClearDropsEverything() {
        var latches = LatchState()
        latches.ctrl = true
        latches.alt = true
        latches.leader = true
        latches.clear()
        XCTAssertEqual(latches, LatchState())
    }

    /// A host whose stored notation does not resolve has no prefix byte. The
    /// leader must then contribute nothing rather than guess at C-b — the LDR
    /// key is disabled in that state for the same reason.
    func testLeaderWithoutAResolvedByteSendsNoPrefix() {
        var latches = LatchState()
        latches.leader = true
        XCTAssertEqual(latches.consume([0x63], leaderByte: nil), [0x63])
        XCTAssertFalse(latches.leader, "it still clears, so the bar does not stay stuck armed")
    }

    /// Only the *first* byte is folded: a multi-byte payload is an escape
    /// sequence from the bar, not a keystroke to modify.
    func testCtrlFoldsOnlyTheFirstByte() {
        var latches = LatchState()
        latches.ctrl = true
        XCTAssertEqual(latches.consume([0x1b, 0x5b, 0x41], leaderByte: leader), [0x1b, 0x5b, 0x41],
                       "ESC is outside the fold range and passes through")
    }

    func testEmptyPayloadSendsNothingAndKeepsTheLatch() {
        var latches = LatchState()
        latches.leader = true
        XCTAssertEqual(latches.consume([], leaderByte: leader), [])
        XCTAssertTrue(latches.leader, "an empty keypress must not silently spend the prefix")
    }
}

// MARK: - Control fold

final class ControlFoldTests: XCTestCase {

    /// The fold the terminal has always applied, kept byte for byte when it was
    /// lifted out of `TerminalScreen`.
    func testTerminalFoldIsUnchanged() {
        XCTAssertEqual(ControlFold.fold(firstByte: 0x63), 0x03, "c")
        XCTAssertEqual(ControlFold.fold(firstByte: 0x43), 0x03, "C")
        XCTAssertEqual(ControlFold.fold(firstByte: 0x20), 0x00, "space is NUL")
        XCTAssertEqual(ControlFold.fold(firstByte: 0x5c), 0x1c, "backslash")
        XCTAssertEqual(ControlFold.fold(firstByte: 0x1b), 0x1b, "outside the range, untouched")
        XCTAssertEqual(ControlFold.fold(firstByte: 0x30), 0x30, "a digit has no control code")
    }

    func testWrittenControlCharacters() {
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "a"), 0x01)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "A"), 0x01)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "@"), 0x00)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "["), 0x1b)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "\\"), 0x1c)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "]"), 0x1d)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "^"), 0x1e)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "_"), 0x1f)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: " "), 0x00)
        XCTAssertEqual(ControlFold.byte(forControlCharacter: "?"), 0x7f)
        XCTAssertNil(ControlFold.byte(forControlCharacter: "1"))
        XCTAssertNil(ControlFold.byte(forControlCharacter: "é"))
    }
}

// MARK: - Custom sequences

/// The syntax a custom key's bytes are written in.
///
/// A key that silently sends the wrong bytes is worse than no custom key at all,
/// so this asserts both halves: that valid input produces exactly the right
/// bytes, and that malformed input is refused rather than partially accepted.
final class KeySequenceParsingTests: XCTestCase {

    /// Resolved against no host at all, which is what every sequence written
    /// before `\L` existed needs and gets.
    private func bytes(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [UInt8]? {
        switch KeySequence.parse(text) {
        case .success(let template): return template.resolve(leaderByte: nil)
        case .failure(let error):
            XCTFail("\(text) should parse, got: \(error.message)", file: file, line: line)
            return nil
        }
    }

    private func failure(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let template) = KeySequence.parse(text) {
            XCTFail("\(text) should not parse, got \(KeySequence.hex(template))", file: file, line: line)
        }
        XCTAssertNil(KeySequence.bytes(text), file: file, line: line)
    }

    func testControlBytes() {
        XCTAssertEqual(bytes("^A"), [0x01])
        XCTAssertEqual(bytes("^a"), [0x01])
        XCTAssertEqual(bytes("^C"), [0x03])
        XCTAssertEqual(bytes("^?"), [0x7f], "^? is DEL")
        XCTAssertEqual(bytes("^["), [0x1b])
        XCTAssertEqual(bytes("^A^B"), [0x01, 0x02])
    }

    func testEscapes() {
        XCTAssertEqual(bytes("\\e"), [0x1b])
        XCTAssertEqual(bytes("\\e[A"), [0x1b, 0x5b, 0x41], "the up arrow")
        XCTAssertEqual(bytes("\\x1b"), [0x1b])
        XCTAssertEqual(bytes("\\x1B"), [0x1b], "hex digits are case insensitive")
        XCTAssertEqual(bytes("\\X1b"), [0x1b], "so is the x")
        XCTAssertEqual(bytes("\\x7f"), [0x7f])
        XCTAssertEqual(bytes("\\x00"), [0x00])
        XCTAssertEqual(bytes("\\xff"), [0xff])
        XCTAssertEqual(bytes("\\n"), [0x0a])
        XCTAssertEqual(bytes("\\r"), [0x0d])
        XCTAssertEqual(bytes("\\t"), [0x09])
        XCTAssertEqual(bytes("\\0"), [0x00])
    }

    func testLiteralsForTheCharactersTheSyntaxUses() {
        XCTAssertEqual(bytes("\\\\"), [0x5c], "an escaped backslash is one backslash")
        XCTAssertEqual(bytes("\\^"), [0x5e], "an escaped caret is one caret")
    }

    func testLiteralText() {
        XCTAssertEqual(bytes("git status"), Array("git status".utf8))
        XCTAssertEqual(bytes("~"), [0x7e])
        XCTAssertEqual(bytes("|"), [0x7c])
        // Not ASCII, but a label may legitimately want it, so it is UTF-8 rather
        // than refused.
        XCTAssertEqual(bytes("é"), Array("é".utf8))
    }

    /// The realistic ones: a tmux prefix chord written out, and a shell line.
    func testMixedSequences() {
        XCTAssertEqual(bytes("^Ac"), [0x01, 0x63], "tmux: prefix then new window")
        XCTAssertEqual(bytes("\\e[1;5D"), [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44], "ctrl-left")
        XCTAssertEqual(bytes("clear\\n"), Array("clear".utf8) + [0x0a])
        XCTAssertEqual(bytes("\\ex"), [0x1b, 0x78], "meta-x")
    }

    func testMalformedInputIsRefused() {
        failure("")                 // nothing to send
        failure("\\")               // trailing backslash
        failure("abc\\")            // trailing backslash after real content
        failure("^")                // trailing caret
        failure("abc^")             // trailing caret after real content
        failure("\\q")              // not an escape
        failure("\\x")              // no hex digits
        failure("\\x1")             // one hex digit
        failure("\\xZZ")            // not hex
        failure("\\x1g")            // second digit not hex
        failure("^1")               // no control code for a digit
        failure("^é")               // no control code for a non-ASCII character
    }

    /// The error is a sentence a human wrote, because it is what the editor
    /// shows instead of saving. An empty message would leave the field looking
    /// broken for no stated reason.
    func testEveryRefusalCarriesASentence() {
        for malformed in ["", "\\", "^", "\\q", "\\x1", "^1"] {
            guard case .failure(let error) = KeySequence.parse(malformed) else {
                return XCTFail("\(malformed) should not parse")
            }
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertTrue(error.message.hasSuffix("."), "‘\(error.message)’ is not a sentence")
        }
    }

    /// Nothing is emitted for input that fails partway through: a key that sent
    /// the first half of what was typed would be the exact failure the parser
    /// exists to prevent.
    func testAPartialParseEmitsNothing() {
        XCTAssertNil(KeySequence.bytes("^A\\q"))
        XCTAssertNil(KeySequence.bytes("\\e[A\\x"))
    }

    func testHexReadout() {
        XCTAssertEqual(KeySequence.hex([0x1b, 0x5b, 0x41]), "1B 5B 41")
        XCTAssertEqual(KeySequence.hex([0x01]), "01")
        XCTAssertEqual(KeySequence.hex([]), "")
    }

    /// The table the editor prints and the parser have to agree, or the screen
    /// documents a syntax the parser does not accept.
    func testEveryDocumentedTokenActuallyParses() {
        for sample in ["abc", "^X", "\\e", "\\x1b", "\\n", "\\r", "\\t", "\\0", "\\\\", "\\^"] {
            XCTAssertNotNil(KeySequence.bytes(sample), "the syntax table documents \(sample)")
        }
        // `\L` parses but has no bytes without a host, so it is asserted against
        // a leader rather than against nil.
        XCTAssertNotNil(KeySequence.bytes("\\L", leaderByte: 0x01))
        XCTAssertEqual(KeySequence.syntaxRows.count, 7)
        XCTAssertTrue(KeySequence.syntaxRows.contains { $0.token == "\\L" },
                      "the leader token has to be documented where the escapes are")
    }
}

// MARK: - The leader token

/// `\L`, the one token whose byte is not known when the sequence is written.
///
/// The layout is app-wide and the tmux prefix is per host, so a key that
/// hardcoded `^A` would send the wrong prefix the moment the same bar was used
/// against a machine set to `C-b`. These assert the two halves of the fix: that
/// the token resolves to whatever the host is set to, and that it resolves to
/// nothing at all rather than to a guess when the host has no usable prefix.
final class KeySequenceLeaderTests: XCTestCase {

    private func template(_ text: String,
                          file: StaticString = #filePath, line: UInt = #line) -> KeySequence.Template? {
        switch KeySequence.parse(text) {
        case .success(let template): return template
        case .failure(let error):
            XCTFail("\(text) should parse, got: \(error.message)", file: file, line: line)
            return nil
        }
    }

    func testLeaderAloneIsOneByteFromTheHost() {
        guard let template = template("\\L") else { return }
        XCTAssertTrue(template.needsLeader)
        XCTAssertFalse(template.isEmpty, "a bare leader still sends something")
        XCTAssertEqual(template.byteCount, 1)
        XCTAssertEqual(template.resolve(leaderByte: 0x01), [0x01])
        XCTAssertEqual(template.resolve(leaderByte: 0x02), [0x02])
    }

    /// The exercise itself: tmux's new window, on whichever prefix the machine
    /// is set to.
    func testLeaderThenAKey() {
        guard let template = template("\\Lc") else { return }
        XCTAssertEqual(template.byteCount, 2)
        XCTAssertEqual(template.resolve(leaderByte: 0x01), [0x01, 0x63], "set -g prefix C-a")
        XCTAssertEqual(template.resolve(leaderByte: 0x02), [0x02, 0x63], "tmux's own default")
        XCTAssertEqual(template.resolve(leaderByte: 0x00), [0x00, 0x63], "C-Space")
    }

    /// Window switching, the thing the tmux section exists for.
    func testLeaderThenADigit() {
        XCTAssertEqual(template("\\L1")?.resolve(leaderByte: 0x01), [0x01, 0x31])
        XCTAssertEqual(template("\\L9")?.resolve(leaderByte: 0x02), [0x02, 0x39])
    }

    func testLeaderComposesWithTheOtherEscapes() {
        XCTAssertEqual(template("\\L\\e[A")?.resolve(leaderByte: 0x01),
                       [0x01, 0x1b, 0x5b, 0x41])
        XCTAssertEqual(template("\\L\\x25")?.resolve(leaderByte: 0x01), [0x01, 0x25], "split")
        XCTAssertEqual(template("\\L^c")?.resolve(leaderByte: 0x02), [0x02, 0x03])
        XCTAssertEqual(template("\\L\"")?.resolve(leaderByte: 0x01), [0x01, 0x22])
        // More than one leader in one sequence is legal, if unusual: tmux's own
        // "send the prefix through to the inner session" is exactly this.
        XCTAssertEqual(template("\\L\\L")?.resolve(leaderByte: 0x01), [0x01, 0x01])
    }

    /// The escape that has always meant a literal backslash still does. `\\L` is
    /// a backslash followed by the letter L, not a leader, or every sequence
    /// that ever printed a Windows path would change meaning.
    func testAnEscapedBackslashIsNotALeader() {
        guard let template = template("\\\\L") else { return }
        XCTAssertFalse(template.needsLeader)
        XCTAssertEqual(template.resolve(leaderByte: nil), [0x5c, 0x4c])
        XCTAssertEqual(template.resolve(leaderByte: 0x01), [0x5c, 0x4c],
                       "a host's prefix cannot change what this sends")
    }

    /// Lowercase is not the token. A `\l` beside a `\1` in a mono face is
    /// exactly the near-miss that would get a wrong sequence saved, so it is
    /// refused with the sentence that names the escapes.
    func testLowercaseIsNotTheToken() {
        guard case .failure(let error) = KeySequence.parse("\\lc") else {
            return XCTFail("`\\l` must not be the leader token")
        }
        XCTAssertTrue(error.message.contains("`\\l`"), "the refusal names the token that was wrong")
        XCTAssertTrue(error.message.contains("`\\L`"), "and lists the one that exists")
    }

    /// The rule the LDR key already follows: no prefix byte means no bytes, not
    /// tmux's default guessed at.
    func testAHostWithNoLeaderResolvesToNothing() {
        XCTAssertNil(template("\\Lc")?.resolve(leaderByte: nil))
        XCTAssertNil(KeySequence.bytes("\\Lc"))
        XCTAssertNil(KeySequence.bytes("\\Lc", leaderByte: LeaderKey.byte(for: "M-x")))
        XCTAssertEqual(KeySequence.bytes("\\Lc", leaderByte: LeaderKey.byte(for: "C-a")), [0x01, 0x63])
    }

    /// A sequence with no leader in it must be resolvable with no host context
    /// at all, which is what every stored key from the previous build is.
    func testSequencesWithoutALeaderNeedNoHost() {
        for text in ["^Ac", "\\e[1;5D", "git status\\n", "~", "\\x7f", "\\\\", "\\^"] {
            guard let template = template(text) else { continue }
            XCTAssertFalse(template.needsLeader, text)
            XCTAssertEqual(template.resolve(leaderByte: nil), template.resolve(leaderByte: 0x01),
                           "\(text) cannot depend on the host")
            XCTAssertNotNil(KeySequence.bytes(text), text)
        }
    }

    /// Every sequence this app could already send, still byte for byte what it
    /// was. This is the list that must not move.
    func testPreExistingSequencesProduceIdenticalBytes() {
        let unchanged: [(String, [UInt8])] = [
            ("^A", [0x01]),
            ("^Ac", [0x01, 0x63]),
            ("^?", [0x7f]),
            ("^[", [0x1b]),
            ("\\e", [0x1b]),
            ("\\e[A", [0x1b, 0x5b, 0x41]),
            ("\\e[1;5D", [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44]),
            ("\\x1b", [0x1b]),
            ("\\x7f", [0x7f]),
            ("\\xff", [0xff]),
            ("\\n", [0x0a]),
            ("\\r", [0x0d]),
            ("\\t", [0x09]),
            ("\\0", [0x00]),
            ("\\\\", [0x5c]),
            ("\\^", [0x5e]),
            ("clear\\n", Array("clear".utf8) + [0x0a]),
            ("git status", Array("git status".utf8)),
            ("é", Array("é".utf8)),
        ]
        for (text, expected) in unchanged {
            XCTAssertEqual(KeySequence.bytes(text), expected, text)
        }
    }

    /// The readout the settings print. `LDR` rather than an invented byte,
    /// because those screens are app-wide and have no host to ask.
    func testHexPrintsTheLeaderSlotSymbolically() {
        XCTAssertEqual(KeySequence.leaderSymbol, "LDR")
        XCTAssertEqual(template("\\Lc").map(KeySequence.hex), "LDR 63")
        XCTAssertEqual(template("\\L1").map(KeySequence.hex), "LDR 31")
        XCTAssertEqual(template("\\L").map(KeySequence.hex), "LDR")
        XCTAssertEqual(template("\\L\\e[A").map(KeySequence.hex), "LDR 1B 5B 41")
        XCTAssertEqual(template("\\e[A").map(KeySequence.hex), "1B 5B 41",
                       "a fixed sequence reads exactly as it always did")
    }

    /// Nothing is emitted for a sequence that fails after a leader, for the same
    /// reason nothing was emitted for one that failed after a control byte.
    func testAPartialParseAfterALeaderEmitsNothing() {
        XCTAssertNil(KeySequence.template("\\Lc\\q"))
        XCTAssertNil(KeySequence.bytes("\\Lc\\q", leaderByte: 0x01))
    }
}
