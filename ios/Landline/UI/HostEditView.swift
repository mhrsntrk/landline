import SwiftUI

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
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, hostname, port, secret, startCommand }

    let onSave: (Host, String?) -> Void

    init(host: Host, onSave: @escaping (Host, String?) -> Void) {
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        _showValidation = State(initialValue: DemoSeed.showsValidation)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
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
