import XCTest
@testable import Landline

/// The host list is typed in by hand, so decoding must never throw on a
/// document written by an older build.
final class HostCodingTests: XCTestCase {

    /// Exactly the shape `hosts.json` had before `startCommand` and
    /// `colorScheme` existed.
    private let legacyDocument = """
    [
      {
        "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
        "name": "studio",
        "hostname": "studio.tail4f1a.ts.net",
        "port": 443,
        "useTLS": true,
        "requireFaceID": false
      }
    ]
    """

    func testLegacyDocumentDecodesWithDefaults() throws {
        let hosts = try Host.decodeList(from: Data(legacyDocument.utf8))
        XCTAssertEqual(hosts.count, 1)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.name, "studio")
        XCTAssertEqual(host.hostname, "studio.tail4f1a.ts.net")
        XCTAssertEqual(host.port, 443)
        XCTAssertTrue(host.useTLS)
        XCTAssertEqual(host.startCommand, "")
        XCTAssertEqual(host.colorScheme, .oneDarkPro)
        XCTAssertEqual(host.fontFamily, "", "no stored font means the bundled Nerd Font")
        XCTAssertEqual(host.fontSize, 0, "no stored size means the app-wide default")
        XCTAssertNil(host.lastShell)
        XCTAssertNil(host.lastAttachedAt)
    }

    func testEmptyObjectDecodesToADefaultHost() throws {
        let hosts = try Host.decodeList(from: Data("[{}]".utf8))
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.hostname, "")
        XCTAssertEqual(host.port, 443)
        XCTAssertEqual(host.colorScheme, .oneDarkPro)
        XCTAssertEqual(host.fontFamily, "")
        XCTAssertEqual(host.fontSize, 0)
    }

    /// The migration that matters for size: a host written before the setting
    /// existed must decode to the 0 sentinel, not to a literal 13, so it keeps
    /// following whatever the pinch gesture left in the app-wide default rather
    /// than jumping to a new size on the first launch of this build.
    func testLegacyHostHasNoOwnFontSize() throws {
        let host = try XCTUnwrap(Host.decodeList(from: Data(legacyDocument.utf8)).first)
        XCTAssertEqual(host.fontSize, 0)
        XCTAssertEqual(TerminalFont.size(forHost: host.fontSize), TerminalFont.size,
                       "0 must resolve to the app-wide default")
    }

    func testStoredFontSizeIsHonouredAndClamped() throws {
        let document = #"[{"hostname":"a.ts.net","fontSize":17}]"#
        let host = try XCTUnwrap(Host.decodeList(from: Data(document.utf8)).first)
        XCTAssertEqual(host.fontSize, 17)
        XCTAssertEqual(TerminalFont.size(forHost: host.fontSize), 17)
        // A size written by a build with a different range, or by a corrupted
        // file, must not be able to hand SwiftTerm a 400pt grid.
        XCTAssertEqual(TerminalFont.size(forHost: 400), TerminalFont.maxSize)
        XCTAssertEqual(TerminalFont.size(forHost: 1), TerminalFont.minSize)
    }

    func testUnknownPaletteFallsBackToDefault() throws {
        let document = #"[{"hostname":"a.ts.net","colorScheme":"solarizedFromTheFuture"}]"#
        let host = try XCTUnwrap(Host.decodeList(from: Data(document.utf8)).first)
        XCTAssertEqual(host.colorScheme, .oneDarkPro)
    }

    func testRoundTripKeepsNewFields() throws {
        var host = Host()
        host.hostname = "rack.tail4f1a.ts.net"
        host.startCommand = "tmux new -A -s main"
        host.colorScheme = .matchSystem
        host.fontFamily = "Menlo"
        host.fontSize = 16
        host.lastShell = "/bin/zsh"
        let decoded = try XCTUnwrap(Host.decodeList(from: Host.encodeList([host])).first)
        XCTAssertEqual(decoded.startCommand, "tmux new -A -s main")
        XCTAssertEqual(decoded.colorScheme, .matchSystem)
        XCTAssertEqual(decoded.fontFamily, "Menlo")
        XCTAssertEqual(decoded.fontSize, 16)
        XCTAssertEqual(decoded.lastShell, "/bin/zsh")
        XCTAssertEqual(decoded.id, host.id)
    }

    /// A font family is a plain string on purpose: the set of installed fonts
    /// is whatever configuration profiles the phone happens to carry, so any
    /// value must survive a round trip rather than being validated away.
    func testStoredFontFamilySurvivesEvenWhenNotInstalled() throws {
        let document = #"[{"hostname":"a.ts.net","fontFamily":"Menlo"}]"#
        let host = try XCTUnwrap(Host.decodeList(from: Data(document.utf8)).first)
        XCTAssertEqual(host.fontFamily, "Menlo")
    }

    func testValidation() {
        var host = Host()
        XCTAssertFalse(host.isValid)
        XCTAssertEqual(host.validationErrors.first?.field, "hostname")

        host.hostname = "macbook.tail4f1a.ts.net"
        XCTAssertTrue(host.isValid)

        host.port = 0
        XCTAssertEqual(host.validationErrors.first?.field, "port")
    }

    func testSessionAgeLabelIsCoarseAndNarrow() {
        var host = Host()
        XCTAssertEqual(host.sessionAgeLabel(), "—")
        let now = Date()
        host.lastAttachedAt = now.addingTimeInterval(-45)
        XCTAssertEqual(host.sessionAgeLabel(now: now), "45s")
        host.lastAttachedAt = now.addingTimeInterval(-14 * 60)
        XCTAssertEqual(host.sessionAgeLabel(now: now), "14m")
        host.lastAttachedAt = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(host.sessionAgeLabel(now: now), "3h")
        host.lastAttachedAt = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(host.sessionAgeLabel(now: now), "2d")
    }
}
