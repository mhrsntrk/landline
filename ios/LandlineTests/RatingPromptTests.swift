import XCTest
@testable import Landline

final class RatingPromptTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "RatingPromptTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func prompt(_ version: String = "1.5") -> RatingPrompt {
        RatingPrompt(defaults: defaults, version: version)
    }

    func testShortSessionsDoNotCount() {
        for _ in 0..<5 { XCTAssertFalse(prompt().recordSession(liveFor: 59, hasAccess: true)) }
        XCTAssertEqual(prompt().goodSessions, 0)
        XCTAssertFalse(defaults.bool(forKey: RatingPrompt.pendingKey))
    }

    func testThirdGoodSessionAsks() {
        XCTAssertFalse(prompt().recordSession(liveFor: 60, hasAccess: true))
        XCTAssertFalse(prompt().recordSession(liveFor: 600, hasAccess: true))
        XCTAssertTrue(prompt().recordSession(liveFor: 61, hasAccess: true))
        XCTAssertTrue(defaults.bool(forKey: RatingPrompt.pendingKey))
    }

    func testNoAskWithoutAccess() {
        for _ in 0..<4 { XCTAssertFalse(prompt().recordSession(liveFor: 120, hasAccess: false)) }
        // Sessions still count, so access returning (an unlock) asks next time.
        XCTAssertTrue(prompt().recordSession(liveFor: 120, hasAccess: true))
    }

    func testAsksOncePerVersion() {
        for _ in 0..<3 { prompt().recordSession(liveFor: 120, hasAccess: true) }
        prompt().markAsked()
        XCTAssertFalse(defaults.bool(forKey: RatingPrompt.pendingKey))
        XCTAssertFalse(prompt().recordSession(liveFor: 120, hasAccess: true))
        XCTAssertTrue(prompt("1.6").recordSession(liveFor: 120, hasAccess: true))
    }
}
