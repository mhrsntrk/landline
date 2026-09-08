import CoreText
import UIKit
import XCTest
@testable import Landline

/// The icon set, and the label and icon overrides that decide what a cell draws.
final class KeyBarIconTests: XCTestCase {

    // MARK: The set itself

    func testTheDefaultIconsAreInTheOfferedSet() {
        // A default nobody could have chosen from the grid is a default nobody
        // can put back after clearing it.
        XCTAssertNotNil(KeyBarIcon.icon(scalar: KeyBarIcon.attachDefault))
        XCTAssertNotNil(KeyBarIcon.icon(scalar: KeyBarIcon.snippetDefault))
    }

    func testThereAreThirtyIconsAndTheyAreUnique() {
        XCTAssertEqual(KeyBarIcon.all.count, 30)
        XCTAssertEqual(Set(KeyBarIcon.all.map(\.scalar)).count, 30, "duplicate icon")
        XCTAssertEqual(Set(KeyBarIcon.all.map(\.name)).count, 30, "duplicate name")
        XCTAssertEqual(Set(KeyBarIcon.groups.map(\.id)).count, KeyBarIcon.groups.count)
    }

    /// The whole point of the set being curated. A Nerd Font patch that drops a
    /// codepoint, or a font swap, turns an icon into a tofu box, and a tofu box
    /// on a 44pt cell is indistinguishable from a broken build. So every icon
    /// is asked of the font that actually ships, not of a cheat sheet.
    func testEveryIconExistsInTheBundledFont() {
        let font = TerminalFont.nerd(size: 12, bold: false)
        let characters = CTFontCopyCharacterSet(font) as CharacterSet
        for icon in KeyBarIcon.all {
            for scalar in icon.scalar.unicodeScalars {
                XCTAssertTrue(characters.contains(scalar),
                              "\(icon.name) (U+\(String(scalar.value, radix: 16, uppercase: true))) is not in the bundled font")
            }
        }
    }

    /// Each is exactly one scalar, because a cell draws one glyph and a stored
    /// two-scalar sequence would silently become an emoji cluster.
    func testEveryIconIsASingleScalar() {
        for icon in KeyBarIcon.all {
            XCTAssertEqual(icon.scalar.unicodeScalars.count, 1, icon.name)
        }
    }

    func testAnUnknownIconIsNotOffered() {
        XCTAssertNil(KeyBarIcon.icon(scalar: "\u{F9999}"))
        XCTAssertNotNil(KeyBarIcon.icon(scalar: KeyBarIcon.attachDefault))
    }

    // MARK: What the cell ends up drawing

    func testTheAttachKeyWearsAnIconByDefault() {
        let resolved = KeyBarKey(catalogID: "file.attach").resolved
        XCTAssertEqual(resolved?.icon, KeyBarIcon.attachDefault)
        // The label survives underneath, for the settings list and for anyone
        // who clears the icon.
        XCTAssertEqual(resolved?.label, "FILE")
    }

    /// The rule, not the list: a key that opens something wears an icon,
    /// because it is not a key a keyboard has and no word reads right on a 44pt
    /// cell. Everything else prints what it types.
    func testOnlyTheKeysThatOpenSomethingWearIcons() {
        for entry in KeyBarCatalog.all {
            let icon = KeyBarKey(catalogID: entry.id).resolved?.icon
            switch entry.action {
            case .attachFile, .insertSnippet:
                XCTAssertNotNil(icon, "\(entry.id) opens something and should wear an icon")
            case .send, .latchCtrl, .latchAlt, .latchLeader:
                XCTAssertNil(icon, "\(entry.id) should print its label")
            }
        }
    }

    func testTheSnippetKeyWearsAnIconByDefault() {
        let resolved = KeyBarKey(catalogID: "snippet.insert").resolved
        XCTAssertEqual(resolved?.icon, KeyBarIcon.snippetDefault)
        XCTAssertEqual(resolved?.label, "SNIP")
        XCTAssertEqual(resolved?.action, .insertSnippet)
    }

    func testALabelOverrideBeatsTheCatalog() {
        var key = KeyBarKey(catalogID: "esc")
        XCTAssertEqual(key.resolved?.label, "ESC")
        key.label = "QUIT"
        XCTAssertEqual(key.resolved?.label, "QUIT")
        // Clearing restores the default rather than blanking the cell, which is
        // the difference between an override and a value.
        key.label = "   "
        XCTAssertEqual(key.resolved?.label, "ESC")
    }

    func testAnIconOverrideBeatsTheLabel() {
        var key = KeyBarKey(catalogID: "ctrl")
        XCTAssertNil(key.resolved?.icon)
        key.icon = KeyBarIcon.all[0].scalar
        XCTAssertEqual(key.resolved?.icon, KeyBarIcon.all[0].scalar)
        // The bytes are untouched by any of this: appearance is appearance.
        XCTAssertEqual(key.resolved?.action, .latchCtrl)
    }

    /// The one key that ships wearing an icon must be able to stop wearing it,
    /// or it is the one key whose appearance is not actually settable. That is
    /// what the third state of `KeyBarKey.icon` exists for.
    func testTheAttachIconCanBeClearedBackToItsWord() {
        var key = KeyBarKey(catalogID: "file.attach")
        XCTAssertEqual(key.resolved?.icon, KeyBarIcon.attachDefault, "ships with one")

        // A label alone does not take the icon off: the cell still wears it.
        key.label = "ATT"
        XCTAssertEqual(key.resolved?.icon, KeyBarIcon.attachDefault)
        XCTAssertEqual(key.resolved?.label, "ATT")

        // Explicitly none does, and then the label is what draws.
        key.icon = ""
        XCTAssertNil(key.resolved?.icon)
        XCTAssertEqual(key.resolved?.label, "ATT")

        // nil is not the same as empty: it puts the default back.
        key.icon = nil
        XCTAssertEqual(key.resolved?.icon, KeyBarIcon.attachDefault)
    }

    /// Clearing an icon on a key that never had a default is a no-op rather
    /// than a state that reads differently from the one before it.
    func testClearingAnIconOnAnOrdinaryKeyChangesNothing() {
        var key = KeyBarKey(catalogID: "esc")
        XCTAssertNil(key.resolved?.icon)
        key.icon = ""
        XCTAssertNil(key.resolved?.icon)
        XCTAssertEqual(key.resolved?.label, "ESC")
    }

    /// An icon written by a newer build must degrade to the word, never to a
    /// tofu box, for the same reason an unknown catalog id drops the key.
    func testAnIconThisBuildDoesNotKnowFallsBackToTheLabel() {
        var key = KeyBarKey(catalogID: "tab")
        key.icon = "\u{F9999}"
        XCTAssertNil(key.resolved?.icon)
        XCTAssertEqual(key.resolved?.label, "TAB")
    }

    func testACustomKeyCanWearAnIcon() {
        let icon = KeyBarIcon.all[3].scalar
        let key = KeyBarKey(label: "GS", sequence: "git status\\n", icon: icon)
        XCTAssertEqual(key.resolved?.icon, icon)
        XCTAssertEqual(key.resolved?.label, "GS")
    }

    // MARK: Storage

    func testOverridesSurviveARoundTrip() throws {
        let icon = KeyBarIcon.all[7].scalar
        let settings = AppSettings(keyBar: [
            KeyBarKey(catalogID: "esc", label: "QUIT"),
            KeyBarKey(catalogID: "file.attach", icon: icon),
        ])
        let decoded = try AppSettings.decode(from: AppSettings.encode(settings))
        XCTAssertEqual(decoded.keyBar[0].label, "QUIT")
        XCTAssertEqual(decoded.keyBar[1].icon, icon)
        // And the explicitly-cleared state survives too, distinct from unset.
        let cleared = AppSettings(keyBar: [KeyBarKey(catalogID: "file.attach", icon: "")])
        let back = try AppSettings.decode(from: AppSettings.encode(cleared))
        XCTAssertEqual(back.keyBar[0].icon, "")
        XCTAssertNil(back.keyBar[0].resolved?.icon)
    }

    /// A layout written before either field existed must still read, and must
    /// come back as the catalog's own appearance.
    func testALayoutWithoutTheNewFieldsStillReads() throws {
        let json = """
        { "keyBar" : [ { "catalogID" : "esc", "id" : "9E1B0F3C-0000-4000-8000-000000000001" } ] }
        """
        let decoded = try AppSettings.decode(from: Data(json.utf8))
        XCTAssertEqual(decoded.keyBar[0].label, "")
        XCTAssertNil(decoded.keyBar[0].icon, "absent means unset, not cleared")
        XCTAssertEqual(decoded.keyBar[0].resolved?.label, "ESC")
    }
}
