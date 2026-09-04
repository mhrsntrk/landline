import SwiftUI

/// Add or edit one machine. Same world as the index: micro-caps labels above
/// fields, hairline separators, a `panel` sheet, and not one grouped-inset iOS
/// card anywhere.
///
/// The sheet holds only what you set while *adding* a machine: what it is
/// called, where it is, and what runs when you get there. Appearance and
/// security are settings you change once and then read, so each is a pushed
/// screen behind a summary row that states its current value — a row that says
/// `TERMINAL FONT / JetBrains Mono NF` is read in one glance, where the picker it
/// stands for was five rows, a stepper, a plate and a paragraph.
struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State var host: Host
    /// Port is held as text so a typo can be named rather than silently
    /// clamped by UInt16 before anyone gets to see it.
    @State private var portText: String
    /// nil = the user never touched the field; "" = clear the stored secret.
    @State private var unlockSecret: String = ""
    @State private var secretEdited = false
    /// Whether the Keychain already holds a secret for this host, read once so
    /// the summary row can say so without a SecItem query per body evaluation.
    @State private var storedSecret = false
    @State private var showValidation = false
    /// Fields the user has been in and left. An error is only worth showing
    /// once someone has had a chance to fill the field in.
    @State private var touched: Set<Field> = []
    /// Which detail screen is pushed. Held in state rather than driven by
    /// `NavigationLink` so a screenshot run can park on one of them.
    @State private var route: Route?
    @FocusState private var focusedField: Field?

    /// The startup command is not here: it is a chain of fields now, and
    private enum Field: Hashable { case name, hostname, port, startCommand }

    /// The settings that are read far more often than they are changed.
    private enum Route: String, Hashable {
        case palette, font, security
    }

    let onSave: (Host, String?) -> Void

    init(host: Host, onSave: @escaping (Host, String?) -> Void) {
        var host = host
        if let chain = Self.demoStartCommand { host.startCommand = chain }
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        _showValidation = State(initialValue: DemoSeed.showsValidation)
        self.onSave = onSave
    }

    /// Debug screenshot hook, the same idiom as `DemoSeed`: push one of the
    /// detail screens on appear, since a screenshot run has no fingers to tap
    /// with. Does nothing in a release build and nothing without the variable
    /// set.
    private static var demoSection: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LANDLINE_DEMO_SECTION"]
        #else
        return nil
        #endif
    }

    private static var demoRoute: Route? {
        switch demoSection {
        case "font", "fontrequest": return .font
        case "palette": return .palette
        case "security": return .security
        default: return nil
        }
    }

    /// Debug screenshot hook, same idiom again: seed the SESSION section with
    /// one of the three chains it has to handle, so each can be looked at
    /// rather than reasoned about. `blocking` is the chain that reads right
    /// and does the wrong thing, because attaching to tmux holds the terminal
    /// and the step after it waits; `fixed` is the same work reordered so the
    /// step that takes over is last.
    private static var demoStartCommand: String? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["LANDLINE_DEMO_CHAIN"] {
        case "none":
            return ""
        case "single":
            return "tmux new -A -s main"
        case "blocking":
            return "cd ~/project\ntmux attach -t main\nnpm run dev"
        case "fixed":
            return """
            tmux new -A -d -s main -c ~/project
            tmux new-window -n dev -t main -c ~/project 'npm run dev'
            tmux attach -t main
            """
        default:
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Debug screenshot hook: fire one real `CTFontManagerRequestFonts` for a
    /// name nothing can resolve, so the failure path can be looked at rather
    /// than reasoned about. A simulator has no provider-installed font, so this
    /// is the only side of that call it can reach.
    private static var demoRequestsFont: Bool { demoSection == "fontrequest" }

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
                        // The one note left in this section: turning TLS off is
                        // the one switch here that can quietly break a
                        // connection, and the reason to do it is not guessable.
                        InstrumentToggle(
                            title: "TLS",
                            isOn: $host.useTLS,
                            note: "Off only for a daemon without `tailscale serve` in front of it."
                        )
                        .padding(.vertical, Theme.Metric.grid * 2)
                    }

                    section("SESSION") {
                        FieldRow(label: "STARTUP COMMAND", annotation: "OPTIONAL") {
                            TextField("", text: $host.startCommand,
                                      prompt: prompt("tmux new -A -s main"))
                                .focused($focusedField, equals: .startCommand)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        // Worth stating because it is genuinely surprising:
                        // without an interactive login shell an alias or a
                        // function simply is not found.
                        proseText("Runs through your login shell interactively, so aliases and "
                            + "functions resolve. Leave it empty for the machine's own default.")
                            .padding(.top, Theme.Metric.grid * 2)
                    }

                    section("TERMINAL") {
                        SummaryRow(label: "PALETTE", value: host.colorScheme.displayName) {
                            route = .palette
                        }
                        Hairline()
                        SummaryRow(label: "FONT",
                                   value: fontSummary,
                                   detail: "\(Int(TerminalFont.size(forHost: host.fontSize))) PT") {
                            route = .font
                        }
                    }

                    section("SECURITY") {
                        SummaryRow(label: "UNLOCK", value: securitySummary) {
                            route = .security
                        }
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
            .navigationDestination(item: $route) { destination($0) }
            .task {
                storedSecret = Keychain.unlockSecret(hostID: host.id) != nil
                route = Self.demoRoute
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .presentationBackground(Theme.panel)
        // Square corners: a rounded sheet is iOS chrome, and this world's
        // corners are 4pt or square.
        .presentationCornerRadius(0)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .palette:
            HostPaletteView(host: $host)
        case .font:
            HostFontView(host: $host,
                         demoPrefill: Self.demoRoute == .font,
                         autoRequest: Self.demoRequestsFont)
        case .security:
            HostSecurityView(host: $host,
                             secret: $unlockSecret,
                             secretEdited: $secretEdited,
                             storedSecret: storedSecret)
        }
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

    // MARK: - Summaries
    //
    // What each detail screen currently amounts to, in one value. A row that
    // states the setting is faster to read than the setting expanded inline,
    // and it is the same sentence the screen behind it opens with.

    /// The face this host renders in, named the way the picker names it.
    private var fontSummary: String {
        host.fontFamily.isEmpty ? TerminalFont.bundledDisplayName : host.fontFamily
    }

    /// What actually guards this host, never what was merely configured: a
    /// Face ID prompt and a stored secret are two different gates, and "OPEN"
    /// is the honest reading when neither is set.
    private var securitySummary: String {
        var parts: [String] = []
        if host.requireFaceID { parts.append("FACE ID") }
        if secretEdited ? !unlockSecret.isEmpty : storedSecret { parts.append("SECRET") }
        return parts.isEmpty ? "OPEN" : parts.joined(separator: " / ")
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
        // Steps in, steps out: each one trimmed and every blank row dropped, so
        // what `hosts.json` holds is the chain and nothing else.
        saved.startCommand = saved.startCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(saved, secretEdited ? unlockSecret : nil)
        dismiss()
    }
}
