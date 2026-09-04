import SwiftUI
import QuartzCore

/// The keys a shell needs that a phone keyboard does not have, drawn as an
/// instrument keypad rather than as iOS buttons: mono micro-caps labels, 0.5pt
/// hairline separators, square corners, no fills except the pressed and latched
/// layers, no shadows.
///
/// What is in the row is an app-wide setting (`SettingsStore`), so this view
/// renders whatever list it is handed and owns none of it.
///
/// Three keys latch rather than send. While one is armed, `TerminalScreen`
/// intercepts the next key — from this bar or from the software keyboard — and
/// folds it (`k & 0x1f` for Ctrl, an `ESC` prefix for Alt, the host's tmux
/// prefix byte in front for Leader), then unlatches.
struct KeyBar: View {
    /// The row, already resolved to labels and bytes.
    let keys: [ResolvedKey]

    @Binding var ctrlLatched: Bool
    @Binding var altLatched: Bool
    @Binding var leaderLatched: Bool

    /// The byte this host's tmux prefix resolves to, or nil when the stored
    /// notation does not parse. Nil disables the LDR key and every key whose
    /// sequence names the leader with `\L`: a key that sends nothing has to look
    /// switched off rather than armed.
    var leaderByte: UInt8?

    /// Bytes for a key that sends immediately. Routed through the same input
    /// path as the software keyboard so the latched modifiers apply to these
    /// too. nil makes the whole bar a specimen: it draws, it does not act, and
    /// it does not scroll under a finger that is trying to scroll the page.
    var send: (([UInt8]) -> Void)?

    @Environment(\.displayScale) private var displayScale

    /// Keys look small; the touch target never is. 44pt is the floor in both
    /// directions — the bar spends its whole height on it, and a cell never
    /// narrows past it. When the row will not fit at 44pt it scrolls, because
    /// shrinking a key under the thumb minimum is the one thing this bar may
    /// not do (DESIGN.md components; Apple's 44pt).
    private static let height: CGFloat = Theme.Metric.hitTarget
    private static let minKeyWidth: CGFloat = Theme.Metric.hitTarget
    /// And a ceiling, for the iPad.
    ///
    /// The bar is a keypad, and a keypad's cells are the size of the thing that
    /// presses them. Spreading thirteen keys evenly across a 1000pt pane makes
    /// each one a 77pt slab holding three glyphs, which stops reading as keys
    /// and starts reading as a toolbar with the labels lost in the middle of it.
    /// Twice the touch minimum is the widest a cell can be and still look like a
    /// key. Past that the row keeps its size and sits against the leading edge,
    /// where the thumb of a hand holding the left side of an iPad already is.
    private static let maxKeyWidth: CGFloat = Theme.Metric.hitTarget * 2

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            GeometryReader { proxy in
                let width = keyWidth(available: proxy.size.width)
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                            if index > 0 { separator }
                            cell(key).frame(width: width)
                        }
                        // The bar has hit its ceiling and there is sheet left
                        // over, so the cell rhythm carries on across it as empty
                        // slots. Exactly what the index does below its last host
                        // and for the same reason: a ledger does not stop ruling
                        // when the entries run out, and a row that simply stops
                        // two thirds of the way across reads as a phone layout
                        // that was stretched and gave up.
                        ForEach(Array(0..<emptySlots(available: proxy.size.width, width: width)),
                                id: \.self) { _ in
                            separator
                            Color.clear.frame(width: width)
                        }
                    }
                    .frame(height: Self.height)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                // No rubber band when the row already fits, so the bar reads as
                // fixed furniture until it genuinely has more keys than screen.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollDisabled(send == nil)
            }
            .frame(height: Self.height)
            // A specimen is drawn, not operated. `allowsHitTesting` rather than
            // `.disabled`, which would grey every label to `inkDim` and make the
            // settings screen's preview look like a switched-off bar rather than
            // like the bar.
            .allowsHitTesting(send != nil)
        }
        .background(Theme.panel)
        // The bar is fixed furniture; its labels cannot reflow or the keys stop
        // lining up with the grid they are drawn on.
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// Fill the width evenly while the row fits; stop at the touch minimum and
    /// let it scroll once it does not; stop again at the key ceiling so a wide
    /// pane does not turn the keypad into a toolbar.
    private func keyWidth(available: CGFloat) -> CGFloat {
        min(Self.maxKeyWidth, unclampedWidth(available: available))
    }

    /// The even share, floored at the touch minimum but not capped. Kept apart
    /// so the bar can tell "the row is filling the width" from "the row has hit
    /// its ceiling and there is sheet left over".
    private func unclampedWidth(available: CGFloat) -> CGFloat {
        guard !keys.isEmpty, available > 0 else { return Self.minKeyWidth }
        let separators = CGFloat(keys.count - 1) / displayScale
        let even = (available - separators) / CGFloat(keys.count)
        return max(Self.minKeyWidth, even.rounded(.down))
    }

    /// How many empty cells the ruling carries on for once the keys have hit
    /// their ceiling. Zero whenever the row already fills the width, which is
    /// every phone and most iPad panes, so this costs nothing there.
    private func emptySlots(available: CGFloat, width: CGFloat) -> Int {
        guard !keys.isEmpty, available > 0 else { return 0 }
        let pitch = width + 1 / displayScale
        let used = CGFloat(keys.count) * width + CGFloat(keys.count - 1) / displayScale
        let spare = available - used
        guard spare > pitch else { return 0 }
        return Int(spare / pitch)
    }

    private var separator: some View {
        VerticalHairline()
            .padding(.vertical, Theme.Metric.grid * 2)
    }

    @ViewBuilder
    private func cell(_ key: ResolvedKey) -> some View {
        switch key.action {
        case .send(let template):
            sendKey(key, template: template)
        case .latchCtrl:
            latch(key, isOn: $ctrlLatched)
        case .latchAlt:
            latch(key, isOn: $altLatched)
        case .latchLeader:
            latch(key, isOn: $leaderLatched, enabled: leaderByte != nil)
        }
    }

    /// The bytes are worked out here rather than when the layout was read,
    /// because a sequence written with `\L` only means something once the host
    /// is known. A key that needs this host's leader and cannot get one is
    /// disabled and sends nothing, the same treatment `LDR` gets, rather than
    /// falling back to tmux's default prefix and typing into a live shell.
    @ViewBuilder
    private func sendKey(_ key: ResolvedKey, template: KeySequence.Template) -> some View {
        let bytes = template.resolve(leaderByte: leaderByte)
        let label = Text(bytes == nil
                         ? "\(key.accessibility), unavailable, this host has no leader"
                         : key.accessibility)
        if key.repeats, let bytes, !bytes.isEmpty, let send {
            RepeatingKeyCell(key: key, bytes: bytes, send: send)
                .accessibilityLabel(label)
        } else {
            Button {
                if let bytes, !bytes.isEmpty { send?(bytes) }
            } label: {
                Text(key.label)
            }
            .buttonStyle(KeyCellStyle(latched: false))
            .disabled(bytes == nil)
            .accessibilityLabel(label)
        }
    }

    /// Ctrl, Alt and Leader latch independently, because `C-a C-o` is a real
    /// tmux binding and Ctrl+Alt is a real combination. Tapping an armed latch
    /// disarms it, so there is always a way out of a wrong one.
    private func latch(_ key: ResolvedKey, isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(key.label)
        }
        .buttonStyle(KeyCellStyle(latched: isOn.wrappedValue))
        // The one genuinely disabled state: a host whose stored leader notation
        // does not resolve has no prefix byte, so LDR has to read as switched
        // off rather than as armable.
        .disabled(!enabled)
        .accessibilityLabel(Text(key.accessibility))
        .accessibilityValue(Text(isOn.wrappedValue ? "armed" : "off"))
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }
}

// MARK: - Press and hold

/// A key that repeats while it is held.
///
/// The tap path is unchanged: the button's own action still fires on lift, so a
/// quick tap sends exactly one key and VoiceOver activation still works. The
/// hold path rides the button's press state, which is what already knows that a
/// thumb sliding off the cell is no longer a press.
private struct RepeatingKeyCell: View {
    let key: ResolvedKey
    let bytes: [UInt8]
    let send: ([UInt8]) -> Void

    /// A reference type in `@State` on purpose: it is a clock, not a value the
    /// body reads, so it must survive a re-render without causing one.
    @State private var driver = KeyRepeatDriver()

    var body: some View {
        Button {
            // A hold has already sent everything this key owes. The action still
            // fires on lift, so without this every hold would end with one extra
            // keystroke.
            if !driver.didRepeat { send(bytes) }
        } label: {
            Text(key.label)
        }
        .buttonStyle(KeyCellStyle(latched: false) { pressed in
            if pressed {
                driver.press { send(bytes) }
            } else {
                driver.release()
            }
        })
    }
}

/// Runs `KeyRepeatState` against a real clock and fires the key.
///
/// One coarse tick that asks the state machine how many repeats are owed, rather
/// than a timer rescheduled at every new interval: the acceleration then costs
/// nothing, and a tick that arrives late pays back what it missed instead of
/// letting the whole hold drift slower. `.common` mode so a scroll elsewhere on
/// screen cannot starve a held key.
private final class KeyRepeatDriver {
    private var state = KeyRepeatState()
    private var timer: Timer?

    var didRepeat: Bool { state.didRepeat }

    func press(_ fire: @escaping () -> Void) {
        stop()
        state.press(now: CACurrentMediaTime())
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let due = self.state.due(now: CACurrentMediaTime())
            for _ in 0..<due { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The finger came up, or left the cell. `state.release()` keeps the repeat
    /// count so the button's action can still tell a tap from a hold.
    func release() {
        state.release()
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

/// Default, pressed, latched, latched-and-pressed, and disabled for one key
/// cell. The latched state is the one that has to read at a glance in a dark
/// room: the cell inverts to the accent and the label goes to the ground
/// colour. Pressing a cell that is already latched inverts *back*, so the tap
/// that disarms a wrong modifier gives feedback instead of looking inert.
private struct KeyCellStyle: ButtonStyle {
    var latched: Bool
    /// Told when the press starts and when it stops, which for a repeating key
    /// is the whole hold. SwiftUI already treats a thumb sliding off the cell as
    /// the end of the press, which is exactly the rule a repeat needs.
    var onPressChange: ((Bool) -> Void)?

    init(latched: Bool, onPressChange: ((Bool) -> Void)? = nil) {
        self.latched = latched
        self.onPressChange = onPressChange
    }

    func makeBody(configuration: Configuration) -> some View {
        StatefulBody(configuration: configuration, latched: latched, onPressChange: onPressChange)
    }

    private struct StatefulBody: View {
        let configuration: ButtonStyleConfiguration
        let latched: Bool
        let onPressChange: ((Bool) -> Void)?
        @Environment(\.isEnabled) private var isEnabled

        private var foreground: Color {
            if !isEnabled { return Theme.inkDim }
            if latched { return configuration.isPressed ? Theme.accent : Theme.ground }
            return configuration.isPressed ? Theme.inkBright : Theme.ink
        }

        private var background: Color {
            if latched { return configuration.isPressed ? Theme.raised : Theme.accent }
            return configuration.isPressed ? Theme.raised : Color.clear
        }

        var body: some View {
            configuration.label
                .font(.llMicroLabel)
                .tracking(0.8)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
                .contentShape(Rectangle())
                .animation(Theme.Motion.state, value: latched)
                .onChange(of: configuration.isPressed) { _, pressed in
                    onPressChange?(pressed)
                }
        }
    }
}

// MARK: - Vertical hairline

/// `Hairline` turned on its side, for separating keys within a row. Same 0.5pt
/// `rule`, same one-physical-pixel treatment.
struct VerticalHairline: View {
    @Environment(\.displayScale) private var displayScale
    var color: Color = Theme.rule

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1 / displayScale)
            .accessibilityHidden(true)
    }
}
