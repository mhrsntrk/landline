import XCTest
@testable import Landline

final class HostActivityTests: XCTestCase {
    private func decode(_ json: String) throws -> [HostSession] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([HostSession].self, from: Data(json.utf8))
    }

    func testOlderDaemonDecodesWithoutTheNewFields() throws {
        let sessions = try decode("""
        [{"id":"a","shell":"/bin/zsh","created_at":1,"attached":false,"idle_secs":5}]
        """)
        XCTAssertNil(sessions[0].outputIdleSecs)
        XCTAssertNil(sessions[0].attention)
        XCTAssertFalse(sessions[0].isActive)
    }

    func testAttentionAndActivityDecode() throws {
        let sessions = try decode("""
        [{"id":"a","shell":"/bin/zsh","created_at":1,"attached":false,"idle_secs":5,
          "output_idle_secs":3,"attention":{"secs_ago":40,"text":"Approve command?"}},
         {"id":"b","shell":"/bin/zsh","created_at":1,"attached":true,"idle_secs":5,
          "output_idle_secs":600,"attention":null}]
        """)
        XCTAssertEqual(sessions[0].attention, .init(secsAgo: 40, text: "Approve command?"))
        XCTAssertTrue(sessions[0].isActive)
        XCTAssertNil(sessions[1].attention)
        XCTAssertFalse(sessions[1].isActive)
    }

    func testOpenHostsRemembersBothWays() {
        let defaults = UserDefaults(suiteName: "HostActivityTests")!
        defaults.removePersistentDomain(forName: "HostActivityTests")
        let id = UUID()
        XCTAssertFalse(OpenHosts.contains(id, defaults: defaults))
        OpenHosts.mark(id, open: true, defaults: defaults)
        XCTAssertTrue(OpenHosts.contains(id, defaults: defaults))
        OpenHosts.mark(id, open: false, defaults: defaults)
        XCTAssertFalse(OpenHosts.contains(id, defaults: defaults))
    }

    /// The rule that keeps the list from spending unlock attempts: a host with
    /// no stored secret, never seen open, is not asked.
    func testListNeverAsksAnUnknownHost() {
        let defaults = UserDefaults(suiteName: "HostActivityTests.ask")!
        defaults.removePersistentDomain(forName: "HostActivityTests.ask")
        var host = Host()
        host.hostname = "box.tail.ts.net"
        XCTAssertFalse(HostActivity.mayAsk(host, defaults: defaults))
        OpenHosts.mark(host.id, open: true, defaults: defaults)
        XCTAssertTrue(HostActivity.mayAsk(host, defaults: defaults))
    }
}
