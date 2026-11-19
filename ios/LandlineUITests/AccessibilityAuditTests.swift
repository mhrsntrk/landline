import XCTest

/// Apple's accessibility audit over each screen a person reaches, driven by
/// the same `LANDLINE_DEMO` hooks the screenshots use. Its own scheme
/// ("Landline Accessibility"), not the default one: it launches the app once
/// per screen and is too slow for every test run.
///
/// Every issue is collected and printed before failing, so one run lists all
/// of them rather than stopping at the first.
final class AccessibilityAuditTests: XCTestCase {
    private let screens = ["list", "terminal", "settings", "keybar", "catalog",
                           "sessions", "purchase", "edit", "attention"]

    override func setUp() {
        continueAfterFailure = true
    }

    func testEveryScreenPassesTheAudit() throws {
        var findings: [String] = []
        for screen in screens {
            let app = XCUIApplication()
            app.launchEnvironment["LANDLINE_DEMO"] = screen
            app.launchEnvironment["LANDLINE_DEMO_ACCESS"] = "trial"
            app.launch()
            sleep(3)
            // Hard gate: missing descriptions, traits and element
            // detection, which were brought to zero in 1.5. Contrast and hit
            // area are printed but not gated: the remaining contrast reports
            // sit on tokens DESIGN.md measures at 4.7:1 or better (or on a
            // disabled control), and SwiftUI keeps a TextField at its natural
            // height. Dynamic Type is out: measured columns, header cells and
            // the key bar cap on purpose and offer the large content viewer.
            try app.performAccessibilityAudit(for: .all.subtracting([.dynamicType, .textClipped])) { issue in
                let gated: XCUIAccessibilityAuditType = [.sufficientElementDescription, .trait, .elementDetection]
                if !gated.contains(issue.auditType) {
                    let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)'" } ?? "-"
                    print("A11Y-NOTE [\(screen)] \(issue.compactDescription) :: \(element)")
                    return true
                }
                let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' id=\($0.identifier)" } ?? "-"
                findings.append("[\(screen)] \(issue.auditType) \(issue.compactDescription) :: \(element)")
                return true
            }
            app.terminate()
        }
        for line in findings { print("A11Y-FINDING \(line)") }
        XCTAssertTrue(findings.isEmpty, "\(findings.count) accessibility findings")
    }
}
