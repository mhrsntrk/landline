import XCTest
@testable import Landline

/// The palettes are the one part of this app the audience can check at a
/// glance: they read these colours every day, and a single wrong hex is noticed
/// instantly. Every value in `TerminalPalette` is transcribed from the scheme's
/// own repository, so these tests exist to prove the transcription is complete
/// and internally consistent, and that nothing here is a placeholder someone
/// meant to come back to.
final class TerminalPaletteTests: XCTestCase {

    /// Everything except `matchSystem`, which is a rule rather than a palette
    /// and is covered separately.
    private var concreteSchemes: [TerminalColorScheme] {
        TerminalColorScheme.allCases.filter { $0 != .matchSystem }
    }

    private func palette(_ scheme: TerminalColorScheme, light: Bool = false) -> TerminalPalette {
        TerminalPalette.resolve(scheme: scheme, systemIsLight: light)
    }

    // MARK: Shape

    func testOneDarkProIsTheDefaultAndComesFirst() {
        XCTAssertEqual(TerminalColorScheme.allCases.first, .oneDarkPro,
                       "PRODUCT.md pins One Dark Pro as the default; it leads the picker")
        XCTAssertEqual(Host().colorScheme, .oneDarkPro)
        XCTAssertEqual(TerminalColorScheme.allCases.last, .matchSystem,
                       "the follow-the-system rule sorts last, after the palettes")
    }

    func testEverySchemeResolvesToAFullSixteenColourPalette() {
        for scheme in TerminalColorScheme.allCases {
            for light in [false, true] {
                let palette = palette(scheme, light: light)
                XCTAssertEqual(palette.ansiHexRGB.count, 16,
                               "\(scheme.rawValue) must supply 8 normal plus 8 bright")
                XCTAssertEqual(palette.ansi.count, 16, "\(scheme.rawValue) conversion dropped a colour")
                for hex in palette.ansiHexRGB {
                    XCTAssertLessThanOrEqual(hex, 0xFFFFFF, "\(scheme.rawValue) has a hex outside 24-bit RGB")
                }
                XCTAssertLessThanOrEqual(palette.foregroundHexRGB, 0xFFFFFF)
                XCTAssertLessThanOrEqual(palette.backgroundHexRGB, 0xFFFFFF)
                XCTAssertLessThanOrEqual(palette.cursorHexRGB, 0xFFFFFF)
                XCTAssertLessThanOrEqual(palette.selectionHexRGB, 0xFFFFFF)
                XCTAssertNotEqual(palette.foregroundHexRGB, palette.backgroundHexRGB,
                                  "\(scheme.rawValue) would render invisible text")
                XCTAssertNotEqual(palette.cursorHexRGB, palette.backgroundHexRGB,
                                  "\(scheme.rawValue) would render an invisible cursor")
            }
        }
    }

    /// The failure this is really guarding: a scheme added by copying the row
    /// above it and forgetting to paste the new numbers in.
    func testNoTwoSchemesShareAPalette() {
        var seen: [String: TerminalColorScheme] = [:]
        for scheme in concreteSchemes {
            let key = palette(scheme).ansiHexRGB.map(String.init).joined(separator: ",")
            if let clash = seen[key] {
                XCTFail("\(scheme.rawValue) has the same 16 colours as \(clash.rawValue)")
            }
            seen[key] = scheme
        }
        XCTAssertEqual(seen.count, concreteSchemes.count)
    }

    /// Within one ramp every colour is a different colour. Repetition *across*
    /// the two ramps is not an error — Nord, Catppuccin and Rosé Pine all reuse
    /// their normal hues as bright hues on purpose — so the two runs of eight
    /// are checked separately rather than as one set of sixteen.
    func testEachRampIsInternallyDistinct() {
        for scheme in concreteSchemes {
            let ansi = palette(scheme).ansiHexRGB
            let normal = Set(ansi[0..<8])
            let bright = Set(ansi[8..<16])
            XCTAssertEqual(normal.count, 8, "\(scheme.rawValue) repeats a colour inside its normal ramp")
            XCTAssertEqual(bright.count, 8, "\(scheme.rawValue) repeats a colour inside its bright ramp")
        }
    }

    /// A palette left half-written would show up as a run of identical greys or
    /// a black hole where a hue should be.
    func testNoSchemeContainsPlaceholderColours() {
        for scheme in concreteSchemes {
            let ansi = palette(scheme).ansiHexRGB
            let distinct = Set(ansi)
            // 9 is the real floor, set by Rosé Pine: eight normal hues plus one
            // extra grey, because it reuses its whole normal ramp as its bright
            // ramp. Anything below that is a palette that was not finished.
            XCTAssertGreaterThanOrEqual(distinct.count, 9,
                                        "\(scheme.rawValue) has too few distinct colours to be a real scheme")
            // Every scheme here has a red, a green, a yellow, a blue, a magenta
            // and a cyan that are actually chromatic. A grey in one of those
            // slots means a slot was skipped. Rosé Pine's "green" is its pine
            // (#31748F, a teal) and Gruvbox's "blue" is #458588, so the bar is
            // "not a neutral", not "matches its name".
            for index in 1...6 {
                XCTAssertFalse(isNeutral(ansi[index]),
                               "\(scheme.rawValue) ANSI \(index) is a grey where a hue belongs")
            }
        }
    }

    // MARK: The exact numbers

    /// The one scheme whose hexes the owner verified by hand before the work
    /// started. If a future edit drifts, this is where it gets caught.
    func testTokyoNightMatchesTheVerifiedSource() {
        let tokyo = palette(.tokyoNight)
        XCTAssertEqual(tokyo.backgroundHexRGB, 0x1A1B26)
        XCTAssertEqual(tokyo.foregroundHexRGB, 0xC0CAF5)
        XCTAssertEqual(Array(tokyo.ansiHexRGB[0..<8]),
                       [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6])
    }

    /// One Dark Pro is the only palette that is also the app's chrome, so it
    /// must stay identical to DESIGN.md's table, which Theme owns.
    func testOneDarkProStillComesFromTheDesignTokens() {
        let onedark = palette(.oneDarkPro)
        XCTAssertEqual(onedark.ansiHexRGB, Theme.ansiHexRGB)
        XCTAssertEqual(onedark.foregroundHexRGB, Theme.terminalForegroundHexRGB)
        XCTAssertEqual(onedark.backgroundHexRGB, Theme.terminalBackgroundHexRGB)
        XCTAssertEqual(onedark.cursorHexRGB, Theme.terminalCursorHexRGB)
    }

    /// Solarized keeps a darker colour at bright-black than at black, which
    /// looks like a transcription bug and is not one: base03 is darker than
    /// base02 by design. Pinned so nobody "fixes" it.
    func testSolarizedKeepsItsInvertedGreyRamp() {
        let solarized = palette(.solarizedDark)
        XCTAssertEqual(solarized.ansiHexRGB[0], 0x073642, "base02")
        XCTAssertEqual(solarized.ansiHexRGB[8], 0x002B36, "base03, darker than base02 on purpose")
        XCTAssertEqual(solarized.backgroundHexRGB, 0x002B36)
    }

    /// Catppuccin Latte is the only light palette that a user can pick outright,
    /// and a light terminal is only usable if ANSI black is dark.
    func testCatppuccinLatteIsLightAndKeepsBlackDark() {
        let latte = palette(.catppuccinLatte)
        XCTAssertFalse(latte.isDark)
        XCTAssertTrue(TerminalColorScheme.catppuccinLatte.isLight)
        XCTAssertEqual(latte.backgroundHexRGB, 0xEFF1F5)
        XCTAssertGreaterThan(contrast(latte.ansiHexRGB[0], latte.backgroundHexRGB), 4.5,
                             "ANSI black must be readable on a light ground")
        for scheme in concreteSchemes where scheme != .catppuccinLatte {
            XCTAssertTrue(palette(scheme).isDark, "\(scheme.rawValue) is meant to be a dark scheme")
            XCTAssertFalse(scheme.isLight)
        }
    }

    // MARK: matchSystem

    func testMatchSystemFollowsThePhoneAndNothingElseDoes() {
        XCTAssertEqual(palette(.matchSystem, light: false).backgroundHexRGB,
                       TerminalPalette.oneDarkPro.backgroundHexRGB)
        XCTAssertEqual(palette(.matchSystem, light: true).backgroundHexRGB,
                       TerminalPalette.matchSystemLight.backgroundHexRGB)
        XCTAssertFalse(palette(.matchSystem, light: true).isDark)
        // Every other scheme is the scheme the user picked, whatever the phone
        // is doing. A host set to Gruvbox does not turn white at sunrise.
        for scheme in concreteSchemes {
            XCTAssertEqual(palette(scheme, light: true).ansiHexRGB,
                           palette(scheme, light: false).ansiHexRGB,
                           "\(scheme.rawValue) must not depend on the system appearance")
        }
    }

    // MARK: Persistence

    /// `hosts.json` stores these strings. Changing one silently resets every
    /// host that used it, so the raw values are pinned literally.
    func testRawValuesArePermanent() {
        XCTAssertEqual(TerminalColorScheme.oneDarkPro.rawValue, "oneDarkPro")
        XCTAssertEqual(TerminalColorScheme.matchSystem.rawValue, "matchSystem")
        XCTAssertEqual(TerminalColorScheme.catppuccinMocha.rawValue, "catppuccinMocha")
        XCTAssertEqual(TerminalColorScheme.tokyoNight.rawValue, "tokyoNight")
        XCTAssertEqual(TerminalColorScheme.gruvboxDark.rawValue, "gruvboxDark")
        XCTAssertEqual(TerminalColorScheme.dracula.rawValue, "dracula")
        XCTAssertEqual(TerminalColorScheme.nord.rawValue, "nord")
        XCTAssertEqual(TerminalColorScheme.solarizedDark.rawValue, "solarizedDark")
        XCTAssertEqual(TerminalColorScheme.rosePine.rawValue, "rosePine")
        XCTAssertEqual(TerminalColorScheme.catppuccinLatte.rawValue, "catppuccinLatte")
        XCTAssertEqual(Set(TerminalColorScheme.allCases.map(\.rawValue)).count,
                       TerminalColorScheme.allCases.count)
    }

    func testEverySchemeRoundTripsThroughAStoredHost() throws {
        for scheme in TerminalColorScheme.allCases {
            var host = Host()
            host.hostname = "rack.tail4f1a.ts.net"
            host.colorScheme = scheme
            let decoded = try XCTUnwrap(Host.decodeList(from: Host.encodeList([host])).first)
            XCTAssertEqual(decoded.colorScheme, scheme, "\(scheme.rawValue) did not survive hosts.json")

            let document = #"[{"hostname":"a.ts.net","colorScheme":"\#(scheme.rawValue)"}]"#
            let fromDisk = try XCTUnwrap(Host.decodeList(from: Data(document.utf8)).first)
            XCTAssertEqual(fromDisk.colorScheme, scheme)
        }
    }

    /// A palette written by a newer build must not cost the user their host
    /// list; it decodes to the default instead.
    func testUnknownRawValuesFallBackToTheDefault() throws {
        for raw in ["catppuccinFrappe", "", "ONEDARKPRO", "oneDarkPro2", "🌘"] {
            XCTAssertEqual(TerminalColorScheme(rawValue: raw) ?? .oneDarkPro, .oneDarkPro,
                           "unknown raw value \(raw) must not resolve to a real scheme")
        }
        let document = #"[{"hostname":"a.ts.net","colorScheme":"catppuccinFrappe"}]"#
        let host = try XCTUnwrap(Host.decodeList(from: Data(document.utf8)).first)
        XCTAssertEqual(host.colorScheme, .oneDarkPro)
        XCTAssertEqual(host.hostname, "a.ts.net", "the rest of the host must survive intact")
    }

    // MARK: Contrast

    /// These are published schemes and matching them matters more than our
    /// preference, so a scheme under 4.5:1 is reported rather than failed. The
    /// one to watch is Solarized Dark, whose low contrast is the entire point
    /// of the scheme.
    func testForegroundContrastAgainstItsOwnBackground() {
        var under: [String] = []
        for scheme in TerminalColorScheme.allCases {
            for light in [false, true] where scheme == .matchSystem || !light {
                let palette = palette(scheme, light: light)
                let ratio = contrast(palette.foregroundHexRGB, palette.backgroundHexRGB)
                let name = scheme.rawValue + (scheme == .matchSystem ? (light ? " (light)" : " (dark)") : "")
                print(String(format: "palette contrast %@ %.2f:1", name, ratio))
                // A hard floor well below the warning threshold: anything this
                // low is a transcription error, not a design opinion.
                XCTAssertGreaterThan(ratio, 3.0, "\(name) is unreadable, which means a wrong hex")
                if ratio < 4.5 { under.append(String(format: "%@ %.2f:1", name, ratio)) }
            }
        }
        if !under.isEmpty {
            print("NOTE: below the 4.5:1 warning threshold, kept because they match the published scheme: "
                  + under.joined(separator: ", "))
        }
    }

    // MARK: Helpers

    private func components(_ hex: UInt32) -> [Double] {
        [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { Double($0) / 255 }
    }

    /// WCAG relative luminance.
    private func luminance(_ hex: UInt32) -> Double {
        let linear = components(hex).map { channel -> Double in
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    /// True when a colour has almost no chroma, i.e. it is a grey.
    private func isNeutral(_ hex: UInt32) -> Bool {
        let channels = components(hex)
        return (channels.max()! - channels.min()!) < 0.08
    }
}
