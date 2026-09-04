import SwiftUI

// The settings that used to live expanded inside the host sheet, and the two
// pieces of chrome that let them move out of it: a pushed screen drawn in the
// same world as the sheet, and the summary row that stands in for it.
//
// Nothing new is invented here. The screen is the sheet's own header idiom with
// a BACK control instead of CANCEL and SAVE, and the summary row is the index's
// row: full bleed, hairline-delimited, micro-caps label, mono value.

// MARK: - Setting screen

/// One pushed setting screen: title, a micro-caps line saying what the setting
/// currently is, and the control underneath.
///
/// It is a push rather than a modal on purpose. A modal is for protected focus
/// — a decision that must be finished or abandoned — and picking a font is
/// neither. The sheet's SAVE still owns the outcome, so backing out of here
/// abandons nothing.
struct SettingScreen<Content: View>: View {
    let title: String
    /// The current value, echoing the summary row that opened this screen so
    /// the push reads as one continuous thought.
    let annotation: String
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, Theme.Metric.gutter)
            // Air under the header rule, so the first control does not sit on
            // it the way a row sits on the rule above the next row.
            .padding(.top, Theme.Metric.grid * 2)
            .padding(.bottom, Theme.Metric.grid * 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.Metric.grid * 2) {
                Text(title)
                    .llTitle()
                    .lineLimit(1)
                Spacer(minLength: Theme.Metric.grid * 2)
                Button("\u{25C0} BACK") { dismiss() }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
            }
            MicroLabel(annotation)
                .padding(.top, Theme.Metric.grid * 2)
                .llMeasuredColumn()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, Theme.Metric.grid * 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

// MARK: - Summary row

/// A setting stated rather than shown: micro-caps label, the value it currently
/// holds, and the mark that says there is a screen behind it.
struct SummaryRow: View {
    let label: String
    /// The current setting, in words. Mono, because it is a machine value.
    let value: String
    /// A second measured fact, when one value is not the whole answer (a font
    /// has a size as well as a name).
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Metric.grid * 3) {
                MicroLabel(label)
                Spacer(minLength: Theme.Metric.grid * 2)
                Text(value)
                    .llValue(Theme.inkBright)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    MicroLabel(detail).llMeasuredColumn()
                }
                // Not a chevron image: an SF Symbol chevron is iOS chrome, and
                // this world draws its marks as glyphs on the mono grid.
                Text("\u{203A}")
                    .llValueStrong(Theme.inkMuted)
            }
            .frame(minHeight: Theme.Metric.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(InstrumentRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(detail.map { "\(value), \($0)" } ?? value))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Palette

/// The terminal palette for one host. One row per scheme, each its own
/// specimen: the scheme's name and a strip of the sixteen ANSI colours it
/// actually paints, drawn on its actual ground.
///
/// The list is nine schemes plus the follow-the-system rule, which is long
/// enough that the sentence explaining a scheme cannot live on every row: ten
/// paragraphs is a wall, not a list. So the row is name plus specimen, one line
/// tall and scannable down the left edge, and the sentence belongs to whichever
/// scheme is currently selected, stated once under the header where the
/// annotation already names it.
///
/// Note what this screen does *not* do: it does not restyle itself. DESIGN.md's
/// chrome tokens carry a contrast floor measured against the One Dark Pro
/// ground, so the app stays One Dark Pro and only the terminal is themed. A
/// scheme appears here as a specimen, never as the surface it is printed on.
struct HostPaletteView: View {
    @Binding var host: Host

    /// The phone's real light/dark setting, so the `MATCH SYSTEM` row can show
    /// the strip it would actually paint right now rather than a guess.
    private let systemIsLight = SystemAppearance.isLight

    var body: some View {
        SettingScreen(title: "PALETTE", annotation: host.colorScheme.displayName) {
            proseText(host.colorScheme.summary)
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Theme.Metric.grid * 3)
            VStack(spacing: 0) {
                ForEach(Array(TerminalColorScheme.allCases.enumerated()), id: \.element.id) { index, scheme in
                    if index > 0 { Hairline() }
                    row(scheme)
                }
            }
        }
    }

    private func row(_ scheme: TerminalColorScheme) -> some View {
        let isSelected = host.colorScheme == scheme
        return Button {
            withAnimation(Theme.Motion.state) { host.colorScheme = scheme }
        } label: {
            HStack(spacing: Theme.Metric.grid * 3) {
                // Selection is a filled accent square, matching the status
                // grammar. Never a checkmark, never a radio.
                Rectangle()
                    .fill(isSelected ? Theme.accent : Color.clear)
                    .frame(width: Theme.Metric.statusSquare, height: Theme.Metric.statusSquare)
                    .overlay { Rectangle().strokeBorder(Theme.rule, lineWidth: 1) }
                Text(scheme.displayName)
                    .llValue(isSelected ? Theme.inkBright : Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: Theme.Metric.grid * 2)
                specimen(scheme)
            }
            .frame(minHeight: Theme.Metric.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(InstrumentRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(scheme.displayName + (scheme.isLight ? ", light ground" : "")))
        .accessibilityValue(Text(scheme.summary))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The palette shown as itself: sixteen ANSI colours as two contiguous runs
    /// of eight, normal above bright, printed on the scheme's own background so
    /// the ground is part of the specimen. A colour bar off a test chart, not a
    /// row of dots.
    private func specimen(_ scheme: TerminalColorScheme) -> some View {
        let palette = TerminalPalette.resolve(scheme: scheme, systemIsLight: systemIsLight)
        return VStack(spacing: 0) {
            run(palette.ansiHexRGB[0..<8])
            run(palette.ansiHexRGB[8..<16])
        }
        .padding(Self.specimenInset)
        .background(Color(hexRGB: palette.backgroundHexRGB))
        .overlay { Rectangle().strokeBorder(Theme.rule, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    private func run(_ colors: ArraySlice<UInt32>) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, hex in
                Rectangle()
                    .fill(Color(hexRGB: hex))
                    .frame(width: Self.patch.width, height: Self.patch.height)
            }
        }
    }

    /// One ANSI patch. Wide enough to read as a colour rather than a speck,
    /// narrow enough that sixteen of them plus the longest scheme name still
    /// fit the smallest phone this app supports.
    private static let patch = CGSize(width: 9, height: 7)
    private static let specimenInset: CGFloat = 2
}

// MARK: - Security

/// What guards one host: the phone's own biometric prompt, and the secret the
/// daemon may ask for.
struct HostSecurityView: View {
    @Binding var host: Host
    /// The typed secret. Empty and edited means "clear the stored one".
    @Binding var secret: String
    @Binding var secretEdited: Bool
    /// Whether the Keychain already holds one for this host, read by the sheet.
    let storedSecret: Bool

    @FocusState private var focused: Bool

    var body: some View {
        SettingScreen(title: "SECURITY", annotation: summary) {
            InstrumentToggle(
                title: "FACE ID",
                isOn: $host.requireFaceID,
                note: "Asks the phone before opening this host. Convenience, not the real gate."
            )
            .padding(.vertical, Theme.Metric.grid * 2)
            Hairline()
            FieldRow(label: "UNLOCK SECRET",
                     annotation: storedSecret && !secretEdited ? "KEYCHAIN / STORED" : "KEYCHAIN") {
                SecureField("", text: $secret, prompt: Text("•••••••••").foregroundColor(Theme.inkMuted))
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: secret) { secretEdited = true }
            }
            // Kept: this is a claim about where a secret goes, and a claim
            // about a secret has to be written down rather than implied.
            proseText("Stored in the Keychain on this phone and sent only when the daemon asks for it.")
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if host.requireFaceID { parts.append("FACE ID") }
        if secretEdited ? !secret.isEmpty : storedSecret { parts.append("SECRET") }
        return parts.isEmpty ? "OPEN" : parts.joined(separator: " / ")
    }
}
