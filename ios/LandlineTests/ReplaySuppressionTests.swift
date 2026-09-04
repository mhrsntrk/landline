import SwiftTerm
import XCTest

@testable import Landline

/// Reopening a resumed session printed terminal replies into the shell:
/// `65;4;1;2;6;21;22;17;28c`, `>|SwiftTerm 1.20.0`, `rgb:abab/b2b2/bfbf`,
/// `24;51t`, `384;408t`.
///
/// Cause: scrollback replay is real output parsed a second time, and it
/// contains the queries the far end sent the first time. SwiftTerm cannot tell
/// a replayed query from a live one, answers them all, and the answers travel
/// up the wire as input, where whatever sits at the prompt types them.
///
/// These assert the rule rather than SwiftTerm's parser: the controller decides
/// whether a response is forwarded, and that decision is the fix.
final class ReplaySuppressionTests: XCTestCase {
    private func makeController(replay: Int) -> (TerminalController, () -> [Data]) {
        let controller = TerminalController()
        controller.attach(to: TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
        var sent: [Data] = []
        controller.onSend = { sent.append($0) }
        controller.beginReplay(bytes: replay)
        return (controller, { sent })
    }

    /// The whole rule, in one table. A response is produced synchronously
    /// inside `feed`; a keypress never is, which is the only thing separating
    /// them at the delegate.
    func testOnlyAResponseGeneratedDuringReplayIsDropped() {
        XCTAssertTrue(TerminalController.dropsOutbound(isReplaying: true, isParsing: true),
                      "a replayed query must not be answered into the live prompt")
        XCTAssertFalse(TerminalController.dropsOutbound(isReplaying: true, isParsing: false),
                       "a keypress during replay is the user, not a replayed query")
        XCTAssertFalse(TerminalController.dropsOutbound(isReplaying: false, isParsing: true),
                       "a live query must be answered")
        XCTAssertFalse(TerminalController.dropsOutbound(isReplaying: false, isParsing: false))
    }

    func testResponsesResumeOnceTheReplayIsConsumed() {
        let (controller, sent) = makeController(replay: 5)
        controller.feed(Data("hello".utf8))
        controller.flushForTest()
        XCTAssertFalse(controller.isReplaying, "replay should end exactly at the reported byte count")
        controller.forwardResponse(Data("\u{1b}[?1c".utf8))
        XCTAssertEqual(sent().count, 1, "a live query must still be answered")
    }

    /// Replayed and live bytes can land in one chunk, so the slice fed to
    /// SwiftTerm is split on the boundary rather than judged as a whole.
    func testAChunkStraddlingTheBoundaryEndsTheReplayExactly() {
        let (controller, _) = makeController(replay: 3)
        controller.feed(Data("abcdef".utf8))
        controller.flushForTest()
        XCTAssertFalse(controller.isReplaying)
    }

    func testWithoutAReplayEverythingIsForwarded() {
        let (controller, sent) = makeController(replay: 0)
        XCTAssertFalse(controller.isReplaying)
        controller.forwardResponse(Data("\u{1b}[?1c".utf8))
        XCTAssertEqual(sent().count, 1)
    }

    func testAShortReplayCannotUnderflow() {
        let (controller, _) = makeController(replay: 2)
        controller.feed(Data("aaaaaaaa".utf8))
        controller.flushForTest()
        XCTAssertFalse(controller.isReplaying)
        controller.feed(Data("bbbb".utf8))
        controller.flushForTest()
        XCTAssertFalse(controller.isReplaying, "the counter must not wrap and re-arm suppression")
    }
}

/// Suppressing replayed queries also swallowed anything the user typed during
/// the replay, roughly 250ms on a full scrollback. The delegate sees a parser
/// response and a keypress identically; the difference is that a response is
/// produced synchronously inside `feed` and a keypress never is.
final class ReplayInputTests: XCTestCase {
    func testTypingDuringReplayStillReachesTheFarEnd() {
        let controller = TerminalController()
        controller.attach(to: TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
        var sent: [Data] = []
        controller.onSend = { sent.append($0) }
        controller.beginReplay(bytes: 4096)

        XCTAssertTrue(controller.isReplaying)
        controller.forwardResponse(Data("ls\n".utf8))

        XCTAssertEqual(
            sent.count, 1,
            "a keypress during replay was dropped; the user is not a replayed query"
        )
    }
}
