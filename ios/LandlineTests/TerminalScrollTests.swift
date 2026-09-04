import XCTest
import SwiftTerm
@testable import Landline

// Swiping to scroll, in the one situation where SwiftTerm cannot do it itself:
// an application at the far end has turned mouse reporting on, so SwiftTerm's
// own pan sends a button press, motion and release, tmux reads that drag as a
// selection, and nothing scrolls. Scrolling needs wheel events.
//
// Three things are worth proving without a device: the exact bytes a notch puts
// on the wire in both encodings a terminal can be in, the travel-to-notch
// conversion including what a fast flick is clamped to, and that the coast after
// a flick actually stops.

// MARK: - Wire bytes

/// Captures everything a terminal puts on the wire.
private final class WireRecorder: TerminalDelegate {
    var sent: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }
}

final class WheelEncodingTests: XCTestCase {
    /// A terminal in `mode`, with everything it has said so far discarded.
    private func terminal(enabling modes: [String]) -> (Terminal, WireRecorder) {
        let recorder = WireRecorder()
        let terminal = Terminal(delegate: recorder)
        for mode in modes { terminal.feed(text: "\u{1b}[?\(mode)h") }
        recorder.sent = []
        return (terminal, recorder)
    }

    /// What `TerminalSwipeScroller` emits, expressed as the two public calls it
    /// makes, so the test exercises SwiftTerm's own encoder rather than a copy
    /// of it living in the test.
    private func wheel(_ terminal: Terminal, up: Bool, col: Int, row: Int) {
        let flags = terminal.encodeButton(button: up ? 4 : 5,
                                          release: false,
                                          shift: false,
                                          meta: false,
                                          control: false)
        terminal.sendEvent(buttonFlags: flags, x: col, y: row, pixelX: col, pixelY: row)
    }

    /// Buttons 4 and 5 are the wheel, and `encodeButton` puts them in the 64/65
    /// range xterm reserves for it. This is the whole reason a wheel event is
    /// not a drag: 0 through 2 are the buttons a drag uses.
    func testWheelButtonsEncodeIntoTheSixtyFourRange() {
        let (terminal, _) = self.terminal(enabling: ["1000"])
        XCTAssertEqual(terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false), 64)
        XCTAssertEqual(terminal.encodeButton(button: 5, release: false, shift: false, meta: false, control: false), 65)
        // A drag's buttons, for contrast: these are what SwiftTerm's own pan
        // sends, and what tmux turns into a selection.
        XCTAssertEqual(terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false), 0)
        XCTAssertEqual(terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false), 3)
    }

    /// SGR (`CSI ? 1006 h`), which is what tmux negotiates on anything modern.
    /// Coordinates are one-based, and the terminator is `M` because a wheel
    /// notch is a press with no release.
    func testSgrWheelBytes() {
        let (terminal, wire) = terminal(enabling: ["1000", "1006"])
        wheel(terminal, up: true, col: 10, row: 4)
        XCTAssertEqual(String(decoding: wire.sent, as: UTF8.self), "\u{1b}[<64;11;5M")

        wire.sent = []
        wheel(terminal, up: false, col: 0, row: 0)
        XCTAssertEqual(String(decoding: wire.sent, as: UTF8.self), "\u{1b}[<65;1;1M")
    }

    /// The legacy X10 encoding, which is what a terminal that asked for mouse
    /// reporting but no extended encoding gets: `CSI M` then three bytes, each
    /// biased by 32. 64 + 32 is 96, the backtick.
    func testLegacyX10WheelBytes() {
        let (terminal, wire) = terminal(enabling: ["1000"])
        wheel(terminal, up: true, col: 10, row: 4)
        // 64 + 32 = 96, then the one-based coordinates biased by 32: 43 and 37.
        XCTAssertEqual(wire.sent, [0x1b, 0x5b, 0x4d, 96, 43, 37])

        wire.sent = []
        wheel(terminal, up: false, col: 0, row: 0)
        XCTAssertEqual(wire.sent, [0x1b, 0x5b, 0x4d, 97, 33, 33])
    }

    /// The bit that makes this a *scroll* rather than a click: the wheel flag
    /// has bit 6 set, so SGR's release test (`flags & 3 == 3` with bit 5 clear)
    /// never fires and the event is never encoded as a button-up.
    func testWheelIsNeverEncodedAsARelease() {
        let (terminal, wire) = terminal(enabling: ["1000", "1006"])
        wheel(terminal, up: true, col: 0, row: 0)
        XCTAssertFalse(String(decoding: wire.sent, as: UTF8.self).hasSuffix("m"),
                       "a lowercase terminator would tell the far end a button was released")
    }

    /// Mouse reporting off is the case the scroller declines outright, and the
    /// mode is the flag it reads to know that.
    func testMouseModeReportsWhetherTheFarEndIsReading() {
        let recorder = WireRecorder()
        let terminal = Terminal(delegate: recorder)
        XCTAssertEqual(terminal.mouseMode, .off)
        terminal.feed(text: "\u{1b}[?1000h")
        XCTAssertNotEqual(terminal.mouseMode, .off)
        terminal.feed(text: "\u{1b}[?1000l")
        XCTAssertEqual(terminal.mouseMode, .off)
    }
}

// MARK: - Travel to notches

final class WheelScrollAccumulatorTests: XCTestCase {
    /// The ratio is taken off the cell height, not off a constant, so the same
    /// swipe covers the same amount of text at 9pt and at 22pt.
    func testNotchCostsThreeCellHeights() {
        let accumulator = WheelScrollAccumulator(cellHeight: 15)
        XCTAssertEqual(accumulator.pointsPerNotch, 45)
        XCTAssertEqual(WheelScrollAccumulator(cellHeight: 30).pointsPerNotch, 90)
    }

    /// A finger moving down the screen reveals earlier output, which is a wheel
    /// notch up. Getting this backwards is the classic scroll bug, so it is
    /// pinned rather than assumed.
    func testDownwardTravelIsAWheelNotchUp() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15)
        XCTAssertEqual(accumulator.notches(forTranslation: 45), 1)
        XCTAssertEqual(accumulator.notches(forTranslation: -90), -2)
    }

    /// A swipe arrives as a hundred small callbacks, most worth less than one
    /// notch. Without a carried remainder a slow drag would scroll nothing.
    func testRemainderCarriesBetweenCallbacks() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15)
        for _ in 0..<4 {
            XCTAssertEqual(accumulator.notches(forTranslation: 10), 0)
        }
        // 40 points banked, 5 more crosses 45.
        XCTAssertEqual(accumulator.notches(forTranslation: 5), 1)
        XCTAssertEqual(accumulator.carry, 0, accuracy: 0.0001)
    }

    /// The clamp. A flick hands the whole flick over in one callback; without a
    /// ceiling that single callback would put hundreds of wheel events on the
    /// wire in one frame and the far end would still be chewing on them seconds
    /// after the finger stopped.
    func testAFastFlickIsClampedToOneStepsWorth() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15)
        XCTAssertEqual(accumulator.notches(forTranslation: 4000),
                       WheelScrollAccumulator.maxNotchesPerStep)
        XCTAssertEqual(accumulator.notches(forTranslation: -4000),
                       -WheelScrollAccumulator.maxNotchesPerStep)
    }

    /// The overflow a clamp refused is dropped, not banked. Paying it back over
    /// the following frames would keep the terminal running after the gesture
    /// had visibly ended.
    func testClampedOverflowIsDroppedRatherThanQueued() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15)
        _ = accumulator.notches(forTranslation: 4000)
        XCTAssertEqual(accumulator.carry, 0)
        XCTAssertEqual(accumulator.notches(forTranslation: 1), 0)
    }

    /// A zero cell height happens for one frame between `makeUIView` and the
    /// first layout. It must not divide by nothing.
    func testDegenerateCellHeightsDoNotDivideByZero() {
        var accumulator = WheelScrollAccumulator(cellHeight: 0)
        XCTAssertGreaterThan(accumulator.pointsPerNotch, 0)
        XCTAssertEqual(accumulator.notches(forTranslation: .nan), 0)
        XCTAssertEqual(accumulator.notches(forTranslation: 0), 0)
    }

    func testResetForgetsTheCarry() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15)
        _ = accumulator.notches(forTranslation: 30)
        accumulator.reset()
        XCTAssertEqual(accumulator.notches(forTranslation: 30), 0)
    }
}

// MARK: - Flick coast

final class FlickDecayTests: XCTestCase {
    /// A slow lift is not a flick. Coasting off it would make every drag end
    /// with a small unrequested slide.
    func testASlowLiftDoesNotCoast() {
        XCTAssertFalse(FlickDecay(velocity: 10).isCoasting)
        XCTAssertFalse(FlickDecay(velocity: -10).isCoasting)
        XCTAssertTrue(FlickDecay(velocity: 2000).isCoasting)
    }

    /// It has to actually stop. A coast that never falls under the threshold is
    /// a terminal that scrolls forever.
    func testTheCoastStops() {
        var decay = FlickDecay(velocity: 6000)
        var frames = 0
        var travelled: CGFloat = 0
        while decay.isCoasting && frames < 600 {
            travelled += decay.step(dt: 1.0 / 60)
            frames += 1
        }
        XCTAssertFalse(decay.isCoasting, "the coast never came to rest")
        XCTAssertLessThan(frames, 120, "a flick should settle inside two seconds")
        XCTAssertGreaterThan(travelled, 0)
    }

    /// Direction survives the decay, and the distance shrinks frame over frame.
    func testCoastDecaysAndKeepsItsDirection() {
        var decay = FlickDecay(velocity: -3000)
        let first = decay.step(dt: 1.0 / 60)
        let second = decay.step(dt: 1.0 / 60)
        XCTAssertLessThan(first, 0)
        XCTAssertLessThan(second, 0)
        XCTAssertGreaterThan(second, first, "the second frame should travel less")
    }

    /// Velocity is clamped, so a flick off a 120Hz panel cannot report a number
    /// that overwhelms the notch ceiling for a hundred frames.
    func testAbsurdVelocitiesAreClamped() {
        XCTAssertEqual(FlickDecay(velocity: 100_000).velocity, FlickDecay.maxSpeed)
        XCTAssertEqual(FlickDecay(velocity: .infinity).velocity, 0)
    }

    func testAStoppedDecayTravelsNothing() {
        var decay = FlickDecay(velocity: 0)
        XCTAssertEqual(decay.step(dt: 1.0 / 60), 0)
    }
}
