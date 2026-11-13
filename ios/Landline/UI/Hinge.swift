import SwiftUI
import UIKit

// The fold, as far as layout cares.
//
// UIKit 27.1 reports a hinge's status and angle through `UIHingeInteraction`
// and nothing else: there is no SwiftUI counterpart and no geometry. The
// geometry follows from the hardware instead. iPhone Duo's inner display is
// natively landscape and folds across its long side, so with the window filling
// that display the crease is always the midline of the window's longer edge:
// two book pages in landscape, a top and bottom page (laptop posture) in
// portrait. A window that does not fill its screen has no known crease, and is
// laid out as if flat.

/// The hinge state that layout reads. `nil` on hardware without a hinge.
enum HingePosture: Equatable {
    case closed
    /// Half open: propped like a book or a laptop. The crease is a real edge.
    case partial
    case open
}

@Observable
final class HingeObserver {
    /// `nil` until a hinge reports, and forever on hardware without one.
    private(set) var posture: HingePosture?
    /// Whether the window covers its whole screen, which is what makes the
    /// window's midline the crease.
    private(set) var windowFillsScreen = false

    init() {
        posture = Self.forcedPosture
    }

    fileprivate func update(_ posture: HingePosture?) {
        guard Self.forcedPosture == nil else { return }
        if self.posture != posture { self.posture = posture }
    }

    /// Debug screenshot hook: `LANDLINE_DEMO_HINGE=partial|open|closed` pins
    /// the posture, because the simulator's pose control lives in DeviceHub's
    /// window and a locked or headless Mac cannot reach it. Compiled out of
    /// release builds.
    private static var forcedPosture: HingePosture? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["LANDLINE_DEMO_HINGE"] {
        case "partial": return .partial
        case "open": return .open
        case "closed": return .closed
        default: return nil
        }
        #else
        return nil
        #endif
    }

    fileprivate func update(fillsScreen: Bool) {
        if windowFillsScreen != fillsScreen { windowFillsScreen = fillsScreen }
    }
}

/// An invisible view that carries the `UIHingeInteraction`, because an
/// interaction has to live on a view in the window's hierarchy.
struct HingeProbe: UIViewRepresentable {
    let observer: HingeObserver

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.observer = observer
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak observer] _, update in
                observer?.update(Self.posture(update.hinge))
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.reportFill()
    }

    @available(iOS 27.1, *)
    static func posture(_ hinge: UIHinge?) -> HingePosture? {
        guard let hinge else { return nil }
        switch hinge.status {
        case .closed: return .closed
        case .partiallyOpen: return .partial
        case .fullyOpen: return .open
        default: return nil
        }
    }

    final class ProbeView: UIView {
        weak var observer: HingeObserver?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportFill()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportFill()
        }

        func reportFill() {
            guard let window else { return }
            let screen = window.windowScene?.screen.bounds.size ?? window.bounds.size
            let size = window.bounds.size
            // Half a point of slack: scale rounding, not a real difference.
            let fills = abs(size.width - screen.width) < 0.5 && abs(size.height - screen.height) < 0.5
            // Deferred: this runs inside UIKit layout, and writing observed
            // state from there would invalidate SwiftUI mid-update.
            DispatchQueue.main.async { [weak observer] in
                observer?.update(fillsScreen: fills)
            }
        }
    }
}
