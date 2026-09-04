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

    func testResponsesAreDroppedWhileReplaying() {
        let (controller, sent) = makeController(replay: 64)
        XCTAssertTrue(controller.isReplaying)
        controller.forwardResponse(Data("\u{1b}[?65;4;1;2;6;21;22;17;28c".utf8))
        XCTAssertTrue(sent().isEmpty, "a replayed query was answered into the live prompt")
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
