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
// installed with a configuration profile is almost
// never Nerd Font patched, so making it the terminal face naively brings the
// tofu bug straight back. These tests prove the composed font puts the user's
// glyphs on screen where it has them and the bundled font's glyphs where it
// does not, per codepoint, which is the only behaviour that is actually useful.

final class TerminalFontCascadeTests: XCTestCase {

    /// A subset of the bundled Nerd Font with Latin and the two powerline
    /// codepoints kept and the wider Nerd Font icons stripped, renamed to its
    /// own family. It is here because the interesting case is *partial*
    /// coverage: a font that carries some prompt glyphs and not others, which
    /// is exactly the measured shape of a partially patched face. Nothing
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
        let font = TerminalFont.font(family: "A Font That Is Not Installed",
                                     size: 14, bold: false)
        XCTAssertTrue(font.fontName.hasPrefix("JetBrainsMonoNFM"),
                      "an unknown family must land on the bundled Nerd Font, got \(font.fontName)")
        XCTAssertFalse(TerminalFont.isInstalled(family: "A Font That Is Not Installed"))
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
        let options = TerminalFont.options(selected: "A Profile Installed Font")
        let row = options.first { $0.family == "A Profile Installed Font" }
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

// MARK: - Provider-installed fonts
//
// The bug this suite covers is the one that shipped in build 2: a phone with
// a font installed through a provider app showed only Courier New and Menlo,
// because CoreText withholds provider-installed fonts from other processes
// until they call `CTFontManagerRequestFonts` (CTFontManager.h). The simulator
// has no provider-installed font, so the *success* path of that call cannot be
// exercised here — only on the owner's phone. What is testable here is
// everything around it: that all three enumeration sources are actually asked
// and counted, that a name which cannot be resolved is reported as a failure
// rather than silently swallowed, and that the once-per-launch guard on
// request-on-use holds.

final class TerminalFontRequestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TerminalFont.resetRequestGuard()
    }

    override func tearDown() {
        TerminalFont.resetRequestGuard()
        super.tearDown()
    }

    /// The union has to keep asking all three enumeration APIs: a font visible
    /// to one source and not another is the whole question, and one count
    /// cannot express it. Counted per source so this test can say which one
    /// went quiet.
    func testCensusCountsEverySourceSeparately() {
        let census = TerminalFont.candidates().census
        XCTAssertGreaterThan(census.system, 0, "UIFont.familyNames sees nothing at all")
        XCTAssertGreaterThan(census.available, 0,
                             "CTFontManagerCopyAvailableFontFamilyNames sees nothing at all")
        // Not asserted to be non-zero: CTFontManager.h says the persistent
        // scope can only return descriptors registered by *this* process on
        // iOS, so a font installed by another app can never appear here. Zero
        // is the expected reading and is itself the diagnosis.
        XCTAssertGreaterThanOrEqual(census.registered, 0)
    }

    /// The union must not let the private system faces (.SFUI and friends) or a
    /// proportional family in through the unresolvable door.
    func testUnionDoesNotAdmitPrivateOrProportionalFamilies() {
        let list = TerminalFont.candidates().list
        for candidate in list {
            XCTAssertFalse(candidate.family.hasPrefix("."),
                           "private system face \(candidate.family) leaked into the picker")
            if candidate.isResolvable {
                XCTAssertTrue(TerminalFont.isMonospaced(family: candidate.family),
                              "\(candidate.family) is not monospaced")
            }
        }
        XCTAssertFalse(list.contains { $0.family == "Helvetica" })
        XCTAssertTrue(list.contains { $0.family == "Menlo" && $0.isResolvable })
    }

    /// Everything the simulator can enumerate is drawable, so the whole list
    /// must come back resolvable. On the owner's phone a name that arrives
    /// unresolvable is the interesting case, and it has to be *kept*.
    func testEnumeratedFamiliesAreResolvableHere() {
        for candidate in TerminalFont.candidates().list {
            XCTAssertEqual(candidate.isResolvable,
                           TerminalFont.isResolvable(family: candidate.family),
                           candidate.family)
        }
    }

    func testResolvedFamilyAcceptsEitherKindOfName() {
        XCTAssertEqual(TerminalFont.resolvedFamily(for: "Menlo"), "Menlo")
        // A PostScript face name is what someone copies out of a font app, and
        // it has to come back as the *family*, which is what Host.fontFamily
        // is documented to hold.
        XCTAssertEqual(TerminalFont.resolvedFamily(for: "Menlo-Regular"), "Menlo")
        XCTAssertEqual(TerminalFont.resolvedFamily(for: "  Menlo  "), "Menlo")
        XCTAssertNil(TerminalFont.resolvedFamily(for: ""))
        XCTAssertNil(TerminalFont.resolvedFamily(for: "A Font That Is Not Installed"))
    }

    /// The failure path, which is the only one a simulator can reach: a name
    /// nothing can resolve must come back as a plain "no", so the picker can
    /// say so instead of appearing to have worked.
    func testRequestingAnUnknownNameFails() {
        let done = expectation(description: "request completed")
        var outcome: TerminalFont.RequestOutcome?
        TerminalFont.requestAccess(name: "A Font That Is Not Installed") { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        let result = outcome
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.succeeded == true)
        XCTAssertNil(result?.resolvedFamily)
    }

    /// An empty name must never reach CoreText, because CoreText's answer to it
    /// is a system dialog with nothing in it.
    func testRequestingAnEmptyNameIsARefusalNotADialog() {
        let done = expectation(description: "request completed")
        TerminalFont.requestAccess(name: "   ") { outcome in
            XCTAssertTrue(outcome.unresolved.isEmpty)
            XCTAssertNil(outcome.resolvedFamily)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// Request-on-use must not put a system dialog in front of someone whose
    /// font is already working, and must not put one up twice in a launch.
    func testRequestOnUseSkipsWhatItCannotHelp() {
        for family in ["", "   ", "Menlo"] {
            let done = expectation(description: "skipped \(family)")
            TerminalFont.requestIfUnresolved(family: family) { changed in
                XCTAssertFalse(changed)
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testRequestOnUseAsksOnlyOncePerLaunch() {
        let missing = "A Font That Is Not Installed"
        let first = expectation(description: "first ask reaches CoreText")
        TerminalFont.requestIfUnresolved(family: missing) { changed in
            XCTAssertFalse(changed, "nothing can resolve this name in a simulator")
            first.fulfill()
        }
        wait(for: [first], timeout: 20)

        // Second time it must short-circuit, and short-circuiting is
        // observable: the completion runs synchronously, before this returns.
        var ranSynchronously = false
        TerminalFont.requestIfUnresolved(family: missing) { changed in
            XCTAssertFalse(changed)
            ranSynchronously = true
        }
        XCTAssertTrue(ranSynchronously, "a repeat request must not reach CoreText again")
    }
}

// MARK: - Size

final class TerminalFontSizeTests: XCTestCase {

    func testHostSizeFallsBackToTheAppDefault() {
        XCTAssertEqual(TerminalFont.size(forHost: 0), TerminalFont.size)
        XCTAssertEqual(TerminalFont.size(forHost: -3), TerminalFont.size)
    }

    func testHostSizeIsClampedToTheRangeTheStepperOffers() {
        XCTAssertEqual(TerminalFont.size(forHost: 9), 9)
        XCTAssertEqual(TerminalFont.size(forHost: 22), 22)
        XCTAssertEqual(TerminalFont.size(forHost: 8), TerminalFont.minSize)
        XCTAssertEqual(TerminalFont.size(forHost: 23), TerminalFont.maxSize)
        XCTAssertEqual(TerminalFont.clamp(1000), TerminalFont.maxSize)
        XCTAssertEqual(TerminalFont.clamp(-1000), TerminalFont.minSize)
    }

    /// The composed font has to honour the size, not just the family: the
    /// stepper is worthless if the cascade quietly resets it.
    func testComposedFontRendersAtTheRequestedSize() {
        for size in [TerminalFont.minSize, 13, TerminalFont.maxSize] {
            XCTAssertEqual(TerminalFont.font(family: "", size: size, bold: false).pointSize, size)
            XCTAssertEqual(TerminalFont.font(family: "Menlo", size: size, bold: false).pointSize, size)
        }
    }
}

/// The picker once said "NOT INSTALLED / FALLS BACK TO BUNDLED" about
/// a profile-installed font in the same breath as confirming the request succeeded, and
/// the terminal quietly rendered in the bundled face. The cause was two
/// different notions of "installed": the request path asked whether the font
/// instantiates, while everything else asked `UIFont.fontNames(forFamilyName:)`,
/// which on iOS never names a font a provider app installed.
final class FontInstalledConsistencyTests: XCTestCase {
    /// If a name resolves, every other code path must agree it is usable.
    /// This is the invariant the bug violated.
    func testResolvedFamiliesAreAlwaysReportedInstalled() {
        for name in ["Menlo", "Courier New", "JetBrainsMonoNFM-Regular", "Menlo-Regular"] {
            guard let resolved = TerminalFont.resolvedFamily(for: name) else { continue }
            XCTAssertTrue(
                TerminalFont.isInstalled(family: resolved),
                "\(name) resolved to '\(resolved)' but isInstalled said no; that split is exactly "
                    + "what made the terminal fall back to the bundled face for a working font."
            )
        }
    }

    /// A resolvable family must also produce its own face, not the fallback.
    func testResolvedFamiliesActuallyRenderInThatFamily() {
        for name in ["Menlo", "Courier New"] {
            guard let resolved = TerminalFont.resolvedFamily(for: name) else { continue }
            let font = TerminalFont.font(family: resolved, size: 14, bold: false)
            XCTAssertEqual(
                font.familyName, resolved,
                "font(family:) returned \(font.familyName) for '\(resolved)'; a silent fallback here "
                    + "is invisible until someone looks at a screenshot."
            )
        }
    }

    func testUnknownFamiliesAreStillRejected() {
        XCTAssertFalse(TerminalFont.isInstalled(family: "Definitely Not A Font 8817"))
        XCTAssertNil(TerminalFont.resolvedFamily(for: "Definitely Not A Font 8817"))
    }
}


/// `faceName` used to start from `UIFont.fontNames(forFamilyName:)`, which
/// returns an empty array for a font a provider app installed. The terminal
/// then rendered in the bundled face while the picker showed the user's font
/// as selected: the same blindness as `isInstalled`, one layer down, and
/// invisible without looking at real output on a real device.
final class FaceResolutionTests: XCTestCase {
    /// Every installed family must yield a usable face in both weights.
    /// A nil face is what silently swapped the font.
    func testInstalledFamiliesAlwaysYieldAFace() {
        let families = ["Menlo", "Courier New", TerminalFont.bundledFamilyName]
        for family in families where TerminalFont.isInstalled(family: family) {
            for bold in [false, true] {
                let font = TerminalFont.font(family: family, size: 14, bold: bold)
                XCTAssertEqual(
                    font.familyName, family,
                    "\(family) bold=\(bold) fell back to \(font.familyName)"
                )
            }
        }
    }

    /// Bold must not silently become a different family.
    func testBoldStaysInFamily() {
        for family in ["Menlo", "Courier New"] where TerminalFont.isInstalled(family: family) {
            let regular = TerminalFont.font(family: family, size: 14, bold: false)
            let bold = TerminalFont.font(family: family, size: 14, bold: true)
            XCTAssertEqual(regular.familyName, bold.familyName)
        }
    }
}
