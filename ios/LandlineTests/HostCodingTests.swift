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
        XCTAssertNil(host.lastShell)
        XCTAssertNil(host.lastAttachedAt)
    }

    func testEmptyObjectDecodesToADefaultHost() throws {
        let hosts = try Host.decodeList(from: Data("[{}]".utf8))
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.hostname, "")
        XCTAssertEqual(host.port, 443)
        XCTAssertEqual(host.colorScheme, .oneDarkPro)
    }

    func testUnknownPaletteFallsBackToDefault() throws {
        let document = #"[{"hostname":"a.ts.net","colorScheme":"solarizedFromTheFuture"}]"#
        let host = try XCTUnwrap(Host.decodeList(from: Data(document.utf8)).first)
        XCTAssertEqual(host.colorScheme, .oneDarkPro)
    }

    func testRoundTripKeepsNewFields() throws {
        var host = Host()
        host.hostname = "rack.tail4f1a.ts.net"
        host.startCommand = "tmuxon"
        host.colorScheme = .matchSystem
        host.lastShell = "/bin/zsh"
        let decoded = try XCTUnwrap(Host.decodeList(from: Host.encodeList([host])).first)
        XCTAssertEqual(decoded.startCommand, "tmuxon")
        XCTAssertEqual(decoded.colorScheme, .matchSystem)
        XCTAssertEqual(decoded.lastShell, "/bin/zsh")
        XCTAssertEqual(decoded.id, host.id)
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
