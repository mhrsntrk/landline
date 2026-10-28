import UIKit
import StoreKit
import StoreKitTest
import SwiftUI
import XCTest

@testable import Landline

@MainActor final class StoreKitIntegrationTests: XCTestCase {
    func testPurchaseScreenAtPhoneAndTabletWidths() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let purchases = Purchases(access: LandlineAccess())
        await purchases.reload()
        XCTAssertTrue(purchases.canStartTrial, purchases.message ?? "Trial unavailable")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for size in [CGSize(width: 390, height: 844), CGSize(width: 768, height: 1024)] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            let controller = UIHostingController(rootView:
                NavigationStack { PurchaseScreen(leading: .close) }
                    .environment(purchases).preferredColorScheme(.dark))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "purchase-\(Int(size.width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    private func session() throws -> SKTestSession {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Landline", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    func testStoreKitTrialCanBeRestoredWithoutRestartingTheClock() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let purchases = Purchases(access: LandlineAccess(), client: StoreKitPurchaseClient())
        purchases.start()
        defer { purchases.stop() }
        await purchases.reload()
        XCTAssertTrue(purchases.canStartTrial)
        await purchases.startTrial()
        let start = try XCTUnwrap(
            purchases.access.entitlements?.trialStartedAt, purchases.message ?? "No trial message")
        XCTAssertTrue(purchases.access.hasFullAccess())
        XCTAssertFalse(purchases.access.entitlements?.unlocked ?? true)
        XCTAssertEqual(purchases.access.status(at: start.addingTimeInterval(604800)), .expired)
        let restored = Purchases(access: LandlineAccess())
        await restored.reload()
        await restored.restore()
        XCTAssertEqual(restored.access.entitlements?.trialStartedAt, start)
        XCTAssertFalse(restored.canStartTrial)
        XCTAssertEqual(session.allTransactions().count, 1)
    }

    func testStoreKitUnlockPersistsAndRefundArrivesThroughUpdates() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let client = StoreKitPurchaseClient()
        let purchases = Purchases(access: LandlineAccess(), client: client)
        purchases.start()
        defer { purchases.stop() }
        await purchases.reload()
        XCTAssertEqual(purchases.unlockProduct?.price, Decimal(string: "2.99"))
        await purchases.unlock()
        XCTAssertEqual(purchases.access.status(), .unlocked, purchases.message ?? "No purchase message")
        let restored = Purchases(access: LandlineAccess())
        await restored.reload()
        XCTAssertEqual(restored.access.status(), .unlocked)
        let transaction = try XCTUnwrap(session.allTransactions().first, purchases.message ?? "No transaction")
        try session.refundTransaction(identifier: transaction.identifier)
        // Observe the app's single production listener, not a competing updates iterator.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while purchases.access.hasFullAccess(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(purchases.access.hasFullAccess())
    }
}
