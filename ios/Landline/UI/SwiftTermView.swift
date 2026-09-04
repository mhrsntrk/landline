import SwiftUI
import UIKit
import SwiftTerm
import os

// MARK: - Terminal palette
//
// SwiftTerm wants `SwiftTerm.Color` (16-bit components) and `UIColor`, neither
// of which is a SwiftUI `Color`, so this layer converts. Palettes are stored as
// packed 0xRRGGBB and converted on demand, which is what lets the picker draw a
// scheme's own swatch strip in SwiftUI from the same numbers the emulator gets.
//
// Every hex below is transcribed from the scheme's own repository, not from
// memory or from a screenshot. The source is cited on each palette, because the
// audience for this app reads these colours all day and a wrong hex is the kind
// of error that is noticed instantly and never forgiven. DESIGN.md's
// "Terminal ANSI (One Dark Pro, exact)" table stays the default and is the only
// one that also drives app chrome.

struct TerminalPalette {
    /// Exactly 16 packed 0xRRGGBB entries: 8 normal then 8 bright, in ANSI
    /// order (black red green yellow blue magenta cyan white).
    let ansiHexRGB: [UInt32]
    let foregroundHexRGB: UInt32
    let backgroundHexRGB: UInt32
    let cursorHexRGB: UInt32
    /// Text colour under a block cursor.
    let cursorTextHexRGB: UInt32
    let selectionHexRGB: UInt32
    let selectionTextHexRGB: UInt32
    /// Drives the keyboard appearance so the software keyboard does not flash
    /// white under a dark terminal.
    let isDark: Bool

    init(
        ansiHexRGB: [UInt32],
        foreground: UInt32,
        background: UInt32,
        cursor: UInt32,
        cursorText: UInt32,
        selection: UInt32,
        selectionText: UInt32,
        isDark: Bool
    ) {
        self.ansiHexRGB = ansiHexRGB
        self.foregroundHexRGB = foreground
        self.backgroundHexRGB = background
        self.cursorHexRGB = cursor
        self.cursorTextHexRGB = cursorText
        self.selectionHexRGB = selection
        self.selectionTextHexRGB = selectionText
        self.isDark = isDark
    }

    // Converted on demand rather than stored: `apply(palette:)` runs on attach
    // and on a scheme change, not per frame, and keeping one representation
    // means the picker and the emulator can never drift apart.
    var ansi: [SwiftTerm.Color] { ansiHexRGB.map(SwiftTerm.Color.init(hexRGB:)) }
    var foreground: UIColor { UIColor(hexRGB: foregroundHexRGB) }
    var background: UIColor { UIColor(hexRGB: backgroundHexRGB) }
    var cursor: UIColor { UIColor(hexRGB: cursorHexRGB) }
    var cursorText: UIColor? { UIColor(hexRGB: cursorTextHexRGB) }
    var selection: UIColor { UIColor(hexRGB: selectionHexRGB) }
    var selectionText: UIColor { UIColor(hexRGB: selectionTextHexRGB) }

    /// The product default, straight off Theme. This is the one palette that is
    /// also the app's chrome, so it is the one DESIGN.md's contrast floor was
    /// measured against.
    static let oneDarkPro = TerminalPalette(
        ansiHexRGB: Theme.ansiHexRGB,
        foreground: Theme.terminalForegroundHexRGB,
        background: Theme.terminalBackgroundHexRGB,
        cursor: Theme.terminalCursorHexRGB,
        cursorText: Theme.terminalBackgroundHexRGB,
        selection: Theme.terminalSelectionHexRGB,
        selectionText: 0xD7DAE0,
        isDark: true
    )

    /// Reached only when the host is set to `matchSystem` and the phone is in
    /// light appearance. One Light is One Dark Pro's own sibling scheme, so the
    /// hues stay the ones the owner already reads.
    static let oneLight = TerminalPalette(
        ansiHexRGB: [
            0xFAFAFA, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0x383A42,
            0xA0A1A7, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0x000000,
        ],
        foreground: 0x383A42,
        background: 0xFAFAFA,
        cursor: 0x526FFF,
        cursorText: 0xFAFAFA,
        selection: 0xD0D0D0,
        selectionText: 0x383A42,
        isDark: false
    )

    /// Catppuccin Mocha, from the project's own kitty port:
    /// https://github.com/catppuccin/kitty `themes/mocha.conf`.
    /// (`catppuccin/alacritty`'s `catppuccin-mocha.toml` agrees colour for
    /// colour, so the ANSI mapping is not one port's opinion.)
    static let catppuccinMocha = TerminalPalette(
        ansiHexRGB: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
        ],
        foreground: 0xCDD6F4,
        background: 0x1E1E2E,
        cursor: 0xF5E0DC,
        cursorText: 0x1E1E2E,
        selection: 0xF5E0DC,
        selectionText: 0x1E1E2E,
        isDark: true
    )

    /// Tokyo Night, from https://github.com/folke/tokyonight.nvim
    /// `extras/kitty/tokyonight_night.conf`, which is the upstream the
    /// tokyo-night-vscode-theme README points terminals at. Verified against
    /// the owner's own configuration for the normal eight and fg/bg.
    static let tokyoNight = TerminalPalette(
        ansiHexRGB: [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xFF899D, 0x9FE044, 0xFABA4A, 0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5,
        ],
        foreground: 0xC0CAF5,
        background: 0x1A1B26,
        cursor: 0xC0CAF5,
        cursorText: 0x1A1B26,
        selection: 0x283457,
        selectionText: 0xC0CAF5,
        isDark: true
    )

    /// Gruvbox Dark, from morhetz's own terminal distribution:
    /// https://github.com/morhetz/gruvbox-contrib `xresources/gruvbox-dark.xresources`
    /// (its `termite/gruvbox-dark` and `konsole/Gruvbox_dark.colorscheme` are
    /// identical). Gruvbox publishes no terminal cursor or selection, so both
    /// come from `morhetz/gruvbox`'s own `colors/gruvbox.vim`: `Visual` is
    /// `bg3` (`dark3` `#665C54`) and `Cursor` is `inverse`, i.e. the
    /// foreground.
    static let gruvboxDark = TerminalPalette(
        ansiHexRGB: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
        ],
        foreground: 0xEBDBB2,
        background: 0x282828,
        cursor: 0xEBDBB2,
        cursorText: 0x282828,
        selection: 0x665C54,
        selectionText: 0xEBDBB2,
        isDark: true
    )

    /// Dracula, from the project's own kitty port:
    /// https://github.com/dracula/kitty `dracula.conf`.
    static let dracula = TerminalPalette(
        ansiHexRGB: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        ],
        foreground: 0xF8F8F2,
        background: 0x282A36,
        cursor: 0xF8F8F2,
        cursorText: 0x282A36,
        selection: 0x44475A,
        selectionText: 0xFFFFFF,
        isDark: true
    )

    /// Nord, from the Nord org's own terminal port:
    /// https://github.com/nordtheme/alacritty `src/nord.yaml`. Its selection
    /// text is `CellForeground`, which this renderer has no equivalent for, so
    /// the foreground is named explicitly.
    static let nord = TerminalPalette(
        ansiHexRGB: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
        ],
        foreground: 0xD8DEE9,
        background: 0x2E3440,
        cursor: 0xD8DEE9,
        cursorText: 0x2E3440,
        selection: 0x4C566A,
        selectionText: 0xD8DEE9,
        isDark: true
    )

    /// Solarized Dark, from Ethan Schoonover's own
    /// https://github.com/altercation/solarized `xresources/solarized`, which
    /// is the canonical 16-colour mapping (and the reason `color8` is darker
    /// than `color0`: Solarized spends half the bright range on greys). That
    /// file has no selection, so selection is the documented highlighted-
    /// background pair from the Solarized README, `base02` on `base1`.
    static let solarizedDark = TerminalPalette(
        ansiHexRGB: [
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        ],
        foreground: 0x839496,
        background: 0x002B36,
        cursor: 0x93A1A1,
        cursorText: 0x002B36,
        selection: 0x073642,
        selectionText: 0x93A1A1,
        isDark: true
    )

    /// Rosé Pine, from the project's own kitty port:
    /// https://github.com/rose-pine/kitty `dist/rose-pine.conf`. Rosé Pine
    /// ships no separate bright ramp beyond `iris`/`muted`, so six of its eight
    /// bright entries repeat the normal ones; that repetition is the scheme,
    /// not a gap in the transcription.
    static let rosePine = TerminalPalette(
        ansiHexRGB: [
            0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
        ],
        foreground: 0xE0DEF4,
        background: 0x191724,
        cursor: 0x524F67,
        cursorText: 0xE0DEF4,
        selection: 0x403D52,
        selectionText: 0xE0DEF4,
        isDark: true
    )

    /// Catppuccin Latte, from https://github.com/catppuccin/kitty
    /// `themes/latte.conf`. The kitty port rather than the alacritty one on
    /// purpose: `catppuccin/alacritty`'s `catppuccin-latte.toml` puts `surface1`
    /// at ANSI black and `subtext1` at ANSI white, which on a `#EFF1F5` ground
    /// makes black text nearly invisible. Kitty's mapping keeps black dark,
    /// which is what a light terminal has to do.
    static let catppuccinLatte = TerminalPalette(
        ansiHexRGB: [
            0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
            0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC,
        ],
        foreground: 0x4C4F69,
        background: 0xEFF1F5,
        cursor: 0xDC8A78,
        cursorText: 0xEFF1F5,
        selection: 0xDC8A78,
        selectionText: 0xEFF1F5,
        isDark: false
    )

    /// What `matchSystem` paints when the phone is in light appearance.
    ///
    /// One Light, not Catppuccin Latte, and the reason is the pairing rather
    /// than the palette: `matchSystem`'s dark half is One Dark Pro, and One
    /// Light is that scheme's own sibling, so following the system changes the
    /// ground without changing the hues the owner reads. Latte is a first-class
    /// choice in its own right for anyone who wants a light terminal outright;
    /// swapping this one constant is all it would take to make it the system
    /// light half instead.
    static let matchSystemLight = oneLight

    /// Resolves what a host actually renders in.
    static func resolve(scheme: TerminalColorScheme, systemIsLight: Bool) -> TerminalPalette {
        switch scheme {
        case .matchSystem: return systemIsLight ? .matchSystemLight : .oneDarkPro
        case .oneDarkPro: return .oneDarkPro
        case .catppuccinMocha: return .catppuccinMocha
        case .tokyoNight: return .tokyoNight
        case .gruvboxDark: return .gruvboxDark
        case .dracula: return .dracula
        case .nord: return .nord
        case .solarizedDark: return .solarizedDark
        case .rosePine: return .rosePine
        case .catppuccinLatte: return .catppuccinLatte
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

// MARK: - Swipe to scroll

/// Turns the finger's vertical travel into whole wheel notches.
///
/// Pure and clock-free on purpose. The ratio, the sign convention and the flick
/// clamp are the three things that decide whether a swipe reads as scrolling or
/// as a lurch, and all three are testable without a device.
struct WheelScrollAccumulator: Equatable {
    /// The most travel one callback may charge, in cell heights.
    ///
    /// A pan callback is normally one frame's worth of finger, which is a few
    /// points. It stops being that the moment the main thread is busy — and it
    /// is busy exactly while this is scrolling, because every notch makes tmux
    /// repaint the pane — so callbacks coalesce and arrive carrying three or
    /// four frames of travel at once. The ceiling smooths that burst over the
    /// following callbacks instead of putting a hundred wheel events on the wire
    /// in one frame.
    ///
    /// Twelve cell heights is a third of a phone screen per callback, or about
    /// forty screens a second: far past any thumb, so this never limits real
    /// input. It is also exactly the old constant, which was four notches at
    /// three cell heights each, so the shape of the clamp is unchanged and only
    /// the fate of the overflow is.
    static let maxCellHeightsPerStep: CGFloat = 12

    /// The most travel that may sit unpaid, in cell heights. Roughly three
    /// screens: more than any single swipe can produce, so nothing a finger
    /// actually did is ever discarded, and still a hard bound so a burst cannot
    /// become a queue that scrolls on after the gesture visibly ended.
    static let maxCarryCellHeights: CGFloat = 120

    /// Points of travel one notch costs.
    let pointsPerNotch: CGFloat
    /// The ceiling, resolved into notches at this speed. Derived rather than
    /// constant: the ceiling is a *travel* limit, so raising the speed has to
    /// raise the notch count it permits or the fast settings would spend every
    /// callback clamped and pay the rest out late, which is the runaway the
    /// ceiling exists to prevent.
    let maxNotchesPerStep: Int
    /// The carry bound in points, from the cell height this was built with.
    let maxCarry: CGFloat
    /// Travel not yet paid out as a whole notch. A swipe is a hundred small
    /// callbacks, most of them worth less than one notch, so the remainder has
    /// to survive between them or a slow drag scrolls nothing at all.
    private(set) var carry: CGFloat = 0

    /// A zero or absurd cell height would divide by nothing; 1pt is the floor.
    init(cellHeight: CGFloat, speed: TerminalScrollSpeed = .default) {
        let height = max(1, cellHeight)
        pointsPerNotch = max(1, height * speed.cellHeightsPerNotch)
        maxNotchesPerStep = max(1, Int(height * Self.maxCellHeightsPerStep / pointsPerNotch))
        maxCarry = height * Self.maxCarryCellHeights
    }

    /// Positive `delta` is the finger travelling *down* the screen, which
    /// reveals earlier output, which is a wheel notch **up**. Returns a signed
    /// notch count: positive up, negative down, zero when nothing is owed yet.
    ///
    /// What the ceiling refuses is **kept**, not dropped. Dropping it was the
    /// bug: a quick flick arrives as a handful of large callbacks, and charging
    /// four notches for each and binning the rest threw most of the finger's
    /// travel away, which is why a fast swipe moved barely further than a slow
    /// one. The unpaid remainder stays in `carry` and is spent on the callbacks
    /// that follow, bounded by `maxCarry` so it can never outlive the gesture by
    /// more than a few frames.
    mutating func notches(forTranslation delta: CGFloat) -> Int {
        guard delta.isFinite else { return 0 }
        carry = min(max(carry + delta, -maxCarry), maxCarry)
        var notches = Int((carry / pointsPerNotch).rounded(.towardZero))
        guard notches != 0 else { return 0 }
        if abs(notches) > maxNotchesPerStep {
            notches = notches < 0 ? -maxNotchesPerStep : maxNotchesPerStep
        }
        carry -= CGFloat(notches) * pointsPerNotch
        return notches
    }

    mutating func reset() { carry = 0 }
}

/// The coast after a flick.
///
/// A wheel event carries no momentum of its own — the far end sees discrete
/// notches — so if the gesture stops dead when the finger lifts, reading a long
/// build log means swiping thirty times. This decays the lift-off velocity and
/// keeps charging notches out of it, which is the same thing a scroll view does
/// and the reason its momentum has to be reproduced rather than borrowed.
struct FlickDecay: Equatable {
    /// Per-frame friction at 60Hz, resampled for whatever the display actually
    /// gives us.
    static let frictionPerFrame: CGFloat = 0.94
    /// Below this the coast has visually stopped.
    static let stopSpeed: CGFloat = 60
    /// A flick off a ProMotion panel can report five figures. Clamped, because
    /// past this the notch ceiling is doing all the work anyway.
    static let maxSpeed: CGFloat = 6000

    /// The coast's budget, in notches rather than in points.
    ///
    /// Friction alone bounds the coast in *travel*, and travel is what the
    /// speed setting divides: at 5x the same flick buys five times the notches,
    /// which is a flick that pages most of the way through a build log. A notch
    /// is a fixed amount of movement at the far end (three lines under xterm's
    /// convention, five under the owner's tmux binding), so the honest place to
    /// bound a runaway is here, in notches. Sixty is roughly four screens at
    /// three lines and seven at five. At 1x the friction curve settles at about
    /// thirty-five notches on its own, so the budget never fires there; it
    /// exists for the top of the range.
    static let maxCoastNotches = 60

    private(set) var velocity: CGFloat
    /// Points of coast still allowed. Unlimited unless the caller gives a
    /// budget, so the friction curve on its own stays testable.
    private(set) var remainingTravel: CGFloat

    init(velocity: CGFloat, maxTravel: CGFloat = .greatestFiniteMagnitude) {
        let finite = velocity.isFinite ? velocity : 0
        self.velocity = min(max(finite, -Self.maxSpeed), Self.maxSpeed)
        if abs(self.velocity) < Self.stopSpeed { self.velocity = 0 }
        remainingTravel = maxTravel.isFinite ? max(0, maxTravel) : .greatestFiniteMagnitude
    }

    var isCoasting: Bool { velocity != 0 && remainingTravel > 0 }

    /// Advances by `dt` seconds and answers with the distance travelled, in
    /// points, for the accumulator to charge.
    mutating func step(dt: CGFloat) -> CGFloat {
        guard isCoasting, dt > 0, dt.isFinite else { return 0 }
        var distance = velocity * dt
        if abs(distance) >= remainingTravel {
            distance = velocity < 0 ? -remainingTravel : remainingTravel
            remainingTravel = 0
            velocity = 0
            return distance
        }
        remainingTravel -= abs(distance)
        velocity *= pow(Self.frictionPerFrame, dt * 60)
        if abs(velocity) < Self.stopSpeed { velocity = 0 }
        return distance
    }
}

/// Makes a vertical swipe over the terminal scroll while the far end is reading
/// the mouse.
///
/// The diagnosis, read out of the SwiftTerm sources rather than assumed:
///
///   * `Terminal.swift` says outright that it "only tracks the mode's state
///     here; translating wheel events is left to the" embedding app.
///   * `iOSTerminalView.panMouseHandler` turns a pan into button press, motion,
///     release — a **drag**. Under `set -g mouse on`, tmux reads a drag as a
///     selection. That is correct behaviour for a drag, and it is exactly what
///     the owner saw when he tried to scroll.
///   * Scrolling needs **wheel** events: buttons 4 and 5, which
///     `Terminal.encodeButton` maps into the 64/65 range.
///
/// So this installs one pan recogniser of its own and fires wheel notches out of
/// it. Three deliberate boundaries:
///
///   * **`mouseMode == .off` is left alone.** `TerminalView` is a `UIScrollView`
///     and its `drawTerminalContents` picks the first visible row out of
///     `contentOffset.y`, not out of `yDisp`; its own pan therefore already
///     scrolls the scrollback, with momentum, rubber banding and an indicator.
///     `scrollUp(lines:)` cannot stand in for that mid-drag, because
///     `updateScroller` early-returns while `isTracking` — the row moves and no
///     pixel does until the finger lifts. Declining the gesture there is both
///     less code and a better scroll than anything written here.
///   * **A live selection wins.** Long press, Select, then drag is the only way
///     to select text with mouse reporting on, and it stays that way.
///   * **Horizontal drags are not ours.** They fall through to SwiftTerm's mouse
///     pan, which is tmux's own drag-to-select.
///
/// `allowMouseReporting` is deliberately left `true`: turning it off would fix
/// the swipe by breaking tmux pane and window clicking, which is worth keeping.
///
/// It also puts the keyboard away once a swipe starts reading history, which is
/// the other half of making a phone usable for looking at output. See
/// `dismissKeyboard`.
///
/// Main thread only, like `TerminalController`: UIKit gestures and the display
/// link both arrive there and nothing else touches this.
final class TerminalSwipeScroller: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private var pan: UIPanGestureRecognizer?

    /// The app-wide scroll speed, asked for rather than handed over.
    ///
    /// Called at the start of every gesture, so changing the setting is live on
    /// the very next swipe rather than on the next time the terminal is opened.
    /// A closure rather than a stored value because this object outlives any one
    /// SwiftUI update and must not hold a stale copy; a closure rather than a
    /// reference to the store because a gesture has no business knowing what a
    /// settings file is.
    var speed: () -> TerminalScrollSpeed = { .default }

    private var accumulator = WheelScrollAccumulator(cellHeight: 1)
    /// Where the wheel is reported from. Frozen at lift-off, so the coast keeps
    /// reporting into the pane the finger was over.
    private var reportPoint: CGPoint = .zero

    private var decay: FlickDecay?
    private var coastLink: CADisplayLink?
    private var lastCoastTime: CFTimeInterval = 0

    /// Whether this gesture has already put the keyboard away, so one long
    /// swipe resigns once rather than on every callback.
    private var didDismissKeyboard = false

    func attach(to view: TerminalView) {
        detach()
        self.view = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
        self.pan = pan
    }

    func detach() {
        stopCoasting()
        if let pan, let view { view.removeGestureRecognizer(pan) }
        pan = nil
        view = nil
    }

    deinit {
        coastLink?.invalidate()
    }

    // MARK: Gesture

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        switch gesture.state {
        case .began:
            stopCoasting()
            accumulator = WheelScrollAccumulator(cellHeight: Self.cellHeight(of: view),
                                                 speed: speed())
            reportPoint = gesture.location(in: view)
            didDismissKeyboard = false
        case .changed:
            let translation = gesture.translation(in: view)
            // Reset every callback so `translation` is a delta rather than the
            // total; the accumulator carries the remainder itself.
            gesture.setTranslation(.zero, in: view)
            reportPoint = gesture.location(in: view)
            let notches = accumulator.notches(forTranslation: translation.y)
            if notches > 0 { dismissKeyboard() }
            emit(notches)
        case .ended:
            startCoasting(velocity: gesture.velocity(in: view).y)
        case .cancelled, .failed:
            stopCoasting()
        default:
            break
        }
    }

    /// Vertical, mouse-reporting, no live selection. Anything else is somebody
    /// else's gesture and this one fails immediately so they can have it.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === self.pan,
              let view else { return true }
        guard view.getTerminal().mouseMode != .off else { return false }
        guard !view.selectionActive else { return false }
        let translation = pan.translation(in: view)
        return abs(translation.y) > abs(translation.x)
    }

    /// How the conflict with SwiftTerm's own recognisers is resolved.
    ///
    /// Returning true here means the *other* recogniser waits until this one has
    /// failed, so a vertical swipe reaches this handler and never reaches
    /// `panMouseHandler`. It is asked per pair and re-asked every touch, which is
    /// what makes it the right tool: `panMouseGesture` is created lazily by
    /// `mouseModeChanged` and `panSelectionGesture` by a selection, so neither
    /// exists at the moment this scroller is attached and a static
    /// `require(toFail:)` could not name them. Nothing is removed from the view,
    /// so every gesture SwiftTerm installs is still there and still works the
    /// moment `gestureRecognizerShouldBegin` above declines.
    ///
    /// Taps and the long press are untouched: only pans are claimed.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, other is UIPanGestureRecognizer else { return false }
        // In a plain shell this scroller does nothing, so it must not insert
        // itself into the scroll view's own gesture graph either.
        guard let view, view.getTerminal().mouseMode != .off else { return false }
        return true
    }

    // MARK: Keyboard

    /// Puts the keyboard away the first time a swipe actually scrolls back into
    /// history.
    ///
    /// The keyboard eats over half a phone screen, and the moment the finger
    /// starts scrolling the user is reading, not typing. Three deliberate
    /// boundaries, all of them about not taking a decision the user did not
    /// make:
    ///
    ///   * **On a scroll, not on a touch.** This is only reached once the
    ///     accumulator has charged a whole notch, so a tap, a long press and a
    ///     sub-notch nudge all leave the keyboard alone.
    ///   * **On the backward direction only.** A positive notch count is the
    ///     finger travelling down, which is scrolling *up* into history: reading
    ///     old output, unambiguously. Swiping the other way is the recovery from
    ///     an overshoot and often ends back at the prompt with something still
    ///     to type, so it is left alone. In practice this costs nothing, because
    ///     you cannot scroll forward before you have scrolled back.
    ///   * **`resignFirstResponder`, and nothing else.** No window frames, no
    ///     `endEditing` broadcast. SwiftTerm's own single tap calls
    ///     `becomeFirstResponder` whenever it is not the first responder, so a
    ///     tap anywhere on the terminal brings the keyboard straight back, and
    ///     that is the whole undo.
    private func dismissKeyboard() {
        guard !didDismissKeyboard, let view, view.isFirstResponder else { return }
        didDismissKeyboard = true
        _ = view.resignFirstResponder()
    }

    // MARK: Coasting

    private func startCoasting(velocity: CGFloat) {
        // The budget is stated in notches and spent in points, so it means the
        // same amount of text at every speed setting.
        let budget = accumulator.pointsPerNotch * CGFloat(FlickDecay.maxCoastNotches)
        let decay = FlickDecay(velocity: velocity, maxTravel: budget)
        guard decay.isCoasting else { return }
        self.decay = decay
        lastCoastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(coast(_:)))
        link.add(to: .main, forMode: .common)
        coastLink = link
    }

    private func stopCoasting() {
        coastLink?.invalidate()
        coastLink = nil
        decay = nil
        accumulator.reset()
    }

    @objc private func coast(_ link: CADisplayLink) {
        guard var decay else {
            stopCoasting()
            return
        }
        // Clamped both ways: a first tick with a stale timestamp would charge a
        // huge distance, and a stalled main thread would charge one just as big.
        let dt = min(max(link.timestamp - lastCoastTime, 1.0 / 120), 1.0 / 20)
        lastCoastTime = link.timestamp
        let distance = decay.step(dt: CGFloat(dt))
        self.decay = decay
        emit(accumulator.notches(forTranslation: distance))
        if !decay.isCoasting { stopCoasting() }
    }

    // MARK: Emission

    private func emit(_ notches: Int) {
        guard notches != 0, let view else { return }
        let terminal = view.getTerminal()
        // The mode can change under a coast — an application exiting drops mouse
        // reporting — so it is re-read per emission rather than latched.
        guard terminal.mouseMode != .off else {
            stopCoasting()
            return
        }
        let hit = Self.cell(of: view, at: reportPoint)
        // Button 4 is a wheel notch up and 5 is down; `encodeButton` maps them
        // to 64 and 65, the range xterm reserves for the wheel. Press with no
        // release: a notch has no release, and asking for one would encode a 3
        // and land as a button-up at the far end.
        let flags = terminal.encodeButton(button: notches > 0 ? 4 : 5,
                                          release: false,
                                          shift: false,
                                          meta: false,
                                          control: false)
        for _ in 0..<abs(notches) {
            terminal.sendEvent(buttonFlags: flags,
                               x: hit.col,
                               y: hit.row,
                               pixelX: hit.pixelX,
                               pixelY: hit.pixelY)
        }
    }

    /// The cell height, derived from the laid-out grid rather than from
    /// SwiftTerm's `cellDimension`, which is internal to the package. `rows` is
    /// itself `floor(height / cellHeight)`, so this overstates by less than one
    /// row's worth across the whole viewport — irrelevant to a scroll ratio, and
    /// self-correcting when the font size changes.
    private static func cellHeight(of view: TerminalView) -> CGFloat {
        let rows = view.getTerminal().rows
        guard rows > 0, view.bounds.height > 0 else { return 16 }
        return view.bounds.height / CGFloat(rows)
    }

    /// Where the wheel notch is reported from, in screen cells.
    ///
    /// `location(in:)` on a scroll view answers in *content* coordinates, and a
    /// mouse report wants the screen cell, so the offset comes back out first.
    /// tmux uses this to decide which pane scrolls, which is why the touch point
    /// is carried at all rather than reporting the cursor cell.
    private static func cell(of view: TerminalView,
                             at point: CGPoint) -> (col: Int, row: Int, pixelX: Int, pixelY: Int) {
        let terminal = view.getTerminal()
        let bounds = view.bounds
        let visibleX = min(max(point.x - view.contentOffset.x, 0), max(bounds.width - 1, 0))
        let visibleY = min(max(point.y - view.contentOffset.y, 0), max(bounds.height - 1, 0))
        let cellWidth = terminal.cols > 0 && bounds.width > 0
            ? bounds.width / CGFloat(terminal.cols) : 8
        let cellHeight = Self.cellHeight(of: view)
        let col = min(max(Int(visibleX / max(cellWidth, 1)), 0), max(terminal.cols - 1, 0))
        let row = min(max(Int(visibleY / max(cellHeight, 1)), 0), max(terminal.rows - 1, 0))
        return (col, row, Int(visibleX), Int(visibleY))
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

    /// A/B switch for measurement, debug builds only. `true` is the shipping
    /// path (one feed per displayed frame). Launching a debug build with
    /// `-LandlineLegacyFeed` restores the incumbent behaviour — one synchronous
    /// `TerminalView.feed` per WebSocket message — so before/after numbers come
    /// off the identical workload on the identical device rather than off two
    /// different builds. A release build always coalesces.
    let coalescing: Bool = {
        #if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("-LandlineLegacyFeed")
        #else
        return true
        #endif
    }()

    /// The frame probe costs a permanently running display link, so it only runs
    /// when someone asked for numbers.
    private let measuring: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LANDLINE_PERF"] == "1"
        #else
        return false
        #endif
    }()

    /// Pending bytes plus the index of the first unconsumed one. Draining by
    /// advancing an index and compacting occasionally is O(n) total; repeated
    /// `removeFirst(k)` on a multi-megabyte buffer is O(n²).
    private var pending: [UInt8] = []
    private var pendingHead = 0
    private var link: CADisplayLink?

    /// How long one drain may hold the main thread. A frame is 16.6ms at 60Hz;
    /// a quarter of one keeps the UI and the keyboard responsive while `cat`ing
    /// something enormous. Whatever is left over rides the next tick.
    private static let frameBudgetSeconds: Double = 0.004
    /// Doubled while the backlog is large: nobody reads the middle of a 4 MiB
    /// `cat`, they want the end, so falling further behind is worse than one
    /// slightly longer frame. Still under a single 60Hz frame.
    private static let catchUpBudgetSeconds: Double = 0.008
    private static let catchUpThreshold = 1 << 20
    /// Bounds on one slice. The slice itself is sized from the measured parse
    /// rate so the budget is actually honoured; a fixed slice cannot honour it,
    /// because how long 64 KiB takes depends on the build, the device, and what
    /// the bytes are.
    private static let minSliceBytes = 2 * 1024
    private static let maxSliceBytes = 256 * 1024
    /// Compact the buffer once the consumed prefix passes this.
    private static let compactThreshold = 512 * 1024

    /// Measured SwiftTerm parse throughput, exponentially smoothed. Seeded low
    /// so the very first frame after attach cannot overshoot.
    private var bytesPerSecond: Double = 1_000_000

    // MARK: Attachment

    func attach(to view: TerminalView) {
        terminalView = view
        if coalescing { startLink() }
        if measuring { probe.start() }
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

    func resetMetrics() {
        metrics = FeedMetrics()
        if measuring { probe.start() }
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
        let backlog = pending.count - pendingHead
        drain(budget: backlog >= Self.catchUpThreshold
              ? Self.catchUpBudgetSeconds
              : Self.frameBudgetSeconds)
        if pendingHead >= pending.count {
            link?.isPaused = true
        }
    }

    private func drain(budget: Double) {
        guard let view = terminalView, pendingHead < pending.count else { return }

        let started = CACurrentMediaTime()
        var fedThisPass = false

        while pendingHead < pending.count {
            let remaining = budget - (CACurrentMediaTime() - started)
            if fedThisPass && remaining <= 0 { break }
            // Size the next slice to what the measured parse rate can finish in
            // the time left, so the loop stops before the budget instead of
            // after it. `budget` is infinite on an explicit flush.
            let window = min(max(remaining, 0.0005), 1.0)
            let allowance = min(Self.maxSliceBytes,
                                max(Self.minSliceBytes, Int(window * bytesPerSecond)))
            let end = min(pendingHead + allowance, pending.count)

            let sliceStart = CACurrentMediaTime()
            // ArraySlice: no copy, and SwiftTerm's parser reads it in place.
            view.feed(byteArray: pending[pendingHead..<end])
            let sliceSeconds = max(CACurrentMediaTime() - sliceStart, 1e-6)
            // Smoothed, so one unusually escape-heavy slice does not whipsaw
            // the next frame's allowance.
            bytesPerSecond = bytesPerSecond * 0.75 + (Double(end - pendingHead) / sliceSeconds) * 0.25

            pendingHead = end
            fedThisPass = true
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
        // SwiftTerm draws glyph cells over a transparent backdrop and lets the
        // layer colour show through the gaps (see its `setupOptions`), so the
        // ground has to be set on the layer. Setting `backgroundColor` instead
        // leaves strips of uninitialised backing store visible while scrolling.
        view.layer.backgroundColor = palette.background.cgColor
        view.caretColor = palette.cursor
        view.caretTextColor = palette.cursorText
        view.selectedTextBackgroundColor = palette.selection
        view.selectedTextForegroundColor = palette.selectionText
        view.keyboardAppearance = palette.isDark ? .dark : .light
    }

    /// The family last applied, so the pinch gesture can resize without having
    /// to be told again which face it is resizing. Empty is the bundled face.
    private(set) var fontFamily: String = TerminalFont.bundledFamilySentinel
    /// The size last applied, for the same reason: the pinch starts from what
    /// is on screen, which since sizes went per-host is not the app default.
    private(set) var fontSize: CGFloat = TerminalFont.defaultSize
    /// The pinch settled on a new size. The screen persists it to the host;
    /// this type has no business knowing where hosts are kept.
    var onFontSizeChange: ((CGFloat) -> Void)?

    /// Resolved appearance in, exactly like `apply(palette:)`: the screen owns
    /// the decision, this owns the UIKit consequences.
    func apply(fontFamily: String, size: CGFloat) {
        // Recorded even with no view attached, so the family survives the gap
        // between a SwiftUI update and `makeUIView`.
        self.fontFamily = fontFamily
        self.fontSize = size
        guard let view = terminalView else { return }
        // Bundled JetBrains Mono Nerd Font Mono unless the user picked a face,
        // and cascaded behind it when they did — see `TerminalFont`. Prompts
        // built with starship, powerlevel10k, or a patched vim theme draw their
        // icons from the Private Use Area, which SF Mono and most side-loaded
        // faces have no glyphs for: every one of them renders as tofu. The
        // "Mono" cut is deliberate, its icons are single cell width, so the grid
        // stays aligned. Explicit bold and italic faces so vim and tmux status
        // lines do not fall back to a proportional face.
        let normal = TerminalFont.font(family: fontFamily, size: size, bold: false)
        let bold = TerminalFont.font(family: fontFamily, size: size, bold: true)
        view.setFonts(
            normal: normal,
            bold: bold,
            italic: normal,
            boldItalic: bold
        )
    }
}

// MARK: - Font

/// Which face the terminal draws in, and how a face the user installed is made
/// safe to draw a prompt with.
///
/// The problem this type exists to solve: a font installed through an iOS
/// configuration profile (iFont and friends) registers system-wide, so
/// `UIFont(name:)` can see it from any app — but almost none of those fonts are
/// Nerd Font patched. Most side-loaded faces are not. Handing SwiftTerm a bare
/// `UIFont(name: "BerkeleyMono", ...)` therefore brings the tofu bug straight
/// back: starship, powerlevel10k and every patched vim theme draw their icons
/// out of the Private Use Area, which an unpatched font has no glyphs for.
///
/// So the user's face is the *primary* and the bundled Nerd Font is a cascade
/// fallback behind it. CoreText consults the cascade list per character, so
/// letters and digits come from the user's font and only the PUA icons fall
/// through to the bundled one. This works with SwiftTerm specifically because
/// its Apple renderer shapes each row through `CTLineCreateWithAttributedString`
/// and then reads each run's *resolved* font back out of
/// `CTRunGetAttributes(run)[.font]` before drawing — so a substituted run is
/// drawn in the font CoreText substituted, not in the primary.
enum TerminalFont {
    /// PostScript names of the bundled faces, read from the files themselves
    /// rather than guessed: a wrong name fails silently back to the system
    /// font, which looks like the tofu bug never got fixed.
    private static let regularName = "JetBrainsMonoNFM-Regular"
    private static let boldName = "JetBrainsMonoNFM-Bold"

    /// What `Host.fontFamily` holds for "use the bundled face".
    static let bundledFamilySentinel = ""
    /// Named in the picker so the bundled face is not mistaken for a system one.
    static let bundledDisplayName = "JetBrains Mono NF (bundled)"

    /// The bundled Nerd Font at `size`, falling back to SF Mono if the font
    /// failed to register (a missing UIAppFonts entry, say).
    static func nerd(size: CGFloat, bold: Bool) -> UIFont {
        if let font = UIFont(name: bold ? boldName : regularName, size: size) {
            return font
        }
        assertionFailure("bundled Nerd Font missing; check UIAppFonts and the Resources/Fonts group")
        return UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// The family the bundled files actually register under. Read off the font
    /// rather than written down, so a font update that changes the family name
    /// cannot leave a stale literal behind.
    static var bundledFamilyName: String {
        UIFont(name: regularName, size: 12)?.familyName ?? "JetBrainsMono Nerd Font Mono"
    }

    /// `family` as the primary face with the bundled Nerd Font cascaded behind
    /// it. An empty or uninstalled family is the bundled face outright.
    ///
    /// The bundled descriptor goes at the *head* of the cascade list and the
    /// platform's own default list after it, because replacing the default list
    /// outright would strand CJK, emoji and Arabic cells — a terminal has to be
    /// able to render whatever the far end sends, not only what the chosen
    /// family covers.
    static func font(family: String, size: CGFloat, bold: Bool) -> UIFont {
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        // `UIFont(descriptor:)` never returns nil: an unknown family silently
        // resolves to Helvetica, which on a terminal grid is a disaster that
        // looks like a rendering bug. Ask whether the family exists first.
        guard !trimmed.isEmpty, isInstalled(family: trimmed) else {
            return nerd(size: size, bold: bold)
        }

        guard let face = faceName(in: trimmed, bold: bold) else {
            // isInstalled just said yes, so a nil face here is the two-notions
            // -of-installed bug returning in a new place. It has already shipped
            // twice as a silent fallback that looked like the user's font simply
            // not applying, so make it loud in debug rather than quiet forever.
            assertionFailure("'\(trimmed)' reports installed but yields no usable face")
            return nerd(size: size, bold: bold)
        }
        let descriptor = UIFontDescriptor(fontAttributes: [.name: face])
            .addingAttributes([.cascadeList: cascadeList(size: size, bold: bold)])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// The concrete PostScript face to use out of `family`.
    ///
    /// Matching on `.family` and letting CoreText choose is what the obvious
    /// implementation does, and it is wrong: the match is a nearest-neighbour
    /// over every registered face, and on "Courier New" it cheerfully hands
    /// back the *italic*. A terminal that silently turns italic because of a
    /// font pick is worse than one that refuses the font. So the face is
    /// chosen here, by weight, with italics excluded, and requested by exact
    /// name — which is the one lookup CoreText cannot reinterpret.
    ///
    /// A family with no bold face lands on its regular face rather than a
    /// synthesised smear, which is what a terminal wants.
    private static func faceName(in family: String, bold: Bool) -> String? {
        let names = UIFont.fontNames(forFamilyName: family)
        // A provider-installed family enumerates NO faces, exactly as it
        // appears in no family list. Returning nil here sent the terminal to
        // the bundled font while the picker cheerfully showed the user's font
        // as selected: the same blindness as isInstalled, one layer down.
        // The family name itself resolves, so ask for that.
        if names.isEmpty {
            guard let base = UIFont(name: family, size: probeSize),
                base.familyName.caseInsensitiveCompare(family) == .orderedSame
            else { return nil }
            guard bold else { return base.fontName }
            // Derive bold from the descriptor. UIFont(descriptor:) never
            // returns nil and will happily hand back Helvetica, so the family
            // is re-checked before the bold face is trusted.
            if let boldDescriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
                let boldFont = UIFont(descriptor: boldDescriptor, size: probeSize)
                if boldFont.familyName.caseInsensitiveCompare(family) == .orderedSame {
                    return boldFont.fontName
                }
            }
            // No bold face: the regular one beats swapping fonts mid-line.
            return base.fontName
        }
        let target: CGFloat = bold ? UIFont.Weight.bold.rawValue : UIFont.Weight.regular.rawValue
        var best: (name: String, distance: CGFloat)?
        for name in names {
            guard let font = UIFont(name: name, size: 12) else { continue }
            let descriptor = font.fontDescriptor
            guard !descriptor.symbolicTraits.contains(.traitItalic) else { continue }
            let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            let weight = (traits?[.weight] as? CGFloat) ?? UIFont.Weight.regular.rawValue
            let distance = abs(weight - target)
            if best == nil || distance < best!.distance { best = (name, distance) }
        }
        // An italic-only family is still the family the user asked for; taking
        // its one face beats swapping in a different font behind their back.
        return best?.name ?? names.first
    }

    /// The bundled face first, then whatever the platform would have cascaded
    /// to anyway.
    private static func cascadeList(size: CGFloat, bold: Bool) -> [UIFontDescriptor] {
        let bundled = UIFontDescriptor(fontAttributes: [.name: bold ? boldName : regularName])
        return [bundled] + systemCascade(size: size)
    }

    /// The platform's own fallback chain, re-expressed as `UIFontDescriptor`s.
    ///
    /// The conversion is not ceremony. On iOS `UIFontDescriptor` is *not* toll
    /// free bridged to `CTFontDescriptorRef` (unlike `NSFontDescriptor` on the
    /// Mac), so `CTFontCopyDefaultCascadeListForLanguages(...) as? [UIFontDescriptor]`
    /// quietly yields nil and the whole default chain vanishes — which showed
    /// up as a terminal that could no longer draw a CJK or Arabic cell the
    /// moment the user picked a Latin-only family. Copying the name attribute
    /// across is enough: every entry in the default list names a concrete face.
    private static func systemCascade(size: CGFloat) -> [UIFontDescriptor] {
        let base = UIFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        guard let raw = CTFontCopyDefaultCascadeListForLanguages(base, nil) as? [CTFontDescriptor]
        else {
            assertionFailure("no default cascade list; non-Latin cells will render as tofu")
            return []
        }
        return raw.compactMap { descriptor in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute)
                as? String else { return nil }
            return UIFontDescriptor(fontAttributes: [.name: name])
        }
    }

    /// True when at least one face is registered under this family name. This
    /// is the only reliable "does this font exist" question on iOS.
    static func isInstalled(family: String) -> Bool {
        // The enumeration answer first, because it is cheap and covers every
        // system and bundled face.
        if !UIFont.fontNames(forFamilyName: family).isEmpty { return true }
        // Then the one that matters for a font a provider app installed.
        // Those never appear in ANY enumeration API on iOS, so asking
        // `fontNames(forFamilyName:)` alone reports a perfectly working,
        // already-granted font as missing. It is what made the picker say
        // "NOT INSTALLED" about a profile-installed font in the same breath as
        // confirming it was available, and worse, it made the terminal fall
        // back to the bundled face. Instantiating is the only honest test.
        guard let font = UIFont(name: family, size: probeSize) else { return false }
        // `UIFont(name:)` is nil for an unknown name, but guard against a
        // near-miss resolving to some other family.
        return font.familyName.caseInsensitiveCompare(family) == .orderedSame
    }

    // MARK: Enumeration
    //
    // The assumption this section used to make — that a font installed through
    // a configuration profile lands in `UIFont.familyNames` like any other — is
    // wrong, and it is the reason build 2 showed the owner only Courier New and
    // Menlo on a phone with a profile-installed font. CoreText says so
    // outright (CTFontManager.h, `CTFontManagerRequestFonts`):
    //
    //   "On iOS, fonts registered by font provider applications in the
    //    persistent scope are not automatically available to other
    //    applications. Client applications must call this function to make the
    //    requested fonts available for font descriptor matching."
    //
    // Not available for matching means not enumerated either, by design. So
    // enumeration is now a union of every source that can name a family, each
    // counted separately (see `EnumerationCensus`) so the picker can say which
    // API saw what instead of leaving the owner to guess, and a name that is
    // listed but cannot yet be instantiated is kept as a distinct state rather
    // than dropped — dropping it is what makes the font invisible.

    /// True when `UIFont` can actually instantiate a face out of this family.
    ///
    /// The distinction that matters: a provider-installed family can be *named*
    /// by an enumeration source and still be unusable until
    /// `CTFontManagerRequestFonts` has run, and every measurement in this file
    /// (the monospace width test, the prompt-icon lookup) silently answers about
    /// the system fallback font when handed a family it cannot resolve. So the
    /// question is asked explicitly instead of being inferred from a measurement
    /// that cannot fail.
    static func isResolvable(family: String) -> Bool {
        !UIFont.fontNames(forFamilyName: family).isEmpty
    }

    /// How many candidate families each enumeration source returned.
    ///
    /// Not shown to anyone: the union below has to ask three different APIs
    /// because each of them can see a font the others cannot, and counting them
    /// separately is what lets a test prove all three are still being asked.
    struct EnumerationCensus: Equatable {
        /// `UIFont.familyNames`.
        var system = 0
        /// `CTFontManagerCopyAvailableFontFamilyNames()`.
        var available = 0
        /// `CTFontManagerCopyRegisteredFontDescriptors(.persistent, true)`.
        var registered = 0
    }

    /// A family name plus whether the phone can draw it yet.
    struct Candidate: Hashable {
        let family: String
        /// False when some source named the family but `UIFont` cannot
        /// instantiate it — the provider-installed case that
        /// `requestAccess(families:completion:)` exists to unblock.
        let isResolvable: Bool
    }

    private enum Candidacy {
        case ready
        case needsAccess
        case rejected
    }

    /// Every monospaced family the phone can see, bundled face excluded (it is
    /// offered separately, as the default), sorted and deduplicated, together
    /// with the per-source counts.
    ///
    /// Detection is measured, not declared: plenty of hand-built monospaced
    /// fonts never set the `isFixedPitch`/`traitMonoSpace` flag in their OS/2
    /// table, so trusting the symbolic trait alone would hide exactly the font
    /// someone went to the trouble of side-loading. Measuring four glyphs that
    /// differ wildly in a proportional face is what actually catches those —
    /// but only for a family that resolves. An unresolvable one is admitted
    /// without the test, because measuring it would measure the fallback font.
    static func candidates() -> (list: [Candidate], census: EnumerationCensus) {
        var verdicts: [String: Candidacy] = [:]
        var census = EnumerationCensus()

        func count(_ names: [String], into slot: WritableKeyPath<EnumerationCensus, Int>) {
            var seen: Set<String> = []
            var total = 0
            for raw in names {
                let family = raw.trimmingCharacters(in: .whitespaces)
                guard !family.isEmpty, seen.insert(family).inserted else { continue }
                let verdict: Candidacy
                if let cached = verdicts[family] {
                    verdict = cached
                } else {
                    verdict = candidacy(of: family)
                    verdicts[family] = verdict
                }
                if verdict != .rejected { total += 1 }
            }
            census[keyPath: slot] = total
        }

        count(UIFont.familyNames, into: \.system)
        count(availableFamilyNames(), into: \.available)
        count(registeredFamilyNames(), into: \.registered)

        // Granted fonts are invisible to all three sources above: iOS never
        // lists a provider-installed font, even after the user has approved
        // it. Without remembering them, a font the owner successfully
        // requested would vanish from the picker on the next launch and have
        // to be typed in again. These are not counted in the census, which
        // deliberately reports only what the system APIs returned.
        for family in grantedFamilies where verdicts[family] == nil {
            let verdict = candidacy(of: family)
            if verdict != .rejected { verdicts[family] = verdict }
        }

        let list = verdicts
            .filter { $0.value != .rejected }
            .map { Candidate(family: $0.key, isResolvable: $0.value == .ready) }
            .sorted { $0.family.localizedCaseInsensitiveCompare($1.family) == .orderedAscending }
        return (list, census)
    }

    /// Family names only, for the callers that never cared about the census.
    static func availableMonospaceFamilies() -> [String] {
        candidates().list.map(\.family)
    }

    /// Whether a name is worth offering, and in what state.
    private static func candidacy(of family: String) -> Candidacy {
        // Dot-prefixed names are the platform's private system faces (.SFUI and
        // friends). They are not installable, not pickable, and listing them
        // would bury the one font the owner is actually looking for.
        guard !family.hasPrefix("."), family != bundledFamilyName else { return .rejected }
        guard isResolvable(family: family) else { return .needsAccess }
        return isMonospaced(family: family) ? .ready : .rejected
    }

    /// CoreText's own family list. Distinct from `UIFont.familyNames` in
    /// principle — it is the font *manager*'s view rather than UIKit's — so it
    /// is asked separately even though the two usually agree.
    private static func availableFamilyNames() -> [String] {
        (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
    }

    /// Families the font manager has a registration record for.
    ///
    /// Honest about its own ceiling: CTFontManager.h says that for the
    /// persistent scope "only macOS can return fonts registered by any process.
    /// Other platforms can only return font descriptors registered by the
    /// application's process." So on iOS this can only ever see fonts *this* app
    /// registered, and a font installed by iFont will not appear here. It is
    /// asked anyway because a zero is itself the diagnosis, and because the
    /// alternative is guessing. `kCTFontManagerScopeUser` is not a second source
    /// to try: the header defines it as the same raw value (2) as
    /// `kCTFontManagerScopePersistent`, so one query covers both.
    private static func registeredFamilyNames() -> [String] {
        guard let descriptors = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true)
            as? [CTFontDescriptor] else { return [] }
        return descriptors.compactMap { descriptor in
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute)
                as? String { return family }
            // A descriptor registered by PostScript name still names something
            // askable; the family is recovered through UIFont below.
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute)
                as? String else { return nil }
            return UIFont(name: name, size: probeSize)?.familyName ?? name
        }
    }

    // MARK: Requesting access

    /// What one `CTFontManagerRequestFonts` round trip actually told us.
    struct RequestOutcome {
        /// Names iOS reported it could not resolve, read back off the
        /// descriptors the completion handler returns.
        let unresolved: [String]
        /// The family name that is now usable, read back off `UIFont` rather
        /// than inferred. Nil means the request achieved nothing.
        let resolvedFamily: String?

        var succeeded: Bool { resolvedFamily != nil }
    }

    /// Ask iOS to make `name` available to this process, and report what
    /// happened.
    ///
    /// This is the only call that can reach a font installed by a provider app,
    /// and on iOS it may put a system dialog in front of the user, so it is
    /// never fired speculatively — only from an explicit tap, or once per
    /// family per launch for a family this host is already configured to use.
    ///
    /// Two descriptors go in per name, because the caller cannot know which
    /// kind of name was typed: `kCTFontNameAttribute` (what
    /// `CTFontDescriptorCreateWithNameAndSize` sets, and the right key for a
    /// PostScript name copied out of the provider app) and
    /// `kCTFontFamilyNameAttribute` (what `Host.fontFamily` actually holds).
    /// The unresolved list is reported but not trusted as the verdict: with
    /// both keys in flight, one of the two comes back unresolved even on a
    /// complete success. `UIFont` is the ground truth, so it is asked last.
    static func requestAccess(name: String, completion: @escaping (RequestOutcome) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            completion(RequestOutcome(unresolved: [], resolvedFamily: nil))
            return
        }
        let descriptors: [CTFontDescriptor] = [
            CTFontDescriptorCreateWithNameAndSize(trimmed as CFString, 0),
            CTFontDescriptorCreateWithAttributes(
                [kCTFontFamilyNameAttribute: trimmed] as CFDictionary),
        ]
        // CTFontManagerRequestFonts does not promise to call back. Measured:
        // with the user-fonts entitlement present but no context able to
        // present the grant dialog, the handler never fires at all, which
        // hung two tests for their full 20s timeout. A caller that waits
        // forever on it would strand the UI in a pending state, so the
        // callback is raced against a deadline and delivered exactly once.
        let delivered = OSAllocatedUnfairLock(initialState: false)
        func deliverOnce(_ outcome: RequestOutcome) {
            let first = delivered.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            guard first else { return }
            // Record a win so the family survives into the next launch's
            // picker; nothing else can remember it.
            if let resolved = outcome.resolvedFamily { rememberGranted(family: resolved) }
            // The handler's queue is undocumented; every caller here touches
            // SwiftUI state or UIKit, so it is pinned to main.
            DispatchQueue.main.async { completion(outcome) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) {
            deliverOnce(RequestOutcome(unresolved: [trimmed], resolvedFamily: resolvedFamily(for: trimmed)))
        }

        CTFontManagerRequestFonts(descriptors as CFArray) { unresolvedDescriptors in
            let unresolved = ((unresolvedDescriptors as? [CTFontDescriptor]) ?? [])
                .compactMap { descriptor -> String? in
                    (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String)
                        ?? (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String)
                }
            deliverOnce(RequestOutcome(unresolved: unresolved, resolvedFamily: resolvedFamily(for: trimmed)))
        }
    }

    /// How long to wait for the system font-grant dialog before giving up.
    /// Generous: the user has to read and answer a dialog inside it.
    static let requestTimeout: TimeInterval = 12

    /// The family name a typed string actually resolves to, or nil.
    ///
    /// Accepts either a family name or a PostScript face name, because a user
    /// reading a name out of iFont may copy either, and answers with the
    /// *family* — which is what `Host.fontFamily` is documented to hold.
    static func resolvedFamily(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let font = UIFont(name: trimmed, size: probeSize) { return font.familyName }
        if isInstalled(family: trimmed) { return trimmed }
        return nil
    }

    /// Families the user has successfully granted this app access to.
    ///
    /// Persisted because no enumeration API on iOS will ever name a
    /// provider-installed font, so this is the only record that it belongs in
    /// the picker. Entries are re-validated on read: a profile can be removed,
    /// and a name that no longer resolves should quietly stop being offered.
    private static let grantedKey = "terminal.grantedFontFamilies"

    static var grantedFamilies: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: grantedKey) ?? []
        return stored.filter { isInstalled(family: $0) }
    }

    static func rememberGranted(family: String) {
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var stored = UserDefaults.standard.stringArray(forKey: grantedKey) ?? []
        guard !stored.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        stored.append(trimmed)
        UserDefaults.standard.set(stored, forKey: grantedKey)
    }

    /// Families already asked about in this process, so a repeat visit to the
    /// terminal cannot put the system dialog up again and again.
    private static var requestedFamilies: Set<String> = []

    /// Request-on-use: a family this host is configured for that no longer
    /// resolves gets one request before the terminal gives up and draws the
    /// bundled face.
    ///
    /// The case this covers is the one that reads as the app losing the
    /// setting: access was granted once, the app was relaunched, and the
    /// per-process grant did not survive. Falling straight back to the bundled
    /// font there would be silent and wrong.
    ///
    /// `completion(true)` means the family became usable and the caller should
    /// re-apply the font. Anything already usable, already asked about, or empty
    /// completes `false` without touching CoreText.
    static func requestIfUnresolved(family: String, completion: @escaping (Bool) -> Void) {
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !isInstalled(family: trimmed),
              requestedFamilies.insert(trimmed).inserted else {
            completion(false)
            return
        }
        requestAccess(name: trimmed) { outcome in completion(outcome.succeeded) }
    }

    /// Test seam: the once-per-launch guard is process state, and a test that
    /// asserts on it has to be able to put it back.
    static func resetRequestGuard() { requestedFamilies.removeAll() }

    /// A family counts as monospaced if any of its faces declares the trait or
    /// measures as fixed pitch.
    static func isMonospaced(family: String) -> Bool {
        for name in UIFont.fontNames(forFamilyName: family) {
            guard let font = UIFont(name: name, size: probeSize) else { continue }
            if font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) { return true }
            if hasUniformAdvances(font) { return true }
        }
        return false
    }

    /// Whether a family covers the Private Use Area codepoints a prompt draws.
    /// Only the bundled face is expected to; the answer is what the picker uses
    /// to tell the truth about a chosen font rather than to guess.
    static func hasPromptIcons(family: String) -> Bool {
        guard let name = UIFont.fontNames(forFamilyName: family).first,
              let font = UIFont(name: name, size: probeSize) else { return false }
        return promptIconCodepoints.allSatisfy { glyph(for: $0, in: font) != 0 }
    }

    /// Powerline branch and separator, plus a Nerd Font device icon. Three
    /// codepoints from three different blocks, so a font that patched only one
    /// range does not read as fully patched.
    static let promptIconCodepoints: [UnicodeScalar] = [
        UnicodeScalar(0xE0A0)!, UnicodeScalar(0xE0B0)!, UnicodeScalar(0xF07C)!,
    ]

    /// Big enough that rounding cannot make two different advances compare
    /// equal, small enough to cost nothing.
    private static let probeSize: CGFloat = 64

    /// 0 is the missing-glyph slot, which is the tofu box.
    static func glyph(for scalar: UnicodeScalar, in font: UIFont) -> CGGlyph {
        var chars = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, chars.count) else {
            return 0
        }
        // A surrogate pair maps to one glyph in the first slot.
        return glyphs.first ?? 0
    }

    /// "i", "W", "1" and " " have wildly different advances in a proportional
    /// face and identical ones in a fixed-pitch face.
    private static func hasUniformAdvances(_ font: UIFont) -> Bool {
        let ct = font as CTFont
        var chars: [UniChar] = Array("iW1 ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        // False if any of the four is missing, which disqualifies symbol and
        // icon fonts before they can accidentally measure uniform.
        guard CTFontGetGlyphsForCharacters(ct, &chars, &glyphs, chars.count) else { return false }
        guard glyphs.allSatisfy({ $0 != 0 }) else { return false }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyphs, &advances, glyphs.count)
        guard let first = advances.first, first.width > 0 else { return false }
        return advances.allSatisfy { abs($0.width - first.width) < 0.01 }
    }

    // MARK: Picker options

    /// One row of the font picker.
    struct Option: Identifiable, Hashable {
        /// Exactly what goes in `Host.fontFamily`; empty is the bundled face.
        let family: String
        /// Set in the family it names, so the choice is visible.
        let displayName: String
        /// The family carries the Private Use Area icons a prompt draws.
        let hasPromptIcons: Bool
        /// Stored on this host but not currently registered on the phone —
        /// the configuration profile was removed, most likely.
        let isMissing: Bool
        /// Named by an enumeration source but not yet instantiable: a font a
        /// provider app installed, which iOS withholds until this app calls
        /// `CTFontManagerRequestFonts`. Shown, not dropped, because dropping it
        /// is precisely the bug — and offered as a request rather than as a
        /// selection, since nothing can be measured about it yet.
        let needsAccess: Bool

        var id: String { family }
        var isBundled: Bool { family.isEmpty }
        /// The phone can draw this family right now, so it has a specimen and
        /// its prompt-icon annotation is a measurement rather than a guess.
        var isResolved: Bool { !isMissing && !needsAccess }
    }

    /// The bundled face first, then every monospaced family the phone can see,
    /// then any family a source named but the phone cannot draw yet.
    /// `selected` is included even when it is no longer installed, so a removed
    /// profile shows up as a named, recoverable state instead of the setting
    /// appearing to have reset itself.
    static func options(selected: String = "") -> [Option] {
        var options: [Option] = [
            Option(family: bundledFamilySentinel,
                   displayName: bundledDisplayName,
                   hasPromptIcons: true,
                   isMissing: false,
                   needsAccess: false)
        ]
        var rows = candidates().list
        let trimmed = selected.trimmingCharacters(in: .whitespaces)
        let missing = !trimmed.isEmpty
            && !rows.contains { $0.family == trimmed }
            && trimmed != bundledFamilyName
        if missing { rows.append(Candidate(family: trimmed, isResolvable: false)) }
        for row in rows {
            let isMissing = missing && row.family == trimmed
            let needsAccess = !isMissing && !row.isResolvable
            options.append(Option(family: row.family,
                                  displayName: row.family,
                                  hasPromptIcons: row.isResolvable
                                      ? hasPromptIcons(family: row.family)
                                      : false,
                                  isMissing: isMissing,
                                  needsAccess: needsAccess))
        }
        return options
    }

    // MARK: Size

    static let minSize: CGFloat = 9
    static let maxSize: CGFloat = 22
    static let defaultSize: CGFloat = 13
    private static let key = "terminal.fontSize"

    /// The app-wide default point size, kept in UserDefaults.
    ///
    /// Size is a *per-host* setting now (`Host.fontSize`), alongside the palette
    /// and the family, so this is the value a host that has never been given one
    /// falls back to. It is still read rather than deleted because builds up to
    /// and including build 2 wrote the pinch gesture's result here, and throwing
    /// that away would reset the size of every existing host on upgrade.
    static var size: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: key)
            guard stored > 0 else { return defaultSize }
            return clamp(CGFloat(stored))
        }
        set {
            UserDefaults.standard.set(Double(clamp(newValue)), forKey: key)
        }
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(maxSize, max(minSize, value))
    }

    /// The size one host renders at. `Host.fontSize` is 0 for every host stored
    /// before the setting existed, and 0 keeps meaning "the app-wide default".
    static func size(forHost stored: Double) -> CGFloat {
        stored > 0 ? clamp(CGFloat(stored)) : size
    }
}

/// `TerminalView` that declines to answer the pixel-size queries.
///
/// tmux asks the terminal for its size in pixels (`CSI 14 t` and `CSI 18 t`)
/// after a resize. SwiftTerm answers, and if tmux is in copy mode at that
/// moment it reads the answer as typed keys, so a stray `?` opens copy mode's
/// search prompt and the pane appears to garble itself.
///
/// Dismissing the keyboard resizes the terminal, and scrolling is what puts
/// tmux in copy mode, so the two happen together constantly here and what used
/// to be a rare desktop annoyance became routine.
///
/// Declining costs nothing this app uses: the pixel dimensions matter to inline
/// image protocols (sixel, kitty graphics), which it does not implement. Every
/// other window command still goes to `super`.
final class LandlineTerminalView: TerminalView {
    override func windowCommand(
        source: Terminal,
        command: Terminal.WindowManipulationCommand
    ) -> [UInt8]? {
        switch command {
        case .reportTextAreaPixelDimension,
             .reportTerminalWindowPixelDimension,
             .reportSizeOfScreenInPixels,
             .reportCellSizeInPixels:
            return nil
        default:
            return super.windowCommand(source: source, command: command)
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
    /// Resolved the same way `palette` is: the screen reads it off the host and
    /// hands the answer down. Empty is the bundled Nerd Font.
    let fontFamily: String
    /// Already resolved through `TerminalFont.size(forHost:)`, so this is a
    /// concrete point size and never the 0 sentinel.
    let fontSize: CGFloat

    /// The app-wide settings, for the scroll speed the swipe gesture charges at.
    /// Optional so a preview or a test can hold this view without one, and
    /// deliberately not `private`: a private stored property would make the
    /// memberwise initialiser private too, and the screen above builds this by
    /// hand.
    @Environment(SettingsStore.self) var settingsStore: SettingsStore?

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

        let view = LandlineTerminalView(frame: .zero, font: nil, options: options)
        view.terminalDelegate = context.coordinator
        // SwiftTerm ships its own grey, rounded, iOS-styled key strip as the
        // input accessory. This app draws that keypad itself, in world; two of
        // them stacked is both a duplicate and a DESIGN.md violation.
        view.inputAccessoryView = nil
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
        controller.apply(fontFamily: fontFamily, size: fontSize)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        context.coordinator.controller = controller
        // A vertical swipe scrolls, whatever is running at the far end. See
        // `TerminalSwipeScroller` for why this cannot be left to SwiftTerm once
        // an application turns mouse reporting on.
        //
        // The store is handed over as a closure, not as a value: the scroller
        // asks it at the start of each gesture, so a change made on the settings
        // screen while a session is open is live on the next swipe. That is also
        // why `updateUIView` can stay empty.
        let store = settingsStore
        context.coordinator.scroller.speed = { [weak store] in
            store?.scrollSpeed ?? .default
        }
        context.coordinator.scroller.attach(to: view)

        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Intentionally empty. See the type comment.
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.scroller.detach()
        coordinator.controller?.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        weak var controller: TerminalController?
        /// Owned here rather than by `TerminalController` because it is a
        /// gesture, not a byte path: it lives and dies with the UIView.
        let scroller = TerminalSwipeScroller()
        private var pinchStartSize: CGFloat = TerminalFont.defaultSize

        init(controller: TerminalController) {
            self.controller = controller
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let controller else { return }
            switch gesture.state {
            case .began:
                // What is on screen, not the app-wide default: this host may
                // have its own size.
                pinchStartSize = controller.fontSize
            case .changed, .ended:
                let target = (pinchStartSize * gesture.scale).rounded()
                let clamped = TerminalFont.clamp(target)
                guard clamped != controller.fontSize else { return }
                // The family is not the pinch's business; it resizes whatever
                // face is already installed.
                controller.apply(fontFamily: controller.fontFamily, size: clamped)
                // Persisted to the host, so the size the owner pinched to is
                // the size that host opens at next time.
                controller.onFontSizeChange?(clamped)
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
