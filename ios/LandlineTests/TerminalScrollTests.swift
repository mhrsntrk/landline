import XCTest
import SwiftTerm
@testable import Landline

// Swiping to scroll, in the one situation where SwiftTerm cannot do it itself:
// an application at the far end has turned mouse reporting on, so SwiftTerm's
// own pan sends a button press, motion and release, tmux reads that drag as a
// selection, and nothing scrolls. Scrolling needs wheel events.
//
// Five things are worth proving without a device: the exact bytes a notch puts
// on the wire in both encodings a terminal can be in, the travel-to-notch
// conversion including that a fast flick no longer throws travel away, that the
// carry which now holds that travel is bounded, that each step of the speed
// setting means the multiple its label claims, and that the coast after a flick
// actually stops. The settings file's migration is here too, because the speed
// is the first key `settings.json` has grown since it was written.

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
    /// swipe covers the same amount of text at 9pt and at 22pt. 1x is three cell
    /// heights, which is what every build before the speed setting charged.
    func testNotchCostScalesWithTheCellHeight() {
        XCTAssertEqual(WheelScrollAccumulator(cellHeight: 15, speed: .x1).pointsPerNotch, 45)
        XCTAssertEqual(WheelScrollAccumulator(cellHeight: 30, speed: .x1).pointsPerNotch, 90)
    }

    /// The default is three times the old speed: one notch per cell height,
    /// which is one line of finger travel per notch.
    func testTheDefaultIsOneNotchPerCellHeight() {
        XCTAssertEqual(TerminalScrollSpeed.default, .x3)
        XCTAssertEqual(WheelScrollAccumulator(cellHeight: 15).pointsPerNotch, 15)
    }

    /// Every step, stated as the notch count one fixed drag buys. The whole
    /// point of the setting is that the labels mean something: 2x has to be
    /// twice 1x, not "somewhat more".
    func testEachSpeedBuysItsMultipleOfTheSlowest() {
        // 450 points of travel, which is exactly ten notches at 1x.
        let drag: CGFloat = 450
        let expected: [TerminalScrollSpeed: Int] = [.x1: 10, .x2: 20, .x3: 30, .x4: 40, .x5: 50]
        for (speed, notches) in expected {
            var accumulator = WheelScrollAccumulator(cellHeight: 15, speed: speed)
            var charged = 0
            // Delivered as ten callbacks, the way a real drag arrives, so the
            // per-callback ceiling and the carry are both in the loop.
            for _ in 0..<10 { charged += accumulator.notches(forTranslation: drag / 10) }
            XCTAssertEqual(charged, notches, "\(speed.label) should charge \(notches) notches")
        }
    }

    /// A finger moving down the screen reveals earlier output, which is a wheel
    /// notch up. Getting this backwards is the classic scroll bug, so it is
    /// pinned rather than assumed.
    func testDownwardTravelIsAWheelNotchUp() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15, speed: .x1)
        XCTAssertEqual(accumulator.notches(forTranslation: 45), 1)
        XCTAssertEqual(accumulator.notches(forTranslation: -90), -2)
    }

    /// A swipe arrives as a hundred small callbacks, most worth less than one
    /// notch. Without a carried remainder a slow drag would scroll nothing.
    func testRemainderCarriesBetweenCallbacks() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15, speed: .x1)
        for _ in 0..<4 {
            XCTAssertEqual(accumulator.notches(forTranslation: 10), 0)
        }
        // 40 points banked, 5 more crosses 45.
        XCTAssertEqual(accumulator.notches(forTranslation: 5), 1)
        XCTAssertEqual(accumulator.carry, 0, accuracy: 0.0001)
    }

    /// The ceiling is a travel limit, so it has to permit more notches as the
    /// speed rises. A fixed notch ceiling would make the fast settings spend
    /// every callback clamped, which is the runaway it exists to prevent.
    func testTheCeilingIsTravelRatherThanNotches() {
        XCTAssertEqual(WheelScrollAccumulator(cellHeight: 15, speed: .x1).maxNotchesPerStep, 4)
        XCTAssertEqual(WheelScrollAccumulator(cellHeight: 15, speed: .x3).maxNotchesPerStep, 12)
        XCTAssertEqual(WheelScrollAccumulator(cellHeight: 15, speed: .x5).maxNotchesPerStep, 20)
        // Same travel per callback whatever the speed: twelve cell heights.
        for speed in TerminalScrollSpeed.allCases {
            let accumulator = WheelScrollAccumulator(cellHeight: 15, speed: speed)
            XCTAssertEqual(CGFloat(accumulator.maxNotchesPerStep) * accumulator.pointsPerNotch,
                           15 * WheelScrollAccumulator.maxCellHeightsPerStep,
                           accuracy: 0.001)
        }
    }

    /// **The bug this pass fixes.** A quick flick arrives as a handful of large
    /// callbacks; the ceiling used to charge four notches for one of those and
    /// bin the rest, so most of the finger's travel never became scrolling.
    /// Nothing a finger actually did may be lost now.
    func testALargeTranslationLosesNoTravel() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15, speed: .x3)
        // 600 points, which is 40 notches at the default and far past one
        // callback's ceiling of 12.
        var charged = accumulator.notches(forTranslation: 600)
        XCTAssertEqual(charged, accumulator.maxNotchesPerStep, "the callback is still capped")
        // The rest is owed, not gone, and pays out on the callbacks that follow.
        var callbacks = 0
        while charged < 40 && callbacks < 20 {
            charged += accumulator.notches(forTranslation: 0)
            callbacks += 1
        }
        XCTAssertEqual(charged, 40, "the travel beyond the ceiling was discarded")
        XCTAssertLessThan(callbacks, 5, "the backlog should drain in a few frames")
        XCTAssertEqual(accumulator.carry, 0, accuracy: 0.0001)
    }

    /// One long drag delivered in one lump and the same drag delivered frame by
    /// frame have to buy the same amount of text. That equality is what "a fast
    /// swipe no longer discards travel" means.
    func testACoalescedDragChargesTheSameAsASmoothOne() {
        var lumpy = WheelScrollAccumulator(cellHeight: 15, speed: .x3)
        var smooth = WheelScrollAccumulator(cellHeight: 15, speed: .x3)
        var lumpyTotal = 0
        var smoothTotal = 0
        // 900 points of travel: four coalesced callbacks against sixty small ones.
        for _ in 0..<4 { lumpyTotal += lumpy.notches(forTranslation: 225) }
        for _ in 0..<20 { lumpyTotal += lumpy.notches(forTranslation: 0) }
        for _ in 0..<60 { smoothTotal += smooth.notches(forTranslation: 15) }
        XCTAssertEqual(lumpyTotal, 60)
        XCTAssertEqual(smoothTotal, 60)
    }

    /// The carry is bounded. Retaining the overflow must not become a queue that
    /// keeps scrolling long after the finger stopped, so an absurd translation
    /// is banked only up to about three screens of travel and the rest is gone.
    func testTheCarryIsBounded() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15, speed: .x3)
        XCTAssertEqual(accumulator.maxCarry, 15 * WheelScrollAccumulator.maxCarryCellHeights)
        var charged = 0
        // A hundred thousand points is nothing a finger can do, and the bound is
        // what stops it becoming ten thousand wheel events.
        charged += accumulator.notches(forTranslation: 100_000)
        var callbacks = 0
        while accumulator.carry != 0 && callbacks < 500 {
            charged += accumulator.notches(forTranslation: 0)
            callbacks += 1
        }
        XCTAssertEqual(charged, 120, "the bound is three screens of travel, not the whole lump")
        XCTAssertLessThan(callbacks, 12, "the bounded backlog drains inside a fifth of a second")
        // Symmetric, and it does not accumulate across callbacks either.
        var downwards = WheelScrollAccumulator(cellHeight: 15, speed: .x3)
        for _ in 0..<10 { _ = downwards.notches(forTranslation: -100_000) }
        XCTAssertGreaterThanOrEqual(downwards.carry, -downwards.maxCarry)
    }

    /// A zero cell height happens for one frame between `makeUIView` and the
    /// first layout. It must not divide by nothing.
    func testDegenerateCellHeightsDoNotDivideByZero() {
        for speed in TerminalScrollSpeed.allCases {
            var accumulator = WheelScrollAccumulator(cellHeight: 0, speed: speed)
            XCTAssertGreaterThan(accumulator.pointsPerNotch, 0)
            XCTAssertGreaterThanOrEqual(accumulator.maxNotchesPerStep, 1)
            XCTAssertEqual(accumulator.notches(forTranslation: .nan), 0)
            XCTAssertEqual(accumulator.notches(forTranslation: 0), 0)
        }
    }

    func testResetForgetsTheCarry() {
        var accumulator = WheelScrollAccumulator(cellHeight: 15, speed: .x1)
        _ = accumulator.notches(forTranslation: 30)
        accumulator.reset()
        XCTAssertEqual(accumulator.notches(forTranslation: 30), 0)
    }
}

// MARK: - The speed setting

final class TerminalScrollSpeedTests: XCTestCase {
    /// The label is the whole of what the user has to understand, so it has to
    /// be true: Nx is N times the notches of 1x for the same travel.
    func testTheLabelMatchesTheArithmetic() {
        for speed in TerminalScrollSpeed.allCases {
            XCTAssertEqual(speed.label, "\(speed.rawValue)x")
            XCTAssertEqual(speed.cellHeightsPerNotch * CGFloat(speed.rawValue),
                           TerminalScrollSpeed.slowestCellHeightsPerNotch,
                           accuracy: 0.0001)
        }
    }

    /// 1x is the speed every build before this one shipped, so somebody who
    /// preferred it can have it back exactly.
    func testTheSlowestStepIsTheOldBehaviour() {
        XCTAssertEqual(TerminalScrollSpeed.x1.cellHeightsPerNotch, 3)
        XCTAssertEqual(TerminalScrollSpeed.default.cellHeightsPerNotch, 1)
    }

    /// Only the two ends and the default are annotated. An annotation on every
    /// cell would be texture rather than marking.
    func testOnlyTheEndsAndTheDefaultAreAnnotated() {
        XCTAssertEqual(TerminalScrollSpeed.x1.endpointNote, "SLOWEST")
        XCTAssertEqual(TerminalScrollSpeed.x3.endpointNote, "DEFAULT")
        XCTAssertEqual(TerminalScrollSpeed.x5.endpointNote, "FASTEST")
        XCTAssertNil(TerminalScrollSpeed.x2.endpointNote)
        XCTAssertNil(TerminalScrollSpeed.x4.endpointNote)
        XCTAssertEqual(TerminalScrollSpeed.x4.travelNote, "1 NOTCH / 0.75 LINES OF TRAVEL")
    }
}

// MARK: - Settings persistence

final class ScrollSpeedPersistenceTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func read() throws -> String {
        String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
    }

    /// Set it, and a store built fresh over the same file reads it back.
    func testTheSpeedRoundTripsThroughTheFile() throws {
        let store = SettingsStore(fileURL: fileURL)
        XCTAssertEqual(store.scrollSpeed, .default)
        store.setScrollSpeed(.x5)
        XCTAssertEqual(SettingsStore(fileURL: fileURL).scrollSpeed, .x5)
    }

    /// **The migration.** A file written by the previous build has a `keyBar`
    /// and no `scrollSpeed`. It must still load, the row must survive, and the
    /// missing key must take the new default rather than the old speed.
    func testAFileFromThePreviousBuildLoadsAndTakesTheNewDefault() throws {
        let previous = try AppSettings.encode(AppSettings(keyBar: [KeyBarKey(catalogID: "esc")]))
        XCTAssertFalse(String(decoding: previous, as: UTF8.self).contains("scrollSpeed"))
        try previous.write(to: fileURL)

        let store = SettingsStore(fileURL: fileURL)
        XCTAssertEqual(store.scrollSpeed, .default)
        XCTAssertEqual(store.keyBar.compactMap(\.catalogID), ["esc"])
    }

    /// The other direction: writing the speed must not cost the key bar, and the
    /// document has to stay a flat object an older build can still read.
    func testWritingTheSpeedKeepsTheDocumentFlat() throws {
        let store = SettingsStore(fileURL: fileURL)
        store.append(KeyBarKey(catalogID: "ctrl"))
        store.setScrollSpeed(.x2)

        let document = try read()
        XCTAssertTrue(document.contains("\"scrollSpeed\" : 2"), document)
        // Still an `AppSettings` document, so the previous build reads its row.
        let asOldBuild = try AppSettings.decode(from: Data(document.utf8))
        XCTAssertEqual(asOldBuild.keyBar.compactMap(\.catalogID), store.keyBar.compactMap(\.catalogID))
    }

    /// A step a newer build wrote, and a file that is not a settings file at
    /// all. Neither may cost the user the row they arranged.
    func testUnreadableValuesFallBackRatherThanThrowingTheFileAway() throws {
        let unknown = #"{"keyBar":[{"id":"\#(UUID().uuidString)","catalogID":"esc"}],"scrollSpeed":99}"#
        try Data(unknown.utf8).write(to: fileURL)
        let store = SettingsStore(fileURL: fileURL)
        XCTAssertEqual(store.scrollSpeed, .default)
        XCTAssertEqual(store.keyBar.compactMap(\.catalogID), ["esc"])

        try Data("not json".utf8).write(to: fileURL)
        XCTAssertEqual(SettingsStore(fileURL: fileURL).scrollSpeed, .default)
    }

    func testTheEmptyDocumentTakesEveryDefault() throws {
        let decoded = try SettingsDocument.decode(from: Data("{}".utf8))
        XCTAssertEqual(decoded.scrollSpeed, .default)
        XCTAssertEqual(decoded.app, AppSettings())
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

    /// The coast's budget, which is what stops a higher speed setting turning a
    /// flick into a page-down storm. Friction bounds the coast in *travel*, and
    /// travel is exactly what the speed setting divides, so the bound that means
    /// anything is stated in notches and spent in points.
    func testTheCoastIsBudgeted() {
        var decay = FlickDecay(velocity: 6000, maxTravel: 300)
        var travelled: CGFloat = 0
        var frames = 0
        while decay.isCoasting && frames < 600 {
            travelled += decay.step(dt: 1.0 / 60)
            frames += 1
        }
        XCTAssertEqual(travelled, 300, accuracy: 0.001, "the coast spent more than its budget")
        XCTAssertFalse(decay.isCoasting)
    }

    /// Backwards too, and a budget of nothing is a coast that never starts.
    func testTheBudgetIsSignedAndCanBeZero() {
        var backwards = FlickDecay(velocity: -6000, maxTravel: 120)
        var travelled: CGFloat = 0
        while backwards.isCoasting { travelled += backwards.step(dt: 1.0 / 60) }
        XCTAssertEqual(travelled, -120, accuracy: 0.001)
        XCTAssertFalse(FlickDecay(velocity: 6000, maxTravel: 0).isCoasting)
    }

    /// Left to friction alone, a hard flick settles at about thirty-five notches
    /// at the old speed, which is why the sixty-notch budget never fires at 1x
    /// and only bounds the top of the range.
    func testTheBudgetDoesNotBiteAtTheSlowestSpeed() {
        let accumulator = WheelScrollAccumulator(cellHeight: 16, speed: .x1)
        var decay = FlickDecay(velocity: FlickDecay.maxSpeed)
        var travelled: CGFloat = 0
        while decay.isCoasting { travelled += decay.step(dt: 1.0 / 60) }
        let notches = travelled / accumulator.pointsPerNotch
        XCTAssertLessThan(notches, CGFloat(FlickDecay.maxCoastNotches))
    }
}
