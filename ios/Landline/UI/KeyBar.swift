import SwiftUI

/// The keys a shell needs that a phone keyboard does not have, drawn as an
/// instrument keypad rather than as iOS buttons: mono micro-caps labels, 0.5pt
/// hairline separators, square corners, no fills except the pressed and latched
/// layers, no shadows.
///
/// Ctrl and Alt latch rather than send. While one is armed, `TerminalScreen`
/// intercepts the next key — from this bar or from the software keyboard — and
/// folds it (`k & 0x1f` for Ctrl, an `ESC` prefix for Alt), then unlatches.
struct KeyBar: View {
    @Binding var ctrlLatched: Bool
    @Binding var altLatched: Bool
    /// Bytes for a key that sends immediately. Routed through the same input
    /// path as the software keyboard so the latched modifiers apply to these too.
    var send: ([UInt8]) -> Void

    /// Keys look small; the touch target never is. 44pt is the floor, and this
    /// bar spends its whole height on it.
    private static let height: CGFloat = Theme.Metric.hitTarget

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                key("ESC", bytes: [0x1b])
                key("TAB", bytes: [0x09])

                separator

                latch("CTRL", isOn: $ctrlLatched)
                latch("ALT", isOn: $altLatched)

                separator

                // CSI A/B/C/D. Arrow glyphs, not words: these are the only
                // pictographic labels the bar allows, because every terminal
                // draws them this way.
                key("\u{2190}", bytes: [0x1b, 0x5b, 0x44], accessibility: "left arrow")
                key("\u{2193}", bytes: [0x1b, 0x5b, 0x42], accessibility: "down arrow")
                key("\u{2191}", bytes: [0x1b, 0x5b, 0x41], accessibility: "up arrow")
                key("\u{2192}", bytes: [0x1b, 0x5b, 0x43], accessibility: "right arrow")

                separator

                key("~", bytes: [0x7e], accessibility: "tilde")
                key("|", bytes: [0x7c], accessibility: "pipe")
                key("/", bytes: [0x2f], accessibility: "slash")
                key("-", bytes: [0x2d], accessibility: "hyphen")
            }
            .frame(height: Self.height)
        }
        .background(Theme.panel)
        // The bar is fixed furniture; its labels cannot reflow or the keys stop
        // lining up with the grid they are drawn on.
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var separator: some View {
        VerticalHairline()
            .padding(.vertical, Theme.Metric.grid * 2)
    }

    private func key(_ label: String, bytes: [UInt8], accessibility: String? = nil) -> some View {
        Button {
            send(bytes)
        } label: {
            Text(label)
        }
        .buttonStyle(KeyCellStyle(latched: false))
        .accessibilityLabel(Text(accessibility ?? label.lowercased()))
    }

    /// Ctrl and Alt latch independently, because Ctrl+Alt is a real combination.
    private func latch(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
        }
        .buttonStyle(KeyCellStyle(latched: isOn.wrappedValue))
        .accessibilityLabel(Text(label.lowercased()))
        .accessibilityValue(Text(isOn.wrappedValue ? "armed" : "off"))
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }
}

/// Default, pressed, latched, and disabled for one key cell. The latched state
/// is the one that has to read at a glance in a dark room: the cell inverts to
/// the accent and the label goes to the ground colour.
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
            if latched { return Theme.ground }
            return configuration.isPressed ? Theme.inkBright : Theme.ink
        }

        private var background: Color {
            if latched { return Theme.accent }
            return configuration.isPressed ? Theme.raised : Color.clear
        }

        var body: some View {
            configuration.label
                .font(.llMicroLabel)
                .tracking(0.8)
                .foregroundStyle(foreground)
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
