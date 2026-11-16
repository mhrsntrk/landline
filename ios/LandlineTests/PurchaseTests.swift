import XCTest
import SwiftUI
import UserNotifications

@testable import Landline

@MainActor final class PurchaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTerminalExpiryDetachesWithoutKillingOrForgettingTheSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hosts = HostStore(fileURL: directory.appendingPathComponent("hosts.json"))
        var host = Host(name: "test", hostname: "example.invalid")
        host.lastSessionID = "keep-this-session"
        hosts.add(host)
        let access = LandlineAccess(entitlements: .init(trialStartedAt: .now))
        let purchases = Purchases(access: access, client: StubPurchaseClient())
        let transport = FakeTransport()
        let connection = Connection(makeTransport: { transport })
        defer { connection.disconnect(sendDetach: true) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView:
            TerminalScreen(host: host, connection: connection)
                .environment(hosts)
                .environment(SettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
                .environment(purchases))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(transport.connectedTo)
        transport.deliverJSON(type: 0x82, #"{"session_id":"keep-this-session","cols":80,"rows":24,"replay_bytes":0,"shell":"/bin/zsh","host":"test","created_at":0}"#)
        // An already-open screen must expire without a tap or foreground event.
        access.update(.init(trialStartedAt: Date.now.addingTimeInterval(-604799)))
        try await Task.sleep(for: .seconds(2.2))
        XCTAssertTrue(transport.cancelled)
        XCTAssertTrue(transport.sentTypes.contains(0x06), "Expiry should detach the live session")
        XCTAssertFalse(transport.sentTypes.contains(0x07), "Expiry must never send KILL")
        XCTAssertEqual(hosts.host(id: host.id)?.lastSessionID, "keep-this-session")
        let socketsBefore = transport.sentRaw.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.sentRaw.count, socketsBefore, "Expired screen must not reconnect")
    }

    func testTrialIsExactlySevenDaysAndNeverStartsFromInstallOrRestore() {
        let access = LandlineAccess()
        XCTAssertEqual(access.status(at: now), .checking)
        access.update(PurchaseEntitlements())
        XCTAssertEqual(access.status(at: now), .trialAvailable)
        access.update(PurchaseEntitlements(trialStartedAt: now))
        let end = now.addingTimeInterval(604800)
        XCTAssertEqual(access.status(at: now), .trial(until: end))
        XCTAssertTrue(access.hasFullAccess(at: end.addingTimeInterval(-1)))
        XCTAssertEqual(access.status(at: end), .expired)
        XCTAssertFalse(access.hasFullAccess(at: now.addingTimeInterval(-1)))
        let restored = LandlineAccess(entitlements: access.entitlements)
        XCTAssertEqual(restored.status(at: end.addingTimeInterval(1)), .expired)
    }

    func testUnlockOverridesTrialAndRefundRemovesAccess() {
        let access = LandlineAccess(
            entitlements: PurchaseEntitlements(unlocked: true, trialStartedAt: now, trialRevoked: true))
        XCTAssertEqual(access.status(at: now.addingTimeInterval(6_048_000)), .unlocked)
        access.update(PurchaseEntitlements(trialStartedAt: now, trialRevoked: true))
        XCTAssertEqual(access.status(at: now), .expired)
    }

    func testExistingCustomersKeepAccessOnlyWithAProductionReceiptBeforeBuild19() {
        for build in ["1", "14", "18"] {
            XCTAssertTrue(LandlineAccess.isExistingCustomer(originalAppVersion: build, isProduction: true))
        }
        for build in ["19", "20", "0", "-1", "1.0", "", "invalid"] {
            XCTAssertFalse(LandlineAccess.isExistingCustomer(originalAppVersion: build, isProduction: true))
        }
        XCTAssertFalse(LandlineAccess.isExistingCustomer(originalAppVersion: "18", isProduction: false))
    }

    func testPurchaseCancelPendingAndVerifiedCompletion() async {
        let client = StubPurchaseClient()
        let access = LandlineAccess()
        let purchases = Purchases(access: access, client: client)
        await purchases.reload()
        XCTAssertTrue(purchases.canStartTrial)
        client.outcome = .cancelled
        await purchases.startTrial()
        XCTAssertEqual(access.status(), .trialAvailable)
        XCTAssertNil(purchases.message)
        client.outcome = .pending
        await purchases.unlock()
        XCTAssertFalse(access.hasFullAccess())
        XCTAssertTrue(purchases.message?.contains("approval") == true)
        client.outcome = .purchased
        client.afterPurchase = PurchaseEntitlements(unlocked: true)
        await purchases.unlock()
        XCTAssertEqual(access.status(), .unlocked)
        XCTAssertFalse(purchases.isBusy)
    }

    func testTrialRequiresAFreeProductAndKnownUnlockPrice() async {
        let client = StubPurchaseClient()
        let purchases = Purchases(access: LandlineAccess(), client: client)
        client.catalog = [.init(id: LandlineProducts.trial, displayPrice: "$0.00", price: 0)]
        await purchases.reload()
        XCTAssertFalse(purchases.canStartTrial)
        client.catalog.append(.init(id: LandlineProducts.unlock, displayPrice: "€2.99", price: 2.99))
        await purchases.reload()
        XCTAssertTrue(purchases.canStartTrial)
        XCTAssertEqual(purchases.unlockProduct?.displayPrice, "€2.99")
        client.catalog[0] = .init(id: LandlineProducts.trial, displayPrice: "$1.00", price: 1)
        await purchases.reload()
        XCTAssertFalse(purchases.canStartTrial)
        await purchases.startTrial()
        XCTAssertEqual(client.purchaseCount, 0)
    }

    func testRestoreUsesOriginalTrialDateAndDoesNotTurnItIntoAnUnlock() async {
        let client = StubPurchaseClient()
        let original = Date.now.addingTimeInterval(-604801)
        client.snapshot = PurchaseEntitlements(trialStartedAt: original)
        let purchases = Purchases(access: LandlineAccess(), client: client)
        await purchases.reload()
        await purchases.restore()
        XCTAssertEqual(client.restoreCount, 1)
        XCTAssertEqual(purchases.access.status(), .expired)
        XCTAssertEqual(purchases.access.entitlements?.trialStartedAt, original)
        XCTAssertFalse(purchases.canStartTrial)
        XCTAssertTrue(purchases.message?.contains("trial has ended") == true)
    }

    func testFailedRestoreOrRefreshKeepsVerifiedAccessAndReportsTheError() async {
        let client = StubPurchaseClient()
        client.snapshot = PurchaseEntitlements(unlocked: true)
        let purchases = Purchases(access: LandlineAccess(), client: client)
        await purchases.reload()
        client.error = PurchaseFailure.unverified
        await purchases.restore()
        XCTAssertEqual(purchases.access.status(), .unlocked)
        XCTAssertEqual(purchases.message, PurchaseFailure.unverified.localizedDescription)
        XCTAssertFalse(purchases.isBusy)
        await purchases.reload()
        XCTAssertEqual(purchases.access.status(), .unlocked)
        XCTAssertNotNil(purchases.message)
    }

    func testUnverifiedInitialEntitlementsNeverGrantAccess() async {
        let client = StubPurchaseClient()
        client.error = PurchaseFailure.unverified
        let purchases = Purchases(access: LandlineAccess(), client: client)
        await purchases.reload()
        XCTAssertFalse(purchases.access.hasFullAccess())
        XCTAssertFalse(purchases.canStartTrial)
        XCTAssertNotNil(purchases.message)
    }
}

@MainActor private final class StubPurchaseClient: PurchaseClient {
    var catalog: [PurchaseProduct] = [
        .init(id: LandlineProducts.trial, displayPrice: "$0.00", price: 0),
        .init(id: LandlineProducts.unlock, displayPrice: "$2.99", price: 2.99),
    ]
    var snapshot = PurchaseEntitlements()
    var afterPurchase = PurchaseEntitlements()
    var outcome = PurchaseOutcome.cancelled
    var error: Error?
    var purchaseCount = 0
    var restoreCount = 0

    func products() async throws -> [PurchaseProduct] {
        if let error { throw error }
        return catalog
    }
    func entitlements() async throws -> PurchaseEntitlements {
        if let error { throw error }
        return snapshot
    }
    func purchase(_ id: String) async throws -> PurchaseOutcome {
        purchaseCount += 1
        if let error { throw error }
        if case .purchased = outcome { snapshot = afterPurchase }
        return outcome
    }
    func restore() async throws {
        restoreCount += 1
        if let error { throw error }
    }
    func listenForUpdates(_ receive: @escaping @MainActor () async -> Void) -> Task<Void, Never> { Task {} }
}

@MainActor final class TrialFunnelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "TrialFunnelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testRemindersFire48And24HoursBeforeTheEndWithTheLocalPrice() {
        let end = now.addingTimeInterval(7 * 86_400)
        let plan = TrialReminders.plan(trialEnd: end, now: now, price: "€3,49")
        XCTAssertEqual(plan.map(\.id), TrialReminders.ids)
        XCTAssertEqual(plan.map(\.fireDate), [end.addingTimeInterval(-48 * 3600), end.addingTimeInterval(-24 * 3600)])
        XCTAssertTrue(plan.allSatisfy { $0.body.contains("€3,49") && !$0.body.contains("$2.99") })
        XCTAssertTrue(plan[1].title.contains("tomorrow"))
        for text in plan.flatMap({ [$0.title, $0.body] }) { XCTAssertFalse(text.contains("\u{2014}")) }
    }

    func testRemindersInThePastAreDropped() {
        let end = now.addingTimeInterval(30 * 3600)
        let plan = TrialReminders.plan(trialEnd: end, now: now, price: nil)
        XCTAssertEqual(plan.map(\.id), [TrialReminders.ids[1]])
        XCTAssertTrue(TrialReminders.plan(trialEnd: now.addingTimeInterval(3600), now: now, price: nil).isEmpty)
    }

    func testCountdownRoundsUpAndAgreesWithTheReminders() {
        let end = now.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(TrialCountdown.remaining(until: end, now: now), "7 DAYS LEFT")
        XCTAssertEqual(TrialCountdown.remaining(until: end, now: end.addingTimeInterval(-48 * 3600)), "2 DAYS LEFT")
        XCTAssertEqual(TrialCountdown.remaining(until: end, now: end.addingTimeInterval(-47 * 3600)), "2 DAYS LEFT")
        XCTAssertEqual(TrialCountdown.remaining(until: end, now: end.addingTimeInterval(-24 * 3600)), "1 DAY LEFT")
        XCTAssertEqual(TrialCountdown.remaining(until: end, now: end.addingTimeInterval(-5 * 3600 + 1)), "5 HOURS LEFT")
        XCTAssertEqual(TrialCountdown.remaining(until: end, now: end.addingTimeInterval(-60)), "UNDER AN HOUR LEFT")
        XCTAssertEqual(TrialCountdown.remaining(until: end, now: end), "ENDED")
        XCTAssertEqual(AccessStatus.trial(until: end).bannerLabel(now: now), "TRIAL · 7 DAYS LEFT")
    }

    func testStartingTheTrialAsksPermissionAndSchedulesReminders() async {
        let client = StubPurchaseClient()
        let reminders = RecordingTrialReminderScheduler()
        let purchases = Purchases(access: LandlineAccess(), client: client,
                                  reminders: reminders, defaults: freshDefaults())
        await purchases.reload()
        XCTAssertEqual(reminders.authorizationRequests, 0)
        client.outcome = .purchased
        client.afterPurchase = PurchaseEntitlements(trialStartedAt: .now)
        await purchases.startTrial()
        XCTAssertEqual(reminders.authorizationRequests, 1)
        XCTAssertEqual(reminders.scheduled.map(\.id), TrialReminders.ids)
        XCTAssertTrue(reminders.scheduled[0].body.contains("$2.99"))
    }

    func testUnlockOrOptOutCancelsButAFailedRefreshDoesNot() async {
        let client = StubPurchaseClient()
        client.snapshot = PurchaseEntitlements(trialStartedAt: .now)
        let reminders = RecordingTrialReminderScheduler()
        let defaults = freshDefaults()
        let purchases = Purchases(access: LandlineAccess(), client: client,
                                  reminders: reminders, defaults: defaults)
        await purchases.reload()
        XCTAssertEqual(reminders.scheduled.count, 2)

        client.error = PurchaseFailure.unavailable
        await purchases.refresh()
        XCTAssertEqual(reminders.scheduled.count, 2, "a transient StoreKit error must not cancel reminders")
        client.error = nil

        purchases.remindersEnabled = false
        await purchases.syncReminders()
        XCTAssertTrue(reminders.scheduled.isEmpty)
        XCTAssertEqual(defaults.object(forKey: TrialReminders.defaultsKey) as? Bool, false)

        purchases.remindersEnabled = true
        await purchases.syncReminders()
        XCTAssertEqual(reminders.scheduled.count, 2)
        client.snapshot = PurchaseEntitlements(unlocked: true, trialStartedAt: .now)
        await purchases.refresh()
        XCTAssertTrue(reminders.scheduled.isEmpty)
    }

    func testSetupProbeOnlyCallsTheDaemonsOwnAnswerFound() {
        // Measured against landlined 0.4.0: /v1/sessions answers 401 to an
        // allowed login with no token and 403 to any other login.
        XCTAssertEqual(SetupProbe.classify(status: 401), .found)
        XCTAssertEqual(SetupProbe.classify(status: 403), .notAllowed)
        for status in [200, 400, 404, 502] {
            XCTAssertNotEqual(SetupProbe.classify(status: status), .found)
        }
    }

    func testSetupNormalizesWhatDoctorPrints() {
        XCTAssertEqual(SetupProbe.normalize(" wss://MacBook.tail1234.ts.net./v1/shell\n"), "macbook.tail1234.ts.net")
        XCTAssertEqual(SetupProbe.normalize("https://box.tail1234.ts.net:443/"), "box.tail1234.ts.net")
        XCTAssertFalse(SetupProbe.isPlausible("box.ts.net:8443"))
        XCTAssertTrue(HostSetup.shareText.contains(HostSetup.oneLine))
    }
}

@MainActor final class TrialReminderNotificationTests: XCTestCase {
    func testRealSchedulerQueuesBothRemindersAndCancelsThem() async throws {
        let center = UNUserNotificationCenter.current()
        // The notification center refuses `add` without permission, and a
        // simulator test host cannot be granted it headlessly.
        let status = await center.notificationSettings().authorizationStatus
        try XCTSkipUnless(status == .authorized || status == .provisional,
                          "notification permission not granted to the test host")
        let scheduler = NotificationTrialReminderScheduler()
        let end = Date().addingTimeInterval(7 * 86_400)
        let plan = TrialReminders.plan(trialEnd: end, now: .now, price: "$2.99")
        await scheduler.replace(with: plan)
        let pending = await center.pendingNotificationRequests()
            .filter { TrialReminders.ids.contains($0.identifier) }
        XCTAssertEqual(Set(pending.map(\.identifier)), Set(TrialReminders.ids))
        for request in pending {
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            let expected = try XCTUnwrap(plan.first { $0.id == request.identifier }).fireDate
            let next = try XCTUnwrap(trigger.nextTriggerDate())
            XCTAssertEqual(next.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
            XCTAssertTrue(request.content.body.contains("$2.99"))
        }
        scheduler.cancelAll()
        // Removal is asynchronous inside the notification center.
        try await Task.sleep(for: .milliseconds(300))
        let left = await center.pendingNotificationRequests()
            .filter { TrialReminders.ids.contains($0.identifier) }
        XCTAssertTrue(left.isEmpty)
    }
}
