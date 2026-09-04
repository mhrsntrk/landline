import XCTest
@testable import Landline

// Press and hold on the key bar.
//
// The latency a held backspace suffers is not removable: every 0x7F is a round
// trip to the daemon and the shell echoes the erase back, so the system keyboard
// deletes at the speed of the link. What this app can control is how many
// keystrokes one hold is worth, because it draws its own keypad. So the repeat
// clock is ours, and these are the four things about it that have to hold: the
// initial delay, the interval, that a release stops it, and that a finger
// leaving the cell stops it too.

final class KeyRepeatStateTests: XCTestCase {
    /// Nothing repeats before the initial delay, or a tap would double.
    func testNothingRepeatsBeforeTheInitialDelay() {
        var state = KeyRepeatState()
        state.press(now: 100)
        XCTAssertEqual(state.due(now: 100), 0)
        XCTAssertEqual(state.due(now: 100 + KeyRepeatState.initialDelay - 0.001), 0)
        XCTAssertFalse(state.didRepeat)
    }

    func testTheFirstRepeatLandsOnTheInitialDelay() {
        var state = KeyRepeatState()
        state.press(now: 100)
        XCTAssertEqual(state.due(now: 100 + KeyRepeatState.initialDelay), 1)
        XCTAssertTrue(state.didRepeat)
    }

    /// After the first repeat the interval takes over. One tick at 40ms is one
    /// repeat, and a tick that arrives early is none.
    func testRepeatsRunAtTheRepeatInterval() {
        var state = KeyRepeatState()
        let pressed: TimeInterval = 100
        let first = pressed + KeyRepeatState.initialDelay
        state.press(now: pressed)
        XCTAssertEqual(state.due(now: first), 1)
        XCTAssertEqual(state.due(now: first + KeyRepeatState.interval * 0.5), 0,
                       "half an interval is not a repeat")
        XCTAssertEqual(state.due(now: first + KeyRepeatState.interval * 1.5), 1)
        XCTAssertEqual(state.due(now: first + KeyRepeatState.interval * 2.5), 1)
    }

    /// A held key speeds up. A short hold nudges, a long one sweeps.
    func testHoldingAcceleratesToTheFastInterval() {
        XCTAssertEqual(KeyRepeatState.interval(afterRepeats: 0), KeyRepeatState.interval)
        XCTAssertEqual(KeyRepeatState.interval(afterRepeats: KeyRepeatState.accelerateAfter - 1),
                       KeyRepeatState.interval)
        XCTAssertEqual(KeyRepeatState.interval(afterRepeats: KeyRepeatState.accelerateAfter),
                       KeyRepeatState.fastInterval)
        XCTAssertLessThan(KeyRepeatState.fastInterval, KeyRepeatState.interval)
    }

    /// The measured shape of a two-second hold, so a change to the constants has
    /// to be a deliberate one: it must be fast enough to be worth holding and
    /// slow enough not to flood a WebSocket.
    func testATwoSecondHoldSendsABoundedNumberOfKeys() {
        var state = KeyRepeatState()
        var now: TimeInterval = 0
        state.press(now: now)
        var total = 0
        // Ticked at 120Hz, the way the driver ticks it.
        while now < 2 {
            now += 1.0 / 120
            total += state.due(now: now)
        }
        XCTAssertGreaterThan(total, 40, "a two second hold has to be worth holding")
        XCTAssertLessThan(total, 100, "and must not flood the link")
    }

    /// Release stops it. This is the same code path as the finger leaving the
    /// cell, which is deliberate: SwiftUI ends the button's press in both cases
    /// and a key that keeps firing after the thumb slid off is worse than one
    /// that never repeated.
    func testReleaseStopsTheRepeat() {
        var state = KeyRepeatState()
        state.press(now: 100)
        XCTAssertEqual(state.due(now: 100 + KeyRepeatState.initialDelay), 1)
        state.release()
        XCTAssertEqual(state.due(now: 200), 0)
        XCTAssertFalse(state.isHeld)
    }

    func testReleasingBeforeTheDelayNeverRepeats() {
        var state = KeyRepeatState()
        state.press(now: 100)
        state.release()
        XCTAssertEqual(state.due(now: 100 + KeyRepeatState.initialDelay * 10), 0)
        XCTAssertFalse(state.didRepeat)
    }

    /// The repeat count survives the release, because that is how the button's
    /// action knows a hold has already sent everything the key owes and must not
    /// add one more on lift.
    func testTheHoldIsStillDistinguishableFromATapAfterRelease() {
        var state = KeyRepeatState()
        state.press(now: 100)
        _ = state.due(now: 100 + KeyRepeatState.initialDelay)
        state.release()
        XCTAssertTrue(state.didRepeat)

        state.press(now: 200)
        XCTAssertFalse(state.didRepeat, "a new press starts a new hold")
    }

    /// A stalled main thread — a 4 MiB `cat` landing mid-hold — must not be paid
    /// back as forty backspaces in one frame.
    func testAStallDoesNotBurstAndDoesNotKeepBursting() {
        var state = KeyRepeatState()
        state.press(now: 100)
        XCTAssertEqual(state.due(now: 100 + 30), KeyRepeatState.maxCatchUp)
        // The schedule restarts from the stall rather than owing thirty seconds
        // of repeats, so the very next tick is not another full burst.
        XCTAssertEqual(state.due(now: 100 + 30), 0)
    }
}

// MARK: - Which keys repeat

final class KeyRepeatPolicyTests: XCTestCase {
    private func entry(_ id: String) -> KeyBarCatalogEntry? { KeyBarCatalog.entry(id: id) }

    /// Repeat is for motion: one more character gone, one more line back.
    func testMotionKeysRepeat() {
        for id in ["backspace", "delete", "pageup", "pagedown",
                   "arrow.left", "arrow.right", "arrow.up", "arrow.down"] {
            XCTAssertEqual(entry(id)?.repeats, true, "\(id) should repeat when held")
        }
    }

    /// Everything else does not, and that is the decision rather than an
    /// oversight: a held `^C` is a signal storm, a held `^D` closes the shell and
    /// then logs the session out, a held tmux leader opens twenty windows, and a
    /// held `~` types a line of tildes into a live prompt.
    func testKeysWhereRepeatWouldBeDangerousDoNot() {
        for id in ["esc", "tab", "home", "end",
                   "ctrl.c", "ctrl.d", "ctrl.z", "ctrl.l", "ctrl.r",
                   "ctrl.w", "ctrl.u", "ctrl.k", "ctrl.a", "ctrl.e",
                   "sym.tilde", "sym.slash", "tmux.new", "tmux.detach", "tmux.window.1"] {
            XCTAssertEqual(entry(id)?.repeats, false, "\(id) must not repeat when held")
        }
    }

    func testLatchesNeverRepeat() {
        for id in ["ctrl", "alt", "leader"] {
            XCTAssertEqual(entry(id)?.repeats, false)
        }
    }

    /// Nothing here can know what a user-written key does, so it never repeats.
    func testCustomKeysNeverRepeat() {
        let custom = KeyBarKey(catalogID: nil, label: "DEPLOY", sequence: "make deploy\\n")
        XCTAssertEqual(custom.resolved?.repeats, false)
    }

    /// The flag has to survive resolution or the bar would never see it.
    func testResolutionCarriesTheRepeatFlag() {
        XCTAssertEqual(KeyBarKey(catalogID: "backspace").resolved?.repeats, true)
        XCTAssertEqual(KeyBarKey(catalogID: "esc").resolved?.repeats, false)
    }
}
