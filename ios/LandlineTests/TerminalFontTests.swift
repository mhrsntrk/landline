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
