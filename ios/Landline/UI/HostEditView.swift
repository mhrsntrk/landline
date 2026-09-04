import SwiftUI
// For `Font(_: UIFont)`: the font picker sets each family name in the exact
// face the terminal would compose for it, which is a UIFont.
import UIKit

/// Add or edit one machine. Same world as the index: micro-caps labels above
/// fields, hairline separators, a `panel` sheet, and not one grouped-inset iOS
/// card anywhere.
struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State var host: Host
    /// Port is held as text so a typo can be named rather than silently
    /// clamped by UInt16 before anyone gets to see it.
    @State private var portText: String
    /// nil = the user never touched the field; "" = clear the stored secret.
    @State private var unlockSecret: String = ""
    @State private var secretEdited = false
    @State private var showValidation = false
    /// Fields the user has been in and left. An error is only worth showing
    /// once someone has had a chance to fill the field in.
    @State private var touched: Set<Field> = []
    /// Filled once, off the main body: enumerating installed families measures
    /// glyph advances across every font on the phone.
    @State private var fontOptions: [TerminalFont.Option] = []
    /// How many families each enumeration source returned, printed under the
    /// picker. When a side-loaded font does not appear, this is the only thing
    /// in the app that says which API can see it.
    @State private var fontCensus = TerminalFont.EnumerationCensus()
    /// The escape hatch: a family name typed by hand, because a font a provider
    /// app installed cannot be enumerated and therefore cannot be offered.
    @State private var typedFamily: String = ""
    @State private var requestInFlight = false
    /// What the last request attempt did, phrased as a sentence.
    @State private var requestNote: RequestNote?
    @FocusState private var focusedField: Field?

    /// One outcome of a `CTFontManagerRequestFonts` round trip, in words.
    private struct RequestNote: Equatable {
        let label: String
        let text: String
        let isError: Bool
    }

    private enum Field: Hashable { case name, hostname, port, secret, startCommand, fontName }

    let onSave: (Host, String?) -> Void

    init(host: Host, onSave: @escaping (Host, String?) -> Void) {
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        _showValidation = State(initialValue: DemoSeed.showsValidation)
        self.onSave = onSave
    }

    /// Debug screenshot hook, the same idiom as `DemoSeed`: park the sheet on
    /// the font section, since a screenshot run has no fingers to scroll with.
    /// Does nothing in a release build and nothing without the variable set.
    private static var demoSection: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LANDLINE_DEMO_SECTION"]
        #else
        return nil
        #endif
    }

    private static var demoParksOnFont: Bool {
        demoSection == "font" || demoSection == "fontrequest"
    }

    /// Debug screenshot hook: fire one real `CTFontManagerRequestFonts` for a
    /// name nothing can resolve, so the failure path can be looked at rather
    /// than reasoned about. A simulator has no provider-installed font, so this
    /// is the only side of that call it can reach.
    private static var demoRequestsFont: Bool { demoSection == "fontrequest" }

    /// Scroll anchor for the hook above.
    private enum Anchor: Hashable { case font }

    var body: some View {
        NavigationStack {
            ScrollView {
                ScrollViewReader { scroll in
                VStack(alignment: .leading, spacing: 0) {
                    section("MACHINE") {
                        FieldRow(label: "NAME", annotation: "OPTIONAL") {
                            TextField("", text: $host.name, prompt: prompt("studio"))
                                .focused($focusedField, equals: .name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Hairline()
                        FieldRow(
                            label: "HOSTNAME",
                            annotation: "TAILNET",
                            error: shouldShow(.hostname) ? error(for: "hostname") : nil
                        ) {
                            TextField("", text: $host.hostname, prompt: prompt(Host.tailnetExample))
                                .focused($focusedField, equals: .hostname)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }
                        Hairline()
                        FieldRow(
                            label: "PORT",
                            annotation: "1-65535",
                            error: shouldShow(.port) ? portError : nil
                        ) {
                            TextField("", text: $portText, prompt: prompt("443"))
                                .focused($focusedField, equals: .port)
                                .keyboardType(.numberPad)
                                .llMeasuredColumn() // a port is a measured value, not prose
                                .onChange(of: portText) { _, new in
                                    if let value = UInt16(new), Host.portRange.contains(Int(value)) {
                                        host.port = value
                                    }
                                }
                        }
                        Hairline()
                        InstrumentToggle(
                            title: "TLS",
                            isOn: $host.useTLS,
                            note: "On unless you are testing against a daemon without `tailscale serve` in front of it."
                        )
                        .padding(.vertical, Theme.Metric.grid * 2)
                    }

                    section("SESSION") {
                        FieldRow(label: "STARTUP COMMAND", annotation: "OPTIONAL") {
                            TextField("", text: $host.startCommand, prompt: prompt("tmuxon"))
                                .focused($focusedField, equals: .startCommand)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Text("Runs through your login shell interactively, so aliases and functions resolve. Leave it empty to get the machine's own default shell.")
                            .llProse()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, Theme.Metric.grid * 3)
                        Hairline()
                        palettePicker
                        Hairline()
                        fontPicker
                            .id(Anchor.font)
                    }

                    section("SECURITY") {
                        InstrumentToggle(
                            title: "FACE ID",
                            isOn: $host.requireFaceID,
                            note: "Asks the phone before opening this host. Convenience, not the real gate."
                        )
                        .padding(.vertical, Theme.Metric.grid * 2)
                        Hairline()
                        FieldRow(label: "UNLOCK SECRET", annotation: "KEYCHAIN") {
                            SecureField("", text: $unlockSecret, prompt: prompt("•••••••••"))
                                .focused($focusedField, equals: .secret)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: unlockSecret) { secretEdited = true }
                        }
                        Text("Stored in the Keychain on this phone and sent only when the daemon asks for it.")
                            .llProse()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, Theme.Metric.grid * 4)
                    }
                }
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.bottom, Theme.Metric.grid * 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
                    guard Self.demoParksOnFont else { return }
                    scroll.scrollTo(Anchor.font, anchor: .top)
                }
                }
            }
            .background(Theme.panel)
            .defaultScrollAnchor(DemoSeed.scrollsToBottom ? .bottom : .top)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focusedField) { previous, _ in
                if let previous { withAnimation(Theme.Motion.state) { _ = touched.insert(previous) } }
            }
            .safeAreaInset(edge: .top, spacing: 0) { sheetHeader }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .presentationBackground(Theme.panel)
        // Square corners: a rounded sheet is iOS chrome, and this world's
        // corners are 4pt or square.
        .presentationCornerRadius(0)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.Metric.grid * 2) {
                Text(host.name.isEmpty ? "NEW HOST" : host.name.uppercased())
                    .llTitle()
                    .lineLimit(1)
                Spacer(minLength: Theme.Metric.grid * 2)
                Button("CANCEL") { dismiss() }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                Button("SAVE") { save() }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                    .disabled(!isSaveable)
            }
            MicroLabel(host.useTLS ? "WSS / \(portText.isEmpty ? "—" : portText)" : "WS / \(portText.isEmpty ? "—" : portText)")
                .padding(.top, Theme.Metric.grid * 2)
                .llMeasuredColumn()
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, Theme.Metric.grid * 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: - Palette

    private var palettePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            MicroLabel("TERMINAL PALETTE")
                .padding(.top, Theme.Metric.grid * 3)
            VStack(spacing: 0) {
                ForEach(Array(TerminalColorScheme.allCases.enumerated()), id: \.element.id) { index, palette in
                    if index > 0 { Hairline() }
                    Button {
                        withAnimation(Theme.Motion.state) { host.colorScheme = palette }
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Metric.grid * 3) {
                            // Selection is a filled accent square, matching the
                            // status grammar. Never a checkmark, never a radio.
                            Rectangle()
                                .fill(host.colorScheme == palette ? Theme.accent : Color.clear)
                                .frame(width: Theme.Metric.statusSquare, height: Theme.Metric.statusSquare)
                                .overlay { Rectangle().strokeBorder(Theme.rule, lineWidth: 1) }
                                .padding(.top, Theme.Metric.grid + 2)
                            VStack(alignment: .leading, spacing: Theme.Metric.grid) {
                                Text(palette.displayName)
                                    .llValue(host.colorScheme == palette ? Theme.inkBright : Theme.ink)
                                proseText(palette.summary)
                                    .llProse()
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if palette == .oneDarkPro {
                                swatches
                            }
                        }
                        .padding(.vertical, Theme.Metric.grid * 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InstrumentRowButtonStyle())
                }
            }
            .padding(.bottom, Theme.Metric.grid * 2)
        }
    }

    // MARK: - Font
    //
    // Same idiom as the palette above: micro-caps label, hairline-separated
    // rows, a filled accent square for the selection. The one thing this picker
    // does that the palette one does not is set each family name *in that
    // family*, because a font is the one setting whose value is its own
    // specimen — reading "Berkeley Mono" in Berkeley Mono is the whole answer.

    private var fontPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            MicroLabel("TERMINAL FONT")
                .padding(.top, Theme.Metric.grid * 3)
            VStack(spacing: 0) {
                ForEach(Array(fontOptions.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Hairline() }
                    fontRow(option)
                }
            }
            // The diagnostic. Three numbers, micro-caps, sitting where a plate
            // number would: which enumeration API saw how many candidate
            // families. A font installed by a provider app is invisible to all
            // three, and seeing three small numbers is what tells you that
            // rather than leaving the picker looking simply empty.
            MicroLabel(fontCensus.line)
                .llMeasuredColumn()
                .accessibilityLabel(Text("font enumeration sources: \(fontCensus.line)"))
            proseText("Fonts you installed with a configuration profile show up here. Only the bundled face is guaranteed to carry the Private Use Area icons a prompt draws; anything missing from your font is drawn from the bundled one, so a prompt never falls back to empty boxes.")
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Metric.grid)
            Hairline()
            sizeControl
            Hairline()
            specimen
            Hairline()
            manualEntry
                .padding(.bottom, Theme.Metric.grid * 4)
        }
        // Enumerating every installed family measures glyph advances, which is
        // far too much work to redo on every body evaluation.
        .task {
            refreshFontOptions()
            if Self.demoParksOnFont, typedFamily.isEmpty { typedFamily = "Berkeley Mono" }
            if Self.demoRequestsFont { request(name: typedFamily) }
        }
    }

    private func refreshFontOptions() {
        let picker = TerminalFont.picker(selected: host.fontFamily)
        fontOptions = picker.list
        fontCensus = picker.census
    }

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
        .frame(minHeight: Theme.Metric.hitTarget)
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
        .padding(.vertical, Theme.Metric.grid * 2)
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
                    TextField("", text: $typedFamily, prompt: prompt("Berkeley Mono"))
                        .focused($focusedField, equals: .fontName)
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
                proseText("A font installed by an app rather than by a profile is not visible to other apps until they ask for it by name. Type the family name exactly as the font app shows it and iOS will offer you the choice.")
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
        focusedField = nil
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

    /// Eight normal ANSI colours as 6pt squares, the palette shown as itself.
    private var swatches: some View {
        HStack(spacing: 2) {
            ForEach(1..<7, id: \.self) { index in
                Rectangle()
                    .fill(Theme.ansi[index])
                    .frame(width: Theme.Metric.statusSquare, height: Theme.Metric.statusSquare)
            }
        }
        .padding(.top, Theme.Metric.grid + 2)
        .accessibilityHidden(true)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Metric.grid * 2) {
                MicroLabel(title, color: Theme.accent)
                Rectangle()
                    .fill(Theme.rule)
                    .frame(height: 0.5)
            }
            .padding(.top, Theme.Metric.grid * 6)
            .padding(.bottom, Theme.Metric.grid * 2)
            content()
        }
    }

    private func prompt(_ text: String) -> Text {
        // A placeholder is an example a user reads, so it takes `inkMuted`.
        // `inkDim` would make the field look filled with nothing legible.
        Text(text).foregroundColor(Theme.inkMuted)
    }

    // MARK: - Validation

    /// The port field is the only place the model cannot represent what the
    /// user typed, so its error is computed from the text.
    private var portError: String? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "No port. `tailscale serve --https=443` means 443, which is the default here."
        }
        guard let value = Int(trimmed) else {
            return "\"\(trimmed)\" is not a number. Enter the port `tailscale serve` listens on, usually 443."
        }
        guard Host.portRange.contains(value) else {
            return "Port \(value) is out of range. Use 1 to 65535; `tailscale serve --https=443` means 443."
        }
        return nil
    }

    private func shouldShow(_ field: Field) -> Bool {
        showValidation || touched.contains(field)
    }

    private func error(for field: String) -> String? {
        host.validationErrors.first { $0.field == field }?.message
    }

    private var isSaveable: Bool {
        host.isValid && portError == nil
    }

    private func save() {
        guard isSaveable else {
            withAnimation(Theme.Motion.state) { showValidation = true }
            focusedField = host.hostname.trimmingCharacters(in: .whitespaces).isEmpty ? .hostname : .port
            return
        }
        var saved = host
        saved.hostname = saved.hostname.trimmingCharacters(in: .whitespaces)
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        saved.startCommand = saved.startCommand.trimmingCharacters(in: .whitespaces)
        onSave(saved, secretEdited ? unlockSecret : nil)
        dismiss()
    }
}
