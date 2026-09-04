import SwiftUI
import XCTest
@testable import Landline

/// The two rules the iPad layout hangs off, kept where they can be checked
/// without standing up a window: which shape the app is in, and what the one
/// back affordance says in each of them.
final class NavigationModeTests: XCTestCase {

    func testRegularWidthIsTheSplit() {
        XCTAssertEqual(NavigationMode(.regular), .split)
    }

    /// The rule that stops an iPad in a narrow Split View or a Slide Over from
    /// cramming a 300pt sidebar into a 320pt window. The decision is the size
    /// class and never the idiom, which is exactly why this is testable at all.
    func testCompactWidthIsTheStack() {
        XCTAssertEqual(NavigationMode(.compact), .stack)
    }

    /// SwiftUI reports nil before a window has been measured. A stack laid out
    /// in a wide window looks sparse for one frame; a split laid out in a narrow
    /// one has no room for either column.
    func testUnknownWidthFallsBackToTheStack() {
        XCTAssertEqual(NavigationMode(nil), .stack)
    }
}

/// DESIGN.md pins one back affordance, in one place, wearing one set of
/// clothes. This is that table.
final class HeaderLeadingTests: XCTestCase {

    func testTheIndexItselfDrawsNoCell() {
        XCTAssertNil(HeaderLeading.root.label)
    }

    func testCompactGoesBack() {
        XCTAssertEqual(HeaderLeading.back.label, "\u{25C0} BACK")
    }

    /// Nothing is behind a sheet, so its cell does not point anywhere.
    func testASheetRootClosesWithoutAMark() {
        XCTAssertEqual(HeaderLeading.close.label, "CLOSE")
    }

    /// The mark points the way the press moves things: showing collapses the
    /// column leftward, hidden pushes the content rightward to reveal it.
    func testTheIndexCellPointsTheWayThePressMovesThings() {
        XCTAssertEqual(HeaderLeading.index(showing: true).label, "\u{25C0} INDEX")
        XCTAssertEqual(HeaderLeading.index(showing: false).label, "\u{25B6} INDEX")
    }

    /// The glyph is a mark, so the spoken label has to carry the meaning.
    func testEveryCellSaysWhatItDoesToVoiceOver() {
        XCTAssertEqual(HeaderLeading.back.accessibilityLabel, "back")
        XCTAssertEqual(HeaderLeading.close.accessibilityLabel, "close")
        XCTAssertEqual(HeaderLeading.index(showing: true).accessibilityLabel, "hide the index")
        XCTAssertEqual(HeaderLeading.index(showing: false).accessibilityLabel, "show the index")
    }

    /// A cell that is drawn is a cell that can be pressed, so the two must not
    /// disagree about whether there is anything there.
    func testOnlyTheRootIsUnlabelled() {
        let labelled: [HeaderLeading] = [.back, .close, .index(showing: true), .index(showing: false)]
        for kind in labelled {
            XCTAssertNotNil(kind.label, "\(kind) draws a cell and must name it")
            XCTAssertFalse(kind.accessibilityLabel.isEmpty)
        }
    }
}

/// The index column's collapsed state is remembered between launches, so it
/// rides `settings.json` and has to survive the same two migrations everything
/// else in that file does.
final class IndexColumnPreferenceTests: XCTestCase {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("landline-index-\(UUID().uuidString).json")
    }

    /// A first run must not open on a screen with the index hidden and nothing
    /// selected, so the absent value means "showing".
    func testAFileWithoutTheKeyDefaultsToShowing() throws {
        let legacy = Data(#"{"keyBar":[],"scrollSpeed":3}"#.utf8)
        let document = try SettingsDocument.decode(from: legacy)
        XCTAssertTrue(document.showsIndexColumn)
    }

    /// The whole point of storing it: a collapsed index stays collapsed.
    func testACollapsedColumnIsRememberedAcrossALaunch() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SettingsStore(fileURL: url)
        XCTAssertTrue(first.showsIndexColumn, "the shipped state is the column showing")
        first.setShowsIndexColumn(false)

        let second = SettingsStore(fileURL: url)
        XCTAssertFalse(second.showsIndexColumn)
    }

    /// It is one more key in the same document, so writing it must not cost the
    /// user the settings that were already in there.
    func testWritingItKeepsTheRestOfTheDocument() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SettingsStore(fileURL: url)
        first.setScrollSpeed(.x5)
        first.append(KeyBarKey(catalogID: "esc"))
        let expectedKeys = first.keyBar.count
        first.setShowsIndexColumn(false)

        let second = SettingsStore(fileURL: url)
        XCTAssertEqual(second.scrollSpeed, .x5)
        XCTAssertEqual(second.keyBar.count, expectedKeys)
        XCTAssertFalse(second.showsIndexColumn)
    }

    func testTheDocumentRoundTrips() throws {
        var document = SettingsDocument()
        document.showsIndexColumn = false
        document.scrollSpeed = .x2
        let data = try SettingsDocument.encode(document)
        XCTAssertEqual(try SettingsDocument.decode(from: data), document)
    }
}
