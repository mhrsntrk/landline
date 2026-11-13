import XCTest
@testable import Landline

/// The fold rules in `NavigationMode`. iPhone Duo's inner display is 951 x 669pt
/// in landscape and 669 x 951pt in portrait.
final class FolioLayoutTests: XCTestCase {
    func testHalfOpenLandscapeSplitsAtTheCrease() {
        let mode = NavigationMode(.regular, width: 951, height: 669, hinge: .partial, fillsScreen: true)
        XCTAssertEqual(mode, .folio(Folio(axis: .sideBySide, indexLength: 475.5)))
    }

    func testHalfOpenPortraitIsLaptopPosture() {
        let mode = NavigationMode(.regular, width: 669, height: 951, hinge: .partial, fillsScreen: true)
        XCTAssertEqual(mode, .folio(Folio(axis: .stacked, indexLength: 475.5)))
    }

    /// A window that does not fill the screen has no known crease.
    func testHalfOpenWindowNotFillingTheScreenIsLaidOutFlat() {
        XCTAssertEqual(NavigationMode(.regular, width: 951, height: 669, hinge: .partial, fillsScreen: false), .split)
    }

    /// Open flat in portrait: the system split overlays at 669pt, so the app
    /// draws its own narrow index instead of falling back to the stack.
    func testOpenPortraitGetsTheNarrowIndex() {
        let mode = NavigationMode(.regular, width: 669, height: 951, hinge: .open, fillsScreen: true)
        XCTAssertEqual(mode, .folio(Folio(axis: .sideBySide, indexLength: NavigationMode.narrowIndexWidth)))
    }

    func testOpenLandscapeKeepsTheSystemSplit() {
        XCTAssertEqual(NavigationMode(.regular, width: 951, height: 669, hinge: .open, fillsScreen: true), .split)
    }

    /// No hinge: the narrow regular window is still the stack, as before.
    func testNoHingeNarrowWindowIsStillTheStack() {
        XCTAssertEqual(NavigationMode(.regular, width: 669, height: 951), .stack)
    }

    /// Closed is the outer display, a phone.
    func testClosedIsCompact() {
        XCTAssertEqual(NavigationMode(.compact, width: 466, height: 678, hinge: .closed, fillsScreen: true), .stack)
    }
}
