import SwiftUI

/// Shell-oriented key bar rendered above the keyboard inside TerminalScreen.
/// v0 keeps it a plain HStack toolbar rather than a real inputAccessoryView.
///
/// The sticky Ctrl toggle does not send bytes itself: while it is on,
/// TerminalScreen intercepts the next typed key k in its onSend path and
/// sends k & 0x1f, then untoggles.
struct KeyBar: View {
    @Binding var ctrlSticky: Bool
    var sendBytes: ([UInt8]) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key("esc") { sendBytes([0x1b]) }
                key("tab") { sendBytes([0x09]) }

                Toggle("ctrl", isOn: $ctrlSticky)
                    .toggleStyle(.button)
                    .buttonStyle(KeyButtonStyle(highlighted: ctrlSticky))
                    .font(.system(.footnote, design: .monospaced))

                Divider().frame(height: 20)

                // Arrows: CSI A/B/C/D
                key("\u{2191}") { sendBytes([0x1b, 0x5b, 0x41]) } // up
                key("\u{2193}") { sendBytes([0x1b, 0x5b, 0x42]) } // down
                key("\u{2190}") { sendBytes([0x1b, 0x5b, 0x44]) } // left
                key("\u{2192}") { sendBytes([0x1b, 0x5b, 0x43]) } // right

                Divider().frame(height: 20)

                key("~") { sendBytes([0x7e]) }
                key("|") { sendBytes([0x7c]) }
                key("/") { sendBytes([0x2f]) }
                key("-") { sendBytes([0x2d]) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(KeyButtonStyle(highlighted: false))
            .font(.system(.footnote, design: .monospaced))
    }
}

private struct KeyButtonStyle: ButtonStyle {
    var highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlighted
                          ? Color.accentColor.opacity(0.5)
                          : Color(uiColor: .secondarySystemFill))
            )
            .opacity(configuration.isPressed ? 0.5 : 1)
            .foregroundStyle(.primary)
    }
}
