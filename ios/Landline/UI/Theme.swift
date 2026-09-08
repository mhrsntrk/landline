import SwiftUI

// Landline's visual world: micrographics (DESIGN.md).
//
// This file is the whole token layer. Nothing else in the app is allowed to
// invent a colour, a size, or a font: if it is not here, it does not exist.
// Structure is drawn with hairlines, ticks, and registration marks, never with
// fills or shadows, and every machine value is monospaced with tabular figures.

// MARK: - Tokens

enum Theme {

    // MARK: Chrome tokens (DESIGN.md, verbatim)

    /// `#282C34` terminal ground and app background.
    static let ground = Color(hexRGB: 0x282C34)
    /// `#21252B` bars, sheets, the second neutral layer.
    static let panel = Color(hexRGB: 0x21252B)
    /// `#2C313C` pressed and selected rows.
    static let raised = Color(hexRGB: 0x2C313C)
    /// `#3E4451` hairlines, tick marks, borders.
    static let rule = Color(hexRGB: 0x3E4451)
    /// `#ABB2BF` primary text.
    static let ink = Color(hexRGB: 0xABB2BF)
    /// `#D7DAE0` emphasis, active values.
    static let inkBright = Color(hexRGB: 0xD7DAE0)
    /// `#949CAB` micro-caps labels, secondary metadata, annotation.
    ///
    /// 5.07:1 on `ground`, 5.57:1 on `panel`, 4.72:1 on `raised`. This is the
    /// quietest ink in the system that is still allowed to carry a glyph.
    static let inkMuted = Color(hexRGB: 0x949CAB)
    /// `#5C6370` **non-text only**: disabled chrome and inactive marks.
    ///
    /// 2.32:1 on `ground`. An instrument is read in bad light and at arm's
    /// length, so nothing a user has to read may ever be set in this.
    static let inkDim = Color(hexRGB: 0x5C6370)
    /// `#61AFEF` selection, primary action, focus ring. The only accent.
    static let accent = Color(hexRGB: 0x61AFEF)
    /// `#528BFF` terminal cursor.
    static let cursor = Color(hexRGB: 0x528BFF)
    /// `#98C379` connected, success.
    static let ok = Color(hexRGB: 0x98C379)
    /// `#E5C07B` reconnecting, degraded.
    static let warn = Color(hexRGB: 0xE5C07B)
    /// `#E06C75` error and destructive *marks*: status squares, rules, strokes.
    ///
    /// 4.38:1 on `ground` and so below the body floor: it may be a mark, but it
    /// may not be a sentence. Error text uses `alertText`.
    static let alert = Color(hexRGB: 0xE06C75)
    /// `#EC9098` error text. 6.01:1 on `ground`, 6.60:1 on `panel`.
    static let alertText = Color(hexRGB: 0xEC9098)

    // MARK: Terminal palette (One Dark Pro, exact)

    /// The 16 ANSI colours as packed 0xRRGGBB, indices 0...7 normal and
    /// 8...15 bright. Provided as integers as well as `Color` so the terminal
    /// layer can hand them to SwiftTerm without importing SwiftUI colours.
    static let ansiHexRGB: [UInt32] = [
        // normal: black red green yellow blue magenta cyan white
        0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
        // bright
        0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
    ]

    /// Same 16 colours as SwiftUI values.
    static let ansi: [Color] = ansiHexRGB.map { Color(hexRGB: $0) }

    static let terminalForegroundHexRGB: UInt32 = 0xABB2BF
    static let terminalBackgroundHexRGB: UInt32 = 0x282C34
    static let terminalCursorHexRGB: UInt32 = 0x528BFF
    static let terminalSelectionHexRGB: UInt32 = 0x3E4451

    static let terminalForeground = Color(hexRGB: terminalForegroundHexRGB)
    static let terminalBackground = Color(hexRGB: terminalBackgroundHexRGB)
    static let terminalCursor = Color(hexRGB: terminalCursorHexRGB)
    static let terminalSelection = Color(hexRGB: terminalSelectionHexRGB)

    /// 8-bit components of a packed colour, for APIs that want raw channels
    /// (SwiftTerm's `Color` takes 16-bit components: multiply by 257).
    static func components(_ hexRGB: UInt32) -> (r: UInt8, g: UInt8, b: UInt8) {
        (
            UInt8((hexRGB >> 16) & 0xFF),
            UInt8((hexRGB >> 8) & 0xFF),
            UInt8(hexRGB & 0xFF)
        )
    }

    // MARK: Structure (DESIGN.md: 4pt grid)

    enum Metric {
        /// The spacing grid. Every gap in the app is a multiple of this.
        static let grid: CGFloat = 4
        /// Horizontal page gutter.
        static let gutter: CGFloat = 16
        /// Minimum row height, so a thumb hits it while walking.
        static let rowHeight: CGFloat = 56
        /// Minimum hit target for a small control.
        static let hitTarget: CGFloat = 44
        /// Tick length in the tick scale.
        static let tick: CGFloat = 4
        /// Distance between ticks.
        static let tickSpacing: CGFloat = 16
        /// Arm length of a registration bracket.
        static let registration: CGFloat = 6
        /// The status square. Square, never a circle.
        static let statusSquare: CGFloat = 6
        /// The only radius this world allows.
        static let corner: CGFloat = 4
    }

    // MARK: Motion (DESIGN.md: 150-200ms, ease-out, state only)

    enum Motion {
        /// Every state change in the app uses exactly this.
        static let state = Animation.easeOut(duration: 0.18)
        /// The single authored moment, the connect transition.
        static let attach = Animation.easeOut(duration: 0.2)
    }
}

// MARK: - Colour from hex

extension Color {
    /// Packed 0xRRGGBB. Named oddly on purpose so it cannot collide with a
    /// generic `init(hex:)` someone else adds.
    init(hexRGB: UInt32) {
        self.init(
            .sRGB,
            red: Double((hexRGB >> 16) & 0xFF) / 255,
            green: Double((hexRGB >> 8) & 0xFF) / 255,
            blue: Double(hexRGB & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Type scale (DESIGN.md)
//
// One family. SF Mono for anything that is data, label, or measurement, which
// here is almost everything. SF Pro Text only for sentences a human wrote.
// `.monospacedDigit()` is applied to every face, including the prose face,
// because a digit that changes width while a timer ticks breaks the illusion.

extension Font {
    /// SF Mono Medium 10, uppercase, tracked +0.8. Annotation grammar.
    static let llMicroLabel = Font.system(size: 10, weight: .medium, design: .monospaced)
        .monospacedDigit()
    /// SF Mono Regular 13. Machine values.
    static let llValue = Font.system(size: 13, weight: .regular, design: .monospaced)
        .monospacedDigit()
    /// SF Mono Medium 15. Host names, primary identifiers.
    static let llValueStrong = Font.system(size: 15, weight: .medium, design: .monospaced)
        .monospacedDigit()
    /// SF Mono Medium 20, tracked -0.2. Screen titles.
    static let llTitle = Font.system(size: 20, weight: .medium, design: .monospaced)
        .monospacedDigit()
    /// SF Pro Text 15. Sentences only, never a value.
    static let llProse = Font.system(size: 15, weight: .regular, design: .default)
        .monospacedDigit()
}

extension View {
    /// 10pt mono medium, tracked, `inkMuted` by default. Pair with
    /// `.uppercased()` on the string, or use `MicroLabel`, which does it for you.
    func llMicroLabel(_ color: Color = Theme.inkMuted) -> some View {
        font(.llMicroLabel).tracking(0.8).foregroundStyle(color)
    }

    func llValue(_ color: Color = Theme.ink) -> some View {
        font(.llValue).foregroundStyle(color)
    }

    func llValueStrong(_ color: Color = Theme.inkBright) -> some View {
        font(.llValueStrong).foregroundStyle(color)
    }

    func llTitle(_ color: Color = Theme.inkBright) -> some View {
        font(.llTitle).tracking(-0.2).foregroundStyle(color)
    }

    func llProse(_ color: Color = Theme.ink) -> some View {
        font(.llProse).foregroundStyle(color)
    }

    /// Dense measured columns cannot grow without breaking the alignment grid
    /// they exist to hold, so the numeric columns cap here while every other
    /// piece of text on the screen scales freely. Applied deliberately and only
    /// to the metadata columns.
    func llMeasuredColumn() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

// MARK: - Primitives

/// 0.5pt `rule`, edge to edge, never inset to fake a card.
///
/// Rendered at exactly one physical pixel: 0.5pt is one pixel at @2x, and at
/// @3x a literal 0.5pt would straddle one and a half pixels and blur, so the
/// height follows the display scale instead.
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale
    var color: Color = Theme.rule

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

/// A 4pt tick every 16pt along an edge, in `rule`.
///
/// The world's signature device. DESIGN.md allows at most one per screen, so
/// this is a component you place on purpose, never a background.
struct TickScale: View {
    enum Edge {
        /// Ticks run down a vertical edge, each tick pointing inward.
        case vertical
        /// Ticks run along a horizontal edge, each tick pointing downward.
        case horizontal
    }

    @Environment(\.displayScale) private var displayScale

    var edge: Edge = .vertical
    var color: Color = Theme.rule

    var body: some View {
        Canvas { context, size in
            let weight = 1 / displayScale
            let tick = Theme.Metric.tick
            let spacing = Theme.Metric.tickSpacing
            switch edge {
            case .vertical:
                var y: CGFloat = 0
                while y <= size.height {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: tick, height: weight)),
                        with: .color(color)
                    )
                    y += spacing
                }
            case .horizontal:
                var x: CGFloat = 0
                while x <= size.width {
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: weight, height: tick)),
                        with: .color(color)
                    )
                    x += spacing
                }
            }
        }
        .frame(
            width: edge == .vertical ? Theme.Metric.tick : nil,
            height: edge == .horizontal ? Theme.Metric.tick : nil
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 6pt corner brackets marking a region, in `rule`.
///
/// Exactly two, on opposite corners. Four would read as a frame, and a frame is
/// a card with the fill removed.
struct RegistrationMarks: View {
    enum Diagonal {
        case topLeadingBottomTrailing
        case topTrailingBottomLeading
    }

    @Environment(\.displayScale) private var displayScale

    var diagonal: Diagonal = .topLeadingBottomTrailing
    var color: Color = Theme.rule
    /// 0 hides the marks without changing layout, for the connect transition.
    var progress: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let weight = 1 / displayScale
            let arm = Theme.Metric.registration * max(0, min(1, progress))
            guard arm > 0 else { return }

            func bracket(atX x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat) {
                let horizontal = CGRect(
                    x: dx > 0 ? x : x - arm,
                    y: dy > 0 ? y : y - weight,
                    width: arm,
                    height: weight
                )
                let vertical = CGRect(
                    x: dx > 0 ? x : x - weight,
                    y: dy > 0 ? y : y - arm,
                    width: weight,
                    height: arm
                )
                context.fill(Path(horizontal), with: .color(color))
                context.fill(Path(vertical), with: .color(color))
            }

            switch diagonal {
            case .topLeadingBottomTrailing:
                bracket(atX: 0, y: 0, dx: 1, dy: 1)
                bracket(atX: size.width, y: size.height, dx: -1, dy: -1)
            case .topTrailingBottomLeading:
                bracket(atX: size.width, y: 0, dx: -1, dy: 1)
                bracket(atX: 0, y: size.height, dx: 1, dy: -1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A 6pt square. Never a circle: squares belong to the drawing grammar.
struct StatusSquare: View {
    enum Level {
        /// Filled `ok`.
        case connected
        /// Filled `warn`.
        case connecting
        /// Hollow `rule`.
        case offline
        /// Filled `alert`. Reserved for a host that answered with an error.
        case failed

        var color: Color {
            switch self {
            case .connected: return Theme.ok
            case .connecting: return Theme.warn
            case .offline: return Theme.rule
            case .failed: return Theme.alert
            }
        }

        var isFilled: Bool {
            if case .offline = self { return false }
            return true
        }

        var label: String {
            switch self {
            case .connected: return "reachable"
            case .connecting: return "checking"
            case .offline: return "unreachable"
            case .failed: return "error"
            }
        }
    }

    var level: Level
    var size: CGFloat = Theme.Metric.statusSquare

    var body: some View {
        // A hollow square this small needs a full point of border to read at
        // arm's length; a hairline would vanish. Everything else uses Hairline.
        Rectangle()
            .strokeBorder(level.color, lineWidth: level.isFilled ? size / 2 : 1)
            .frame(width: size, height: size)
            .animation(Theme.Motion.state, value: level.isFilled)
            .accessibilityLabel(Text(level.label))
    }
}

/// A sentence a human wrote, with backticked spans rendered in mono so a
/// machine value inside prose never sets in SF Pro. `Text(String)` does not
/// parse markdown the way `Text("literal")` does, hence the explicit parse.
func proseText(_ string: String) -> Text {
    if let attributed = try? AttributedString(markdown: string) {
        return Text(attributed)
    }
    return Text(string)
}

/// The uppercase, tracked, mono annotation label.
struct MicroLabel: View {
    private let text: String
    private var color: Color

    init(_ text: String, color: Color = Theme.inkMuted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .llMicroLabel(color)
    }
}

// MARK: - Interactive states
//
// DESIGN.md: every interactive element ships default, pressed, disabled, and
// focus. `raised` is the pressed layer, `accent` is the focus ring, and
// disabled drops to `inkDim`, which is the one place that token is allowed near
// a glyph: an inactive control is exempt from the contrast floor, and reading as
// switched off is the whole job. No shadows, no scaling, no bounce.

/// A full-bleed row that presses into the `raised` layer.
struct InstrumentRowButtonStyle: ButtonStyle {
    /// The row this screen is currently showing, in a split view where the row
    /// stays on screen beside its own content. Distinct from focus, which is a
    /// keyboard position and can sit on a row that is not the selected one.
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StatefulBody(configuration: configuration, selected: selected)
    }

    private struct StatefulBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.4)
                .background(configuration.isPressed || selected ? Theme.raised : Color.clear)
                .overlay(alignment: .leading) {
                    // Selection and focus both read as an accent rule on the
                    // leading edge, not as a glowing rounded rectangle and never
                    // as a checkmark.
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2)
                        .opacity(isFocused || selected ? 1 : 0)
                }
                .animation(Theme.Motion.state, value: configuration.isPressed)
                .animation(Theme.Motion.state, value: isFocused)
                .animation(Theme.Motion.state, value: selected)
                .contentShape(Rectangle())
        }
    }
}

/// A bordered mono control: `[ ADD HOST ]`. Primary uses the accent ink.
struct InstrumentButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary, destructive }

    var emphasis: Emphasis = .secondary

    func makeBody(configuration: Configuration) -> some View {
        StatefulBody(configuration: configuration, emphasis: emphasis)
    }

    private struct StatefulBody: View {
        let configuration: ButtonStyleConfiguration
        let emphasis: InstrumentButtonStyle.Emphasis
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        private var tint: Color {
            guard isEnabled else { return Theme.inkDim }
            switch emphasis {
            case .primary: return Theme.accent
            case .secondary: return Theme.ink
            // A button label is text, so the destructive tint is `alertText`.
            case .destructive: return Theme.alertText
            }
        }

        var body: some View {
            configuration.label
                .font(.llMicroLabel)
                .tracking(0.8)
                .foregroundStyle(tint)
                .padding(.horizontal, Theme.Metric.grid * 3)
                .frame(minHeight: 32)
                .background(configuration.isPressed ? Theme.raised : Color.clear)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            isFocused ? Theme.accent : tint.opacity(isEnabled ? 0.6 : 0.4),
                            lineWidth: isFocused ? 1 : 0.5
                        )
                }
                .animation(Theme.Motion.state, value: configuration.isPressed)
                .animation(Theme.Motion.state, value: isEnabled)
                .contentShape(Rectangle())
        }
    }
}

/// Two-state control drawn as a pair of square cells, because a capsule switch
/// is iOS chrome and this world does not use iOS chrome.
struct InstrumentToggle: View {
    let title: String
    @Binding var isOn: Bool
    /// Optional sentence under the control.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid) {
            HStack(alignment: .center, spacing: Theme.Metric.grid * 2) {
                MicroLabel(title)
                Spacer(minLength: Theme.Metric.grid * 2)
                HStack(spacing: 0) {
                    cell("OFF", active: !isOn, isPositive: false)
                    cell("ON", active: isOn, isPositive: true)
                }
                .fixedSize()
            }
            .frame(minHeight: Theme.Metric.hitTarget)
            if let note {
                // A sentence, so it sets in `ink` like every other sentence.
                // Its rank comes from position and face, never from dimming it.
                proseText(note)
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.Motion.state) { isOn.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isOn ? "on" : "off"))
        .accessibilityAddTraits(.isButton)
    }

    /// The selected cell is marked, but only the ON side gets the accent:
    /// accent means "this setting is doing something", and a blue block on OFF
    /// reads as enabled at a glance. The unselected cell is still a live target
    /// and still has to be read, so it drops to `inkMuted`, not to `inkDim`.
    private func cell(_ text: String, active: Bool, isPositive: Bool) -> some View {
        Text(text)
            .llMicroLabel(active ? (isPositive ? Theme.ground : Theme.inkBright) : Theme.inkMuted)
            .frame(width: 40, height: 26)
            .background(active ? (isPositive ? Theme.accent : Theme.raised) : Color.clear)
            .overlay {
                Rectangle().strokeBorder(Theme.rule, lineWidth: 0.5)
            }
            .animation(Theme.Motion.state, value: active)
    }
}

// MARK: - Navigation grammar (DESIGN.md)
//
// One back affordance, in one place: the leading cell of a header band. A
// bordered `[ ... ]` control is this world's grammar for an *action on the
// content* — SAVE, RECONNECT, + HOST — and moving between screens is not that,
// it is structure. So the control that moves you is drawn as a division of the
// band itself: a cell on the leading edge, separated from what the screen is
// about by a vertical hairline, exactly the way a plate is divided.
//
// The same cell carries the split view. In regular width the index is not
// behind the terminal, it is beside it, so the cell shows and hides the column
// rather than popping a stack, and it says so.

/// What the leading cell of a header band does on this screen.
enum HeaderLeading: Equatable {
    /// Nothing is behind this screen, and no cell is drawn. The index in
    /// compact width, and the sidebar in regular width.
    case root
    /// Compact width: pop to the screen behind this one.
    case back
    /// The root of a sheet. Nothing is behind it, so it does not point
    /// anywhere: it simply stops.
    case close
    /// Regular width: the index column, and whether it is currently showing.
    case index(showing: Bool)

    /// The cell's label, or nil when no cell is drawn. `\u{25C0}` and
    /// `\u{25B6}` are the marks, never an SF Symbol chevron: this world draws
    /// its marks as glyphs on the mono grid.
    var label: String? {
        switch self {
        case .root: return nil
        case .back: return "\u{25C0} BACK"
        case .close: return "CLOSE"
        // The mark points the way the press moves things: showing collapses the
        // column leftward, hidden pushes the content rightward to reveal it.
        case .index(let showing): return showing ? "\u{25C0} INDEX" : "\u{25B6} INDEX"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .root: return ""
        case .back: return "back"
        case .close: return "close"
        case .index(let showing): return showing ? "hide the index" : "show the index"
        }
    }
}

/// The header band's leading cell. Full band height, hairline-divided,
/// `inkMuted` going to `inkBright` on a press that also lifts the cell to
/// `raised`.
struct HeaderLeadingCell: View {
    let kind: HeaderLeading
    let action: () -> Void

    var body: some View {
        if let label = kind.label {
            Button(action: action) {
                Text(label)
                    .font(.llMicroLabel)
                    .tracking(0.8)
                    .lineLimit(1)
                    // Fixed furniture: the cell may not reflow, or the band's
                    // leading edge stops lining up with the gutter below it.
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .padding(.horizontal, Theme.Metric.grid * 3)
                    .frame(minWidth: Theme.Metric.hitTarget)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HeaderCellStyle())
            .accessibilityLabel(Text(kind.accessibilityLabel))
        }
    }
}

private struct HeaderCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.inkBright : Theme.inkMuted)
            .background(configuration.isPressed ? Theme.raised : Color.clear)
            .overlay(alignment: .trailing) { VerticalHairline() }
            .animation(Theme.Motion.state, value: configuration.isPressed)
    }
}

// MARK: - Field chrome

/// Micro-caps label above a field, with the field drawn on a `panel` band and
/// a hairline underneath. No grouped inset, no rounded box.
struct FieldRow<Content: View>: View {
    let label: String
    var annotation: String?
    var error: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid) {
            HStack(spacing: Theme.Metric.grid * 2) {
                MicroLabel(label)
                Spacer(minLength: 0)
                if let annotation {
                    MicroLabel(annotation)
                }
            }
            content
                .font(.llValue)
                .foregroundStyle(Theme.inkBright)
                .tint(Theme.accent)
                .frame(minHeight: 28)
            if let error {
                // `alert` is 4.38:1 and so is a mark, not a message. Both the
                // ERR annotation and the sentence are text, so both take
                // `alertText` at 6.60:1 on `panel`; it still reads as the same
                // red at a glance.
                HStack(alignment: .top, spacing: Theme.Metric.grid * 2) {
                    MicroLabel("ERR", color: Theme.alertText)
                        .padding(.top, 1)
                    proseText(error)
                        .llProse(Theme.alertText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, Theme.Metric.grid * 2)
    }
}
