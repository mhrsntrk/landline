import Foundation
import Observation

enum LandlineProducts {
    static let trial = "com.landlineclient.app.trial7days"
    static let unlock = "com.landlineclient.app.fullUnlock"
    static let all: Set<String> = [trial, unlock]
    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60
}

/// Populated only from verified StoreKit transactions in the production client.
struct PurchaseEntitlements: Equatable {
    var unlocked = false
    var trialStartedAt: Date?
    var trialRevoked = false
}

enum AccessStatus: Equatable {
    case checking, trialAvailable, unlocked, expired
    case trial(until: Date)

    var hasFullAccess: Bool {
        switch self {
        case .unlocked, .trial: true
        default: false
        }
    }
}

@MainActor @Observable
final class LandlineAccess {
    private(set) var entitlements: PurchaseEntitlements?

    init(entitlements: PurchaseEntitlements? = nil) {
        self.entitlements = entitlements
    }

    func update(_ entitlements: PurchaseEntitlements) {
        self.entitlements = entitlements
    }

    func status(at now: Date = .now) -> AccessStatus {
        guard let entitlements else { return .checking }
        if entitlements.unlocked { return .unlocked }
        guard let start = entitlements.trialStartedAt else { return .trialAvailable }
        let end = start.addingTimeInterval(LandlineProducts.trialDuration)
        guard !entitlements.trialRevoked, now >= start, now < end else { return .expired }
        return .trial(until: end)
    }

    func hasFullAccess(at now: Date = .now) -> Bool { status(at: now).hasFullAccess }

    /// iOS receipts use CFBundleVersion, not the marketing version. Build 19
    /// introduces purchases. Sandbox receipts report 1.0 and must not unlock.
    static func isExistingCustomer(originalAppVersion: String, isProduction: Bool) -> Bool {
        guard isProduction, let build = Int(originalAppVersion), build > 0 else { return false }
        return build < 19
    }
}
