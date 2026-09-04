import SwiftUI
// For `Font(_: UIFont)`: the font picker sets each family name in the exact
// face the terminal would compose for it, which is a UIFont.
import UIKit

/// The face and size one host renders at.
///
/// Its own screen because a font is the one setting whose value is its own
/// specimen: the rows are set in the families they name, the plate at the
/// bottom draws the chosen face at the exact size the terminal will, and none
/// of that is worth carrying on the sheet where a machine gets added.
struct HostFontView: View {
    @Binding var host: Host

    /// Debug screenshot hooks, the same idiom as `DemoSeed`: put a name in the
    /// manual field, and fire one real `CTFontManagerRequestFonts` for a name
    /// nothing can resolve, so the failure path can be looked at rather than
    /// reasoned about.
    var demoPrefill = false
    var autoRequest = false

    /// Filled once, off the main body: enumerating installed families measures
    /// glyph advances across every font on the phone.
    @State private var fontOptions: [TerminalFont.Option] = []
    /// The escape hatch: a family name typed by hand, because a font a provider
    /// app installed cannot be enumerated and therefore cannot be offered.
    @State private var typedFamily: String = ""
    @State private var requestInFlight = false
    /// What the last request attempt did, phrased as a sentence.
    @State private var requestNote: RequestNote?
    @FocusState private var focused: Bool

    /// One outcome of a `CTFontManagerRequestFonts` round trip, in words.
    private struct RequestNote: Equatable {
        let label: String
        let text: String
        let isError: Bool
    }

    var body: some View {
        SettingScreen(title: "TERMINAL FONT", annotation: annotation) {
            VStack(spacing: 0) {
                ForEach(Array(fontOptions.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Hairline() }
                    fontRow(option)
                }
            }
            // The one line that has to be here: it is what every row's
            // annotation is measured against, and without it "ICONS FROM
            // BUNDLED" reads as a warning rather than as the arrangement
            // working.
            proseText("Anything your font is missing, the Private Use Area icons a prompt draws included, is drawn from the bundled face.")
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Theme.Metric.grid * 2)
            Hairline()
            sizeControl
            Hairline()
            specimen
            Hairline()
            manualEntry
        }
        // Enumerating every installed family measures glyph advances, which is
        // far too much work to redo on every body evaluation.
        .task {
            refreshFontOptions()
            if demoPrefill, typedFamily.isEmpty { typedFamily = "Menlo" }
            if autoRequest { request(name: typedFamily) }
        }
    }

    /// The header line: what this host renders in, at what size.
    private var annotation: String {
        let name = host.fontFamily.isEmpty ? TerminalFont.bundledDisplayName : host.fontFamily
        return "\(name) / \(Int(resolvedSize)) PT"
    }

    private func refreshFontOptions() {
        fontOptions = TerminalFont.options(selected: host.fontFamily)
    }

    // MARK: - Rows
    //
    // Micro-caps annotation, hairline-separated rows, a filled accent square for
    // the selection — the palette screen's idiom. The one thing this picker does
    // that the palette one does not is set each family name *in that family*,
    // because reading a family name set in that family is the whole answer.

    private func fontRow(_ option: TerminalFont.Option) -> some View {
        let isSelected = host.fontFamily == option.family
        return Button {
            // A family iOS has not made available yet cannot be selected —
            // there is nothing to select. Tapping it asks for it instead, which
            // is the only action that can change the answer.
            if option.needsAccess {
                request(name: option.family)
            } else {
                withAnimation(Theme.Motion.state) { host.fontFamily = option.family }
            }
        } label: {
            HStack(alignment: .top, spacing: Theme.Metric.grid * 3) {
                Rectangle()
                    .fill(isSelected ? Theme.accent : Color.clear)
                    .frame(width: Theme.Metric.statusSquare, height: Theme.Metric.statusSquare)
                    .overlay { Rectangle().strokeBorder(Theme.rule, lineWidth: 1) }
                    .padding(.top, Theme.Metric.grid + 3)
                VStack(alignment: .leading, spacing: Theme.Metric.grid) {
                    Text(option.displayName)
                        // The name is its own specimen, set in the exact font
                        // the terminal would compose for this row. A family
                        // that is not installed has no specimen to show, so it
                        // falls back to the app's own face.
                        .font(option.isResolved
                              ? Font(TerminalFont.font(family: option.family, size: 15, bold: false))
                              : .llValueStrong)
                        .foregroundStyle(isSelected ? Theme.inkBright : Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MicroLabel(fontAnnotation(option), color: fontAnnotationColor(option))
                }
                Spacer(minLength: 0)
                if option.isResolved {
                    promptIconSpecimen(option)
                }
            }
            .padding(.vertical, Theme.Metric.grid * 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(InstrumentRowButtonStyle())
    }

    /// One measured fact per row, never a guess: the codepoints were actually
    /// looked up in the font.
    private func fontAnnotation(_ option: TerminalFont.Option) -> String {
        if option.isMissing { return "NOT INSTALLED / FALLS BACK TO BUNDLED" }
        if option.needsAccess { return "NEEDS ACCESS / TAP TO REQUEST" }
        if option.isBundled { return "DEFAULT / FULL PROMPT ICONS" }
        return option.hasPromptIcons ? "FULL PROMPT ICONS" : "ICONS FROM BUNDLED"
    }

    private func fontAnnotationColor(_ option: TerminalFont.Option) -> Color {
        if option.isMissing { return Theme.alertText }
        if option.needsAccess { return Theme.warn }
        return Theme.inkMuted
    }

    /// The three codepoints the annotation is measured from, drawn in the face
    /// the terminal would actually compose for this row — so a font missing
    /// them shows the bundled glyphs standing in, exactly as the terminal will.
    private func promptIconSpecimen(_ option: TerminalFont.Option) -> some View {
        Text(String(String.UnicodeScalarView(TerminalFont.promptIconCodepoints)))
            .font(Font(TerminalFont.font(family: option.family, size: 15, bold: false)))
            .foregroundStyle(Theme.inkMuted)
            .padding(.top, Theme.Metric.grid)
            .accessibilityHidden(true)
    }

    // MARK: - Size
    //
    // The pinch gesture in the terminal has always been able to change this;
    // there was simply nowhere to read or set it, which made it a setting only
    // someone who already knew about it could find. Drawn as a bordered mono
    // stepper rather than a `Stepper`, whose iOS chrome is a grey rounded
    // segmented capsule this world does not own.

    private var sizeControl: some View {
        HStack(spacing: Theme.Metric.grid * 2) {
            MicroLabel("SIZE")
            MicroLabel("\(Int(TerminalFont.minSize))-\(Int(TerminalFont.maxSize))")
                .llMeasuredColumn()
            Spacer(minLength: Theme.Metric.grid * 2)
            stepButton("−", to: resolvedSize - 1, label: "smaller")
            // Tabular by construction (SF Mono), and fixed width so the row
            // does not shift when 9 becomes 10.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.grid) {
                Text("\(Int(resolvedSize))")
                    .llValueStrong()
                    .frame(minWidth: 22, alignment: .trailing)
                MicroLabel("PT")
            }
            .llMeasuredColumn()
            stepButton("+", to: resolvedSize + 1, label: "larger")
        }
        .frame(minHeight: Theme.Metric.rowHeight)
        .accessibilityElement(children: .contain)
    }

    /// What this host actually renders at: its own size, or the app-wide
    /// default when it has never been given one.
    private var resolvedSize: CGFloat {
        TerminalFont.size(forHost: host.fontSize)
    }

    private func stepButton(_ glyph: String, to newValue: CGFloat, label: String) -> some View {
        Button(glyph) {
            withAnimation(Theme.Motion.state) { host.fontSize = Double(newValue) }
        }
        .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
        .disabled(newValue < TerminalFont.minSize || newValue > TerminalFont.maxSize)
        .accessibilityLabel(Text(label))
    }

    // MARK: - Specimen
    //
    // The one setting whose value is its own specimen. It renders the family
    // name and the three prompt codepoints the annotations are measured from, in
    // the exact font and at the exact size the terminal will compose — so a
    // font that was just granted access proves itself here immediately, and the
    // Nerd Font fallback firing behind an unpatched face is visible rather than
    // promised.

    private var specimen: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            HStack(spacing: Theme.Metric.grid * 2) {
                MicroLabel("SPECIMEN")
                Spacer(minLength: 0)
                MicroLabel("\(Int(resolvedSize)) PT").llMeasuredColumn()
            }
            Text(specimenText)
                .font(Font(TerminalFont.font(family: specimenFamily,
                                             size: resolvedSize,
                                             bold: false)))
                .foregroundStyle(Theme.inkBright)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Metric.grid * 3)
                // Room for the 6pt brackets, so one never lands on a glyph.
                .padding(.horizontal, Theme.Metric.grid * 3)
                .background(Theme.ground)
                // Two brackets on one diagonal: this is a plate showing what the
                // terminal will draw, so it is marked the way the terminal
                // viewport is.
                .overlay { RegistrationMarks(diagonal: .topLeadingBottomTrailing) }
                .accessibilityLabel(Text("specimen of \(specimenFamily.isEmpty ? TerminalFont.bundledDisplayName : specimenFamily)"))
        }
        .padding(.vertical, Theme.Metric.grid * 3)
    }

    /// The chosen family, unless it is not currently drawable, in which case the
    /// specimen honestly shows the bundled face the terminal would fall back to.
    private var specimenFamily: String {
        TerminalFont.isInstalled(family: host.fontFamily) ? host.fontFamily : ""
    }

    private var specimenText: String {
        let name = host.fontFamily.isEmpty ? TerminalFont.bundledDisplayName : host.fontFamily
        let icons = String(String.UnicodeScalarView(TerminalFont.promptIconCodepoints))
        return "\(name)  \(icons)"
    }

    // MARK: - Manual entry
    //
    // The escape hatch, and on a phone with a provider-installed font the only
    // thing that can work. CoreText will not let this app enumerate a font that
    // iFont (or any other font provider) installed — see `TerminalFont` — so the
    // name has to come from the user, and `CTFontManagerRequestFonts` is the one
    // call that can turn a name into a usable face. iOS puts its own dialog in
    // front of that, which is why this is a deliberate button and not something
    // the picker does on its own.

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            FieldRow(label: "FONT NOT LISTED", annotation: "FAMILY NAME") {
                HStack(spacing: Theme.Metric.grid * 3) {
                    TextField("", text: $typedFamily,
                              prompt: Text("Family name").foregroundColor(Theme.inkMuted))
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { request(name: typedFamily) }
                    Button(requestInFlight ? "ASKING" : "REQUEST") { request(name: typedFamily) }
                        .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                        .disabled(requestInFlight
                                  || typedFamily.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let note = requestNote {
                HStack(alignment: .top, spacing: Theme.Metric.grid * 2) {
                    MicroLabel(note.label, color: note.isError ? Theme.alertText : Theme.ok)
                        .padding(.top, 1)
                    proseText(note.text)
                        .llProse(note.isError ? Theme.alertText : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            } else {
                // Kept, shortened: a font app's name has to be copied exactly,
                // and nothing on screen would otherwise say so.
                proseText("A font an app installed is invisible here until this app asks for it by name. Type the family name exactly as the font app shows it.")
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One `CTFontManagerRequestFonts` round trip, reported plainly either way.
    private func request(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !requestInFlight else { return }
        requestInFlight = true
        focused = false
        TerminalFont.requestAccess(name: trimmed) { outcome in
            requestInFlight = false
            withAnimation(Theme.Motion.state) {
                if let family = outcome.resolvedFamily {
                    host.fontFamily = family
                    typedFamily = ""
                    requestNote = RequestNote(
                        label: "OK",
                        text: "`\(family)` is available and now set as this host's face. The specimen above is drawn in it.",
                        isError: false
                    )
                } else {
                    requestNote = RequestNote(
                        label: "ERR",
                        text: "iOS could not resolve `\(trimmed)`. Open the app you installed the font with and copy the family name exactly as it appears there, capitals and spaces included.",
                        isError: true
                    )
                }
                refreshFontOptions()
            }
        }
    }
}
