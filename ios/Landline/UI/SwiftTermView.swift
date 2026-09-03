import SwiftUI
import UIKit
import SwiftTerm
import os

// MARK: - Terminal palette
//
// SwiftTerm wants `SwiftTerm.Color` (16-bit components) and `UIColor`, neither
// of which is a SwiftUI `Color`, so this layer converts. The values themselves
// are not restated: they come from Theme's packed hex, which is DESIGN.md's
// "Terminal ANSI (One Dark Pro, exact)" table.

struct TerminalPalette {
    /// Exactly 16 entries: 8 normal then 8 bright, in ANSI order.
    let ansi: [SwiftTerm.Color]
    let foreground: UIColor
    let background: UIColor
    let cursor: UIColor
    /// Text colour under a block cursor.
    let cursorText: UIColor?
    let selection: UIColor
    let selectionText: UIColor
    /// Drives the keyboard appearance so the software keyboard does not flash
    /// white under a dark terminal.
    let isDark: Bool

    /// The product default, straight off Theme.
    static let oneDarkPro = TerminalPalette(
        ansi: Theme.ansiHexRGB.map(SwiftTerm.Color.init(hexRGB:)),
        foreground: UIColor(hexRGB: Theme.terminalForegroundHexRGB),
        background: UIColor(hexRGB: Theme.terminalBackgroundHexRGB),
        cursor: UIColor(hexRGB: Theme.terminalCursorHexRGB),
        cursorText: UIColor(hexRGB: Theme.terminalBackgroundHexRGB),
        selection: UIColor(hexRGB: Theme.terminalSelectionHexRGB),
        selectionText: UIColor(hexRGB: 0xD7DAE0),
        isDark: true
    )

    /// Reached only when the host is set to `matchSystem` and the phone is in
    /// light appearance. One Light is One Dark Pro's own sibling scheme, so the
    /// hues stay the ones the owner already reads.
    static let oneLight = TerminalPalette(
        ansi: ([
            0xFAFAFA, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0x383A42,
            0xA0A1A7, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0x000000,
        ] as [UInt32]).map(SwiftTerm.Color.init(hexRGB:)),
        foreground: UIColor(hexRGB: 0x383A42),
        background: UIColor(hexRGB: 0xFAFAFA),
        cursor: UIColor(hexRGB: 0x526FFF),
        cursorText: UIColor(hexRGB: 0xFAFAFA),
        selection: UIColor(hexRGB: 0xD0D0D0),
        selectionText: UIColor(hexRGB: 0x383A42),
        isDark: false
    )

    /// Resolves what a host actually renders in. Anything that is not
    /// `matchSystem` is One Dark Pro, which PRODUCT.md pins as the default.
    static func resolve(scheme: TerminalColorScheme, systemIsLight: Bool) -> TerminalPalette {
        switch scheme {
        case .matchSystem: return systemIsLight ? .oneLight : .oneDarkPro
        case .oneDarkPro: return .oneDarkPro
        }
    }
}

extension SwiftTerm.Color {
    /// Packed 0xRRGGBB into SwiftTerm's 8-bit-per-channel initialiser.
    convenience init(hexRGB: UInt32) {
        let c = Theme.components(hexRGB)
        self.init(red8: UInt16(c.r), green8: UInt16(c.g), blue8: UInt16(c.b))
    }
}

extension UIColor {
    convenience init(hexRGB: UInt32) {
        let c = Theme.components(hexRGB)
        self.init(red: CGFloat(c.r) / 255,
                  green: CGFloat(c.g) / 255,
                  blue: CGFloat(c.b) / 255,
                  alpha: 1)
    }
}

// MARK: - Feed metrics

/// Cheap counters the benchmark harness and the debug HUD read. Plain fields,
/// no publishing: reading these must never invalidate a SwiftUI body.
struct FeedMetrics {
    /// Chunks handed in by Connection (one per WebSocket message).
    var chunks = 0
    /// Times we actually called into SwiftTerm.
    var flushes = 0
    var bytes = 0
    var feedSeconds: Double = 0
    /// Longest single main-thread flush; this is the number that shows up as a
    /// dropped frame if it goes past ~8ms.
    var maxFlushSeconds: Double = 0

    var chunksPerFlush: Double { flushes == 0 ? 0 : Double(chunks) / Double(flushes) }
}

/// Watches the main run loop while output streams and records how badly it
/// stalls. This is the number that matters: a terminal that parses fast but
/// blocks the main thread for 40ms at a time still reads as stuttering.
final class FrameProbe {
    private(set) var frames = 0
    /// Intervals longer than two 60Hz frames — a visible hitch.
    private(set) var hitches = 0
    private(set) var worstIntervalSeconds: Double = 0
    private var last: CFTimeInterval = 0
    private var link: CADisplayLink?

    private static let hitchThreshold: Double = 1.0 / 30.0

    func start() {
        stop()
        frames = 0
        hitches = 0
        worstIntervalSeconds = 0
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    deinit { link?.invalidate() }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last != 0 else { return }
        let interval = link.timestamp - last
        frames += 1
        worstIntervalSeconds = max(worstIntervalSeconds, interval)
        if interval > Self.hitchThreshold { hitches += 1 }
    }
}

// MARK: - TerminalController

/// Owns the UIKit terminal and every byte that reaches it.
///
/// This type exists so terminal output never travels through SwiftUI. Bytes
/// arrive from `Connection.onStdout` on the main queue, land in a plain byte
/// buffer here, and are drained into SwiftTerm by a `CADisplayLink` — one feed
/// per displayed frame regardless of how many WebSocket messages arrived. No
/// `@State`, no `@Published`, no `updateUIView`: a 4 MiB build log scrolling
/// past invalidates the SwiftUI body exactly zero times.
///
/// Main thread only. `Connection` fires all its callbacks on the main queue and
/// the display link is scheduled on the main run loop, so the byte buffer and
/// SwiftTerm's parser state (which holds partial UTF-8 sequences between feeds,
/// see `Terminal.ReadingBuffer`) are only ever touched from one thread.
final class TerminalController {
    /// Bytes the user typed or pasted that should go to the PTY.
    var onSend: ((Data) -> Void)?
    /// The terminal grid was re-laid-out to a new size.
    var onResize: ((_ cols: Int, _ rows: Int) -> Void)?

    private(set) weak var terminalView: TerminalView?
    private(set) var metrics = FeedMetrics()
    let probe = FrameProbe()

    /// A/B switch for measurement. `true` is the shipping path (one feed per
    /// displayed frame). Launching with `-LandlineLegacyFeed` restores the
    /// incumbent behaviour — one synchronous `TerminalView.feed` per WebSocket
    /// message — so before/after numbers come off the identical workload on the
    /// identical device rather than off two different builds.
    let coalescing: Bool = !ProcessInfo.processInfo.arguments.contains("-LandlineLegacyFeed")

    /// Pending bytes plus the index of the first unconsumed one. Draining by
    /// advancing an index and compacting occasionally is O(n) total; repeated
    /// `removeFirst(k)` on a multi-megabyte buffer is O(n²).
    private var pending: [UInt8] = []
    private var pendingHead = 0
    private var link: CADisplayLink?

    /// How long one drain may hold the main thread. A frame is 16.6ms at 60Hz
    /// and 8.3ms at 120Hz; staying under half a 120Hz frame keeps the UI (and
    /// the keyboard) responsive while `cat`ing something enormous. Whatever is
    /// left over rides the next tick.
    private static let frameBudgetSeconds: Double = 0.004
    /// Granularity of one bounded slice inside that budget.
    private static let sliceBytes = 64 * 1024
    /// Compact the buffer once the consumed prefix passes this.
    private static let compactThreshold = 512 * 1024

    // MARK: Attachment

    func attach(to view: TerminalView) {
        terminalView = view
        if coalescing { startLink() }
        probe.start()
    }

    func detach() {
        probe.stop()
        stopLink()
        pending.removeAll(keepingCapacity: false)
        pendingHead = 0
        terminalView = nil
    }

    deinit {
        link?.invalidate()
    }

    // MARK: Geometry

    var cols: Int { terminalView?.getTerminal().cols ?? 80 }
    var rows: Int { terminalView?.getTerminal().rows ?? 24 }

    // MARK: Feeding

    /// Accepts one STDOUT chunk. Never touches SwiftTerm synchronously: the
    /// bytes wait here until the next display refresh, so a burst of hundreds
    /// of small frames becomes one parse and one repaint.
    func feed(_ data: Data) {
        metrics.chunks += 1
        metrics.bytes += data.count
        guard coalescing else {
            legacyFeed(data)
            return
        }
        pending.append(contentsOf: data)
        link?.isPaused = false
    }

    /// The incumbent path, kept only so `-LandlineLegacyFeed` can measure it.
    private func legacyFeed(_ data: Data) {
        guard let view = terminalView else { return }
        let started = CACurrentMediaTime()
        view.feed(byteArray: [UInt8](data)[...])
        let elapsed = CACurrentMediaTime() - started
        metrics.flushes += 1
        metrics.feedSeconds += elapsed
        metrics.maxFlushSeconds = max(metrics.maxFlushSeconds, elapsed)
    }

    /// One line of hard numbers for the console. Called on a timer while a
    /// session is live; costs nothing when nothing is streaming.
    func metricsLine(label: String) -> String {
        String(
            format: "[landline.perf] %@ mode=%@ chunks=%d flushes=%d chunks/flush=%.1f bytes=%d "
                + "feed_total=%.1fms feed_max=%.2fms probe_frames=%d hitches=%d worst_frame=%.1fms",
            label,
            coalescing ? "coalesced" : "per-chunk",
            metrics.chunks,
            metrics.flushes,
            metrics.chunksPerFlush,
            metrics.bytes,
            metrics.feedSeconds * 1000,
            metrics.maxFlushSeconds * 1000,
            probe.frames,
            probe.hitches,
            probe.worstIntervalSeconds * 1000
        )
    }

    /// Drains the buffer immediately. Used by the local-echo path and at
    /// teardown; normal output goes through the display link.
    func flushNow() {
        drain(budget: .infinity)
    }

    func resetMetrics() {
        metrics = FeedMetrics()
        probe.start()
    }

    private func startLink() {
        stopLink()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // 60Hz is plenty for reading text; asking for less on a ProMotion
        // display saves power in the scene this app is actually used in.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        // .common so a scroll or a gesture cannot starve terminal output.
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        drain(budget: Self.frameBudgetSeconds)
        if pendingHead >= pending.count {
            link?.isPaused = true
        }
    }

    private func drain(budget: Double) {
        guard let view = terminalView, pendingHead < pending.count else { return }

        let started = CACurrentMediaTime()
        var fedThisPass = false

        while pendingHead < pending.count {
            let end = min(pendingHead + Self.sliceBytes, pending.count)
            // ArraySlice: no copy, and SwiftTerm's parser reads it in place.
            view.feed(byteArray: pending[pendingHead..<end])
            pendingHead = end
            fedThisPass = true
            if CACurrentMediaTime() - started >= budget { break }
        }

        if pendingHead >= pending.count {
            pending.removeAll(keepingCapacity: pending.capacity <= Self.compactThreshold)
            pendingHead = 0
        } else if pendingHead >= Self.compactThreshold {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }

        guard fedThisPass else { return }
        let elapsed = CACurrentMediaTime() - started
        metrics.flushes += 1
        metrics.feedSeconds += elapsed
        metrics.maxFlushSeconds = max(metrics.maxFlushSeconds, elapsed)
    }

    // MARK: Appearance

    func apply(palette: TerminalPalette) {
        guard let view = terminalView else { return }
        // installColors takes exactly the 16 ANSI entries and recomputes the
        // 256-colour palette from them; the four non-ANSI colours are separate
        // properties and must be set after, because installColors triggers a
        // colorsChanged() that re-derives from the natives.
        view.installColors(palette.ansi)
        view.nativeBackgroundColor = palette.background
        view.nativeForegroundColor = palette.foreground
        view.backgroundColor = palette.background
        view.caretColor = palette.cursor
        view.caretTextColor = palette.cursorText
        view.selectedTextBackgroundColor = palette.selection
        view.selectedTextForegroundColor = palette.selectionText
        view.keyboardAppearance = palette.isDark ? .dark : .light
    }

    func apply(fontSize: CGFloat) {
        guard let view = terminalView else { return }
        // SF Mono via monospacedSystemFont. Explicit bold/italic faces so vim
        // and tmux status lines do not fall back to a proportional face.
        view.setFonts(
            normal: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            bold: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            italic: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            boldItalic: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        )
    }
}

// MARK: - Font size preference

enum TerminalFont {
    static let minSize: CGFloat = 9
    static let maxSize: CGFloat = 22
    static let defaultSize: CGFloat = 13
    private static let key = "terminal.fontSize"

    static var size: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: key)
            guard stored > 0 else { return defaultSize }
            return min(maxSize, max(minSize, CGFloat(stored)))
        }
        set {
            UserDefaults.standard.set(Double(min(maxSize, max(minSize, newValue))), forKey: key)
        }
    }
}

// MARK: - SwiftTermView

/// UIViewRepresentable wrapper around SwiftTerm's TerminalView.
///
/// `updateUIView` is deliberately empty. Everything mutable about the terminal
/// (bytes, palette, font) is reached through `TerminalController`, so a SwiftUI
/// re-render costs nothing and terminal output cannot cause one.
struct SwiftTermView: UIViewRepresentable {
    let controller: TerminalController
    let palette: TerminalPalette

    func makeUIView(context: Context) -> TerminalView {
        var options = TerminalOptions.default
        // The daemon replays a 256 KiB scrollback ring on attach; 500 lines
        // would throw most of it away before the user ever sees it.
        options.scrollback = 5000
        // .base16Lab (SwiftTerm's default) *derives* the 256-colour cube from
        // the 16 base colours, so `ls --color`, fzf, and vim colourschemes drift
        // from what the same program paints on the desktop. .xterm is the
        // standard 6x6x6 cube plus grayscale ramp: what every other terminal does.
        options.ansi256PaletteStrategy = .xterm

        let view = TerminalView(frame: .zero, font: nil, options: options)
        view.terminalDelegate = context.coordinator
        // The chrome behind the grid, so an incomplete last row does not flash
        // a different colour than the terminal ground.
        view.isOpaque = true
        // No iOS text affordances on a PTY.
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.optionAsMetaKey = true

        controller.attach(to: view)
        controller.apply(palette: palette)
        controller.apply(fontSize: TerminalFont.size)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        context.coordinator.controller = controller

        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Intentionally empty. See the type comment.
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.controller?.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        weak var controller: TerminalController?
        private var pinchStartSize: CGFloat = TerminalFont.defaultSize

        init(controller: TerminalController) {
            self.controller = controller
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let controller else { return }
            switch gesture.state {
            case .began:
                pinchStartSize = TerminalFont.size
            case .changed, .ended:
                let target = (pinchStartSize * gesture.scale).rounded()
                let clamped = min(TerminalFont.maxSize, max(TerminalFont.minSize, target))
                guard clamped != TerminalFont.size else { return }
                TerminalFont.size = clamped
                controller.apply(fontSize: clamped)
            default:
                break
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            controller?.onSend?(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            controller?.onResize?(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
