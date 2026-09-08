import XCTest
@testable import Landline

/// Saved text, and the bytes choosing it puts on the wire.
final class SnippetTests: XCTestCase {

    func testTypedTextIsWrappedForAPrompt() {
        let snippet = Snippet(name: "status", text: "git status")
        let bytes = snippet.bytes(bracketedPaste: true)
        XCTAssertEqual(Array(bytes.prefix(6)), [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
        XCTAssertEqual(Array(bytes.suffix(6)), [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
        XCTAssertEqual(String(decoding: bytes.dropFirst(6).dropLast(6), as: UTF8.self),
                       "git status")
    }

    func testAPlainTerminalGetsTheTextAlone() {
        let snippet = Snippet(text: "git status")
        XCTAssertEqual(String(decoding: snippet.bytes(bracketedPaste: false), as: UTF8.self),
                       "git status")
    }

    /// The safety this feature turns on. Text is recoverable; text plus a
    /// newline has already run at whatever prompt was open.
    func testNothingIsRunUnlessItWasAskedFor() {
        let quiet = Snippet(text: "rm -rf /tmp/x")
        XCTAssertFalse(quiet.bytes(bracketedPaste: true).contains(0x0d))
        XCTAssertFalse(quiet.bytes(bracketedPaste: false).contains(0x0d))

        let loud = Snippet(text: "rm -rf /tmp/x", runsImmediately: true)
        XCTAssertEqual(loud.bytes(bracketedPaste: false).last, 0x0d)
    }

    /// The return goes after the closing marker, not inside it. Inside, it is
    /// pasted text; outside, it is a key being pressed, which is the whole
    /// difference between typing a command and running it.
    func testTheReturnLandsOutsideTheBrackets() {
        let bytes = Snippet(text: "ls", runsImmediately: true).bytes(bracketedPaste: true)
        XCTAssertEqual(bytes.last, 0x0d)
        XCTAssertEqual(Array(bytes.dropLast().suffix(6)), [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
    }

    func testAnEmptySnippetTypesNothing() {
        XCTAssertTrue(Snippet(text: "").bytes(bracketedPaste: true).isEmpty)
        XCTAssertTrue(Snippet(text: "", runsImmediately: true).bytes(bracketedPaste: false).isEmpty,
                      "an empty snippet must not press return on its own")
        XCTAssertFalse(Snippet(text: "").isUsable)
    }

    func testMultilineSnippetsSurviveIntact() {
        let snippet = Snippet(text: "cd /srv\nmake deploy")
        let bytes = snippet.bytes(bracketedPaste: true)
        let inner = String(decoding: bytes.dropFirst(6).dropLast(6), as: UTF8.self)
        XCTAssertEqual(inner, "cd /srv\nmake deploy",
                       "a multi-line snippet is one paste, not two commands")
    }

    // MARK: How the rows read

    func testAnUnnamedSnippetBorrowsItsFirstLine() {
        XCTAssertEqual(Snippet(text: "git status").displayName, "git status")
        XCTAssertEqual(Snippet(text: "cd /srv\nmake").displayName, "cd /srv")
        XCTAssertEqual(Snippet(name: "deploy", text: "make").displayName, "deploy")
        XCTAssertEqual(Snippet(name: "   ", text: "").displayName, "untitled")
    }

    func testTheSummarySaysWhenThereIsMoreThanOneLine() {
        XCTAssertTrue(Snippet(text: "a\nb\nc").summary.hasPrefix("3 LINES / "))
        XCTAssertFalse(Snippet(text: "a").summary.contains("LINES"))
    }

    // MARK: Storage

    func testSnippetsRoundTripAndOlderFilesStillRead() throws {
        let settings = AppSettings(snippets: [
            Snippet(name: "deploy", text: "make deploy", runsImmediately: true),
        ])
        let decoded = try AppSettings.decode(from: AppSettings.encode(settings))
        XCTAssertEqual(decoded.snippets.count, 1)
        XCTAssertEqual(decoded.snippets[0].name, "deploy")
        XCTAssertTrue(decoded.snippets[0].runsImmediately)

        // A settings file written before snippets existed reads as none, and
        // must not disturb the key bar next to it.
        let old = #"{ "keyBar" : [ { "catalogID" : "esc" } ] }"#
        let back = try AppSettings.decode(from: Data(old.utf8))
        XCTAssertTrue(back.snippets.isEmpty)
        XCTAssertEqual(back.keyBar.count, 1)
    }
}

/// The host diagnosis, which is the only thing on the index that tells someone
/// what to do next.
final class HostDiagnosisTests: XCTestCase {

    func testEveryFailureNamesSomethingToDo() {
        let failures: [HostDiagnosis] = [
            .loginNotAllowed, .nameDoesNotResolve, .noAnswer, .tlsFailed, .noNetwork,
        ]
        for diagnosis in failures {
            XCTAssertNotNil(diagnosis.label, "\(diagnosis) has no word")
            guard let advice = diagnosis.advice else {
                return XCTFail("\(diagnosis) has no advice")
            }
            XCTAssertFalse(advice.isEmpty)
            XCTAssertFalse(advice.contains("\u{2014}"), "no em-dashes in user-facing copy")
        }
    }

    func testAWorkingHostSaysNothingAtAll() {
        for quiet in [HostDiagnosis.reachable, .checking, .unknown] {
            XCTAssertNil(quiet.advice, "\(quiet) should not explain itself")
            XCTAssertNil(quiet.label)
        }
    }

    /// A refusal is not an outage, and the row has to distinguish them: one is
    /// fixed in the daemon's config, the other by turning something on.
    func testARefusalIsNotAnOutage() {
        XCTAssertEqual(HostDiagnosis.reachable.level, .connected)
        XCTAssertEqual(HostDiagnosis.loginNotAllowed.level, .failed)
        XCTAssertEqual(HostDiagnosis.noAnswer.level, .offline)
        XCTAssertNotEqual(HostDiagnosis.loginNotAllowed.level, HostDiagnosis.noAnswer.level)
    }
}

/// The session list's one piece of arithmetic.
final class SessionIdleTests: XCTestCase {
    func testIdleReadsCoarselyAndStaysNarrow() {
        XCTAssertEqual(SessionsView.idleLabel(0), "0s")
        XCTAssertEqual(SessionsView.idleLabel(45), "45s")
        XCTAssertEqual(SessionsView.idleLabel(60), "1m")
        XCTAssertEqual(SessionsView.idleLabel(3599), "59m")
        XCTAssertEqual(SessionsView.idleLabel(3600), "1h")
        XCTAssertEqual(SessionsView.idleLabel(86_400), "1d")
        XCTAssertEqual(SessionsView.idleLabel(-5), "0s", "a clock skew is not a negative age")
        for seconds in [0, 59, 60, 3599, 3600, 86_399, 86_400, 8_640_000] {
            XCTAssertLessThanOrEqual(SessionsView.idleLabel(seconds).count, 4,
                                     "\(seconds) is too wide for the column")
        }
    }
}
