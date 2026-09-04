import SwiftUI

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
    /// notation does not parse. Nil disables the LDR key: a leader that sends
    /// nothing has to look switched off rather than armed.
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
                    }
                    .frame(height: Self.height)
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
    /// let it scroll once it does not.
    private func keyWidth(available: CGFloat) -> CGFloat {
        guard !keys.isEmpty, available > 0 else { return Self.minKeyWidth }
        let separators = CGFloat(keys.count - 1) / displayScale
        let even = (available - separators) / CGFloat(keys.count)
        return max(Self.minKeyWidth, even.rounded(.down))
    }

    private var separator: some View {
        VerticalHairline()
            .padding(.vertical, Theme.Metric.grid * 2)
    }

    @ViewBuilder
    private func cell(_ key: ResolvedKey) -> some View {
        switch key.action {
        case .send(let bytes):
            sendKey(key, bytes: bytes)
        case .latchCtrl:
            latch(key, isOn: $ctrlLatched)
        case .latchAlt:
            latch(key, isOn: $altLatched)
        case .latchLeader:
            latch(key, isOn: $leaderLatched, enabled: leaderByte != nil)
        }
    }

    private func sendKey(_ key: ResolvedKey, bytes: [UInt8]) -> some View {
        Button {
            send?(bytes)
        } label: {
            Text(key.label)
        }
        .buttonStyle(KeyCellStyle(latched: false))
        .accessibilityLabel(Text(key.accessibility))
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

/// Default, pressed, latched, latched-and-pressed, and disabled for one key
/// cell. The latched state is the one that has to read at a glance in a dark
/// room: the cell inverts to the accent and the label goes to the ground
/// colour. Pressing a cell that is already latched inverts *back*, so the tap
/// that disarms a wrong modifier gives feedback instead of looking inert.
private struct KeyCellStyle: ButtonStyle {
    var latched: Bool

    func makeBody(configuration: Configuration) -> some View {
        StatefulBody(configuration: configuration, latched: latched)
    }

    private struct StatefulBody: View {
        let configuration: ButtonStyleConfiguration
        let latched: Bool
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
