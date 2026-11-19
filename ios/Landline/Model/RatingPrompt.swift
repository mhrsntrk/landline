import Foundation

// When to ask for an App Store rating, and nothing else. The system decides
// whether the prompt actually appears (at most three times a year); this only
// decides when the app is allowed to offer it.
//
// The rule: someone has had three sessions that held a live shell for at least
// a minute, they still have access (an expired trial is the worst moment to
// ask), and they have not been asked on this version yet. The ask happens after
// the terminal is closed, never while a shell is on screen.

/// How many terminal screens are on screen right now. SwiftUI does not promise
/// whether a replacing terminal's `onAppear` runs before or after the old one's
/// `onDisappear`, so the prompt checks this count instead of a flag order.
@MainActor enum TerminalPresence {
    static var visible = 0
}

struct RatingPrompt {
    static let minimumLive: TimeInterval = 60
    static let sessionsNeeded = 3

    static let countKey = "ratingPrompt.goodSessions"
    static let askedVersionKey = "ratingPrompt.askedVersion"
    /// Watched by `RootView` through `@AppStorage`. Set when a session that
    /// just ended makes the app eligible; cleared when the prompt is offered.
    static let pendingKey = "ratingPrompt.pending"

    let defaults: UserDefaults
    let version: String

    init(defaults: UserDefaults = .standard,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.defaults = defaults
        self.version = version
    }

    var goodSessions: Int { defaults.integer(forKey: Self.countKey) }
    var askedThisVersion: Bool { defaults.string(forKey: Self.askedVersionKey) == version }

    /// Records one terminal visit. Returns true, and sets the pending flag,
    /// when this visit is the one that makes the app eligible to ask.
    @discardableResult
    func recordSession(liveFor seconds: TimeInterval, hasAccess: Bool) -> Bool {
        guard seconds >= Self.minimumLive else { return false }
        let count = goodSessions + 1
        defaults.set(count, forKey: Self.countKey)
        guard hasAccess, count >= Self.sessionsNeeded, !askedThisVersion else { return false }
        defaults.set(true, forKey: Self.pendingKey)
        return true
    }

    /// Called right before the system prompt is requested.
    func markAsked() {
        defaults.set(version, forKey: Self.askedVersionKey)
        defaults.set(false, forKey: Self.pendingKey)
    }
}
