import CoreText
import UIKit
import XCTest

@testable import Landline

/// The bundled Nerd Font is the fix for prompt icons rendering as tofu.
/// These tests fail loudly if it stops being bundled, gets renamed, or is
/// swapped for a build without the patched glyphs, none of which are visible
/// in a normal build log.
final class TerminalFontTests: XCTestCase {
    /// Codepoints a real prompt actually draws. Powerline separators come from
    /// starship and powerlevel10k; the others are Nerd Font device and VCS
    /// icons that a patched font must carry.
    private let requiredCodepoints: [(name: String, scalar: UnicodeScalar)] = [
        ("powerline branch", UnicodeScalar(0xE0A0)!),
        ("powerline separator", UnicodeScalar(0xE0B0)!),
        ("nerd folder", UnicodeScalar(0xF07C)!),
        ("nerd apple", UnicodeScalar(0xF302)!),
    ]

    func testBundledFontsResolve() {
        for bold in [false, true] {
            let font = TerminalFont.nerd(size: 14, bold: bold)
            XCTAssertTrue(
                font.fontName.hasPrefix("JetBrainsMonoNFM"),
                "expected the bundled Nerd Font, got \(font.fontName). A wrong PostScript name "
                    + "falls back to the system font silently, which looks exactly like the tofu bug."
            )
        }
    }

    func testFontCarriesNerdGlyphs() {
        let font = TerminalFont.nerd(size: 14, bold: false)
        let ctFont = font as CTFont
        for (name, scalar) in requiredCodepoints {
            var chars = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let ok = CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, chars.count)
            XCTAssertTrue(ok, "\(name) U+\(String(scalar.value, radix: 16, uppercase: true)) has no glyph")
            XCTAssertNotEqual(glyphs.first, 0, "\(name) mapped to the missing-glyph slot")
        }
    }

    /// The Mono cut matters: its icons are one cell wide, so the grid stays
    /// aligned. A proportional Nerd Font would smear every prompt.
    func testFontIsMonospaced() {
        let font = TerminalFont.nerd(size: 14, bold: false)
        let widths = ["i", "W", "1", " "].map { s -> CGFloat in
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        for w in widths.dropFirst() {
            XCTAssertEqual(w, widths[0], accuracy: 0.01, "font is not monospaced")
        }
    }
}

// MARK: - Cascade
//
// The whole reason `TerminalFont.font(family:size:bold:)` exists. A font the
// owner installed with a configuration profile — Berkeley Mono, say — is almost
// never Nerd Font patched, so making it the terminal face naively brings the
// tofu bug straight back. These tests prove the composed font puts the user's
// glyphs on screen where it has them and the bundled font's glyphs where it
// does not, per codepoint, which is the only behaviour that is actually useful.

final class TerminalFontCascadeTests: XCTestCase {

    /// A subset of the bundled Nerd Font with Latin and the two powerline
    /// codepoints kept and the wider Nerd Font icons stripped, renamed to its
    /// own family. It is here because the interesting case is *partial*
    /// coverage: a font that carries some prompt glyphs and not others, which
    /// is exactly the measured shape of Berkeley Mono on the desktop. Nothing
    /// on the simulator has that shape, so the fixture supplies it.
    private static let fixtureFamily = "Landline Partial Test Mono"
    private static var fixtureRegistered = false

    override class func setUp() {
        super.setUp()
        guard let url = Bundle(for: TerminalFontCascadeTests.self)
            .url(forResource: "PartialCoverageMono", withExtension: "ttf"),
              let data = NSData(contentsOf: url),
              let provider = CGDataProvider(data: data),
              let font = CGFont(provider) else {
            XCTFail("PartialCoverageMono.ttf missing from the test bundle")
            return
        }
        var error: Unmanaged<CFError>?
        fixtureRegistered = CTFontManagerRegisterGraphicsFont(font, &error)
        if !fixtureRegistered {
            XCTFail("could not register the fixture font: \(String(describing: error))")
        }
    }

    /// Which physical font CoreText would actually draw `scalar` with, given
    /// `font` as the composed primary. This is the same question SwiftTerm's
    /// renderer asks: it shapes each row into a CTLine and then reads the
    /// resolved font back off each run before drawing it.
    private func resolvedFontName(for scalar: UnicodeScalar, in font: UIFont) -> String {
        let text = String(scalar) as CFString
        let resolved = CTFontCreateForString(
            font as CTFont, text, CFRange(location: 0, length: CFStringGetLength(text))
        )
        return CTFontCopyPostScriptName(resolved) as String
    }

    private func fixtureFont(bold: Bool = false) -> UIFont {
        TerminalFont.font(family: Self.fixtureFamily, size: 14, bold: bold)
    }

    func testFixtureIsInstalledAndHasPartialCoverage() throws {
        XCTAssertTrue(Self.fixtureRegistered)
        XCTAssertTrue(TerminalFont.isInstalled(family: Self.fixtureFamily))
        let bare = try XCTUnwrap(UIFont(name: "LandlinePartialTestMono-Regular", size: 14))
        // The premise the rest of this file rests on: the primary has the
        // powerline codepoints and lacks the Nerd Font icons.
        XCTAssertNotEqual(TerminalFont.glyph(for: UnicodeScalar(0xE0A0)!, in: bare), 0)
        XCTAssertNotEqual(TerminalFont.glyph(for: UnicodeScalar(0xE0B0)!, in: bare), 0)
        XCTAssertEqual(TerminalFont.glyph(for: UnicodeScalar(0xF07C)!, in: bare), 0,
                       "fixture is supposed to be missing the Nerd Font folder icon")
        XCTAssertEqual(TerminalFont.glyph(for: UnicodeScalar(0xF302)!, in: bare), 0)
    }

    /// The primary keeps everything it can draw. If the cascade greedily pulled
    /// the bundled font in, the user's font would only ever be half applied.
    func testCoveredCodepointsStayInTheChosenFamily() {
        let font = fixtureFont()
        for scalar in [UnicodeScalar("A"), UnicodeScalar("1"), UnicodeScalar(0xE0A0)!,
                       UnicodeScalar(0xE0B0)!] {
            let name = resolvedFontName(for: scalar, in: font)
            XCTAssertTrue(
                name.hasPrefix("LandlinePartialTestMono"),
                "U+\(String(scalar.value, radix: 16, uppercase: true)) resolved to \(name); the "
                    + "chosen family covers it, so the cascade must not steal it"
            )
        }
    }

    /// The other half of the split, and the whole point: codepoints the chosen
    /// family lacks come from the bundled Nerd Font rather than from the
    /// missing-glyph slot.
    func testMissingCodepointsComeFromTheBundledNerdFont() {
        let font = fixtureFont()
        for scalar in [UnicodeScalar(0xF07C)!, UnicodeScalar(0xF302)!] {
            let hex = String(scalar.value, radix: 16, uppercase: true)
            let name = resolvedFontName(for: scalar, in: font)
            XCTAssertTrue(
                name.hasPrefix("JetBrainsMonoNFM"),
                "U+\(hex) resolved to \(name), not the bundled Nerd Font: the cascade is not firing "
                    + "and this codepoint renders as tofu"
            )
            // Resolution alone is not proof; the resolved font has to actually
            // own a glyph for it.
            let resolvedFont = UIFont(name: name, size: 14)
            XCTAssertNotNil(resolvedFont)
            if let resolvedFont {
                XCTAssertNotEqual(TerminalFont.glyph(for: scalar, in: resolvedFont), 0,
                                  "U+\(hex) mapped to the missing-glyph slot in \(name)")
            }
        }
    }

    /// The end of the chain, and the test that actually matters: this is
    /// SwiftTerm's draw path, not an approximation of it.
    ///
    /// `AppleTerminalView` shapes a row into a `CTLine`, walks
    /// `CTLineGetGlyphRuns`, reads each run's font back out of
    /// `CTRunGetAttributes(run)[.font]`, and draws that run's glyphs with that
    /// font. So a composed font only fixes tofu if CoreText *splits the line
    /// into a separate run* for the substituted codepoint and tags it with the
    /// fallback face. Resolution through `CTFontCreateForString` is a weaker
    /// claim than this; it is possible to pass that and still draw nothing.
    func testSwiftTermsRunSplittingPutsTheFallbackOnScreen() throws {
        let font = fixtureFont()
        // A realistic prompt fragment: text and a powerline separator the
        // chosen family has, then a Nerd Font folder icon it does not.
        let row = "~/src \u{E0B0} \u{F07C} ok"
        let attributed = NSAttributedString(string: row, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = try XCTUnwrap(CTLineGetGlyphRuns(line) as? [CTRun])
        XCTAssertGreaterThan(runs.count, 1,
                             "CoreText did not split the line; the fallback can never be drawn")

        let utf16 = Array(row.utf16)
        var drawnBy: [Int: (font: String, glyph: CGGlyph)] = [:]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            // Exactly the lookup AppleTerminalView does per run.
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = try XCTUnwrap(
                attrs.object(forKey: NSAttributedString.Key.font.rawValue as NSString) as? UIFont
            )
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for i in 0..<count {
                drawnBy[indices[i]] = (CTFontCopyPostScriptName(runFont as CTFont) as String,
                                       glyphs[i])
            }
        }

        let separatorIndex = try XCTUnwrap(utf16.firstIndex(of: 0xE0B0))
        let folderIndex = try XCTUnwrap(utf16.firstIndex(of: 0xF07C))
        let letterIndex = try XCTUnwrap(utf16.firstIndex(of: UInt16(UnicodeScalar("~").value)))

        let separator = try XCTUnwrap(drawnBy[separatorIndex])
        let folder = try XCTUnwrap(drawnBy[folderIndex])
        let letter = try XCTUnwrap(drawnBy[letterIndex])

        XCTAssertTrue(letter.font.hasPrefix("LandlinePartialTestMono"), letter.font)
        XCTAssertTrue(separator.font.hasPrefix("LandlinePartialTestMono"),
                      "U+E0B0 is in the chosen family and must be drawn from it, got \(separator.font)")
        XCTAssertTrue(folder.font.hasPrefix("JetBrainsMonoNFM"),
                      "U+F07C would be drawn from \(folder.font), which means tofu")
        // Non-zero glyph ids: the run is drawing real outlines, not the
        // missing-glyph box, which is what the bug actually looks like.
        for (name, drawn) in [("letter", letter), ("separator", separator), ("folder", folder)] {
            XCTAssertNotEqual(drawn.glyph, 0, "\(name) is the missing-glyph slot")
        }
    }

    /// CoreText's own cascade list is *replaced* by an explicit one, so if the
    /// platform default were not appended a terminal would stop being able to
    /// draw CJK and emoji the moment a user picked a Latin-only font.
    func testSystemFallbackSurvivesTheCustomCascade() {
        let font = fixtureFont()
        for scalar in [UnicodeScalar(0x4E2D)!, UnicodeScalar(0x0645)!] {
            let hex = String(scalar.value, radix: 16, uppercase: true)
            let name = resolvedFontName(for: scalar, in: font)
            let resolved = UIFont(name: name, size: 14)
            XCTAssertNotNil(resolved, "U+\(hex) resolved to an unusable font \(name)")
            if let resolved {
                XCTAssertNotEqual(
                    TerminalFont.glyph(for: scalar, in: resolved), 0,
                    "U+\(hex) has no glyph anywhere in the cascade; the platform default list "
                        + "was dropped instead of appended"
                )
            }
        }
    }

    /// Requesting bold from a family that only ships a regular face must not
    /// silently land on a different family.
    func testBoldFallsBackWithinTheSameFamily() {
        let bold = fixtureFont(bold: true)
        XCTAssertEqual(bold.familyName, Self.fixtureFamily)
        XCTAssertTrue(resolvedFontName(for: UnicodeScalar("A"), in: bold)
            .hasPrefix("LandlinePartialTestMono"))
        // And the cascade still applies to the bold face.
        XCTAssertTrue(resolvedFontName(for: UnicodeScalar(0xF07C)!, in: bold)
            .hasPrefix("JetBrainsMonoNFM"))
    }

    /// Regression: matching on `.family` and letting CoreText pick returned
    /// *Courier New Italic* for "Courier New", which put the whole terminal in
    /// italics. Caught by looking at the picker, not by a passing test.
    func testChosenFaceIsNeverItalic() {
        for family in ["Courier New", "Menlo", "Academy Engraved LET"] {
            guard TerminalFont.isInstalled(family: family) else { continue }
            for bold in [false, true] {
                let font = TerminalFont.font(family: family, size: 14, bold: bold)
                XCTAssertFalse(
                    font.fontDescriptor.symbolicTraits.contains(.traitItalic),
                    "\(family) bold=\(bold) resolved to the italic face \(font.fontName)"
                )
                XCTAssertEqual(font.familyName, family,
                               "\(family) resolved outside its own family: \(font.fontName)")
            }
        }
    }

    /// Bold has to be a real bold face when the family ships one.
    func testBoldPicksTheBoldFaceWhenThereIsOne() {
        let bold = TerminalFont.font(family: "Menlo", size: 14, bold: true)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold), bold.fontName)
        let regular = TerminalFont.font(family: "Menlo", size: 14, bold: false)
        XCTAssertFalse(regular.fontDescriptor.symbolicTraits.contains(.traitBold), regular.fontName)
    }

    // MARK: Fallbacks that must never reach SF

    func testEmptyFamilyIsTheBundledFont() {
        for bold in [false, true] {
            let font = TerminalFont.font(family: "", size: 14, bold: bold)
            XCTAssertTrue(font.fontName.hasPrefix("JetBrainsMonoNFM"), font.fontName)
        }
        XCTAssertTrue(TerminalFont.font(family: "   ", size: 14, bold: false)
            .fontName.hasPrefix("JetBrainsMonoNFM"))
    }

    /// The failure this guards is silent and ugly: `UIFont(descriptor:)` never
    /// returns nil, so an uninstalled family resolves to a proportional system
    /// face and the whole grid shears.
    func testUninstalledFamilyIsTheBundledFont() {
        let font = TerminalFont.font(family: "Berkeley Mono Not Installed Here",
                                     size: 14, bold: false)
        XCTAssertTrue(font.fontName.hasPrefix("JetBrainsMonoNFM"),
                      "an unknown family must land on the bundled Nerd Font, got \(font.fontName)")
        XCTAssertFalse(TerminalFont.isInstalled(family: "Berkeley Mono Not Installed Here"))
    }

    // MARK: Enumeration

    /// The width test, not the symbolic trait, is what will actually catch a
    /// profile-installed font: plenty of them never set the fixed-pitch flag.
    /// The fixture is registered at runtime exactly like a profile font is, so
    /// this is the enumeration path a side-loaded font really takes.
    func testEnumerationFindsTheRuntimeRegisteredFamily() {
        let families = TerminalFont.availableMonospaceFamilies()
        XCTAssertTrue(families.contains(Self.fixtureFamily),
                      "runtime-registered monospaced family missing from \(families)")
        XCTAssertEqual(families, families.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }, "families must be sorted")
        XCTAssertEqual(Set(families).count, families.count, "families must be deduplicated")
        // The bundled face is offered as the default option, not as a family,
        // so it must not appear twice.
        XCTAssertFalse(families.contains(TerminalFont.bundledFamilyName))
    }

    func testEnumerationRejectsProportionalFamilies() {
        let families = TerminalFont.availableMonospaceFamilies()
        for proportional in ["Helvetica", "Times New Roman", "Georgia"] {
            XCTAssertFalse(families.contains(proportional), proportional)
        }
        XCTAssertTrue(TerminalFont.isMonospaced(family: "Menlo"))
        XCTAssertFalse(TerminalFont.isMonospaced(family: "Helvetica"))
    }

    func testPromptIconDetectionIsMeasuredNotGuessed() {
        // The fixture has powerline but not the folder icon, so it is not a
        // fully patched font and the picker must not claim it is.
        XCTAssertFalse(TerminalFont.hasPromptIcons(family: Self.fixtureFamily))
        XCTAssertFalse(TerminalFont.hasPromptIcons(family: "Menlo"))
        XCTAssertTrue(TerminalFont.hasPromptIcons(family: TerminalFont.bundledFamilyName))
    }

    // MARK: Picker options

    func testOptionsLeadWithTheBundledFace() {
        let options = TerminalFont.options()
        let first = options.first
        XCTAssertEqual(first?.family, "")
        XCTAssertTrue(first?.isBundled == true)
        XCTAssertTrue(first?.hasPromptIcons == true)
        XCTAssertFalse(first?.isMissing == true)
        XCTAssertTrue(options.contains { $0.family == Self.fixtureFamily })
    }

    /// A removed configuration profile must read as a named state, not as the
    /// setting having quietly reset itself.
    func testOptionsKeepASelectionThatIsNoLongerInstalled() {
        let options = TerminalFont.options(selected: "Berkeley Mono")
        let row = options.first { $0.family == "Berkeley Mono" }
        XCTAssertNotNil(row, "a selected but uninstalled family must still be listed")
        XCTAssertTrue(row?.isMissing == true)
        XCTAssertFalse(row?.hasPromptIcons == true)
    }

    func testOptionsDoNotDuplicateAnInstalledSelection() {
        let options = TerminalFont.options(selected: Self.fixtureFamily)
        XCTAssertEqual(options.filter { $0.family == Self.fixtureFamily }.count, 1)
        XCTAssertFalse(options.first { $0.family == Self.fixtureFamily }?.isMissing == true)
    }
}
