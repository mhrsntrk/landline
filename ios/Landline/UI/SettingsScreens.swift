import SwiftUI

// The app-wide settings, and the screens that arrange the key bar.
//
// Everything here is drawn in the world the host sheet already established: a
// `SettingHeader`, `SummaryRow`s that state a value, hairline-delimited rows,
// micro-caps annotation, and a measured column on the right that says what the
// thing actually does. Nothing new is invented.

// MARK: - Settings

/// The app's first app-wide settings screen.
///
/// One row today. It exists as a level anyway because the distinction it draws
/// is the one the user has to hold: what belongs to a machine (palette, font,
/// tmux leader) is edited on the machine, and what belongs to the thumb is
/// edited once, here.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var route: Route?

    enum Route: String, Hashable { case keyBar }

    var body: some View {
        SettingScreen(title: "SETTINGS", annotation: "APP-WIDE / EVERY HOST") {
            proseText("These apply to every machine. What differs between machines, like the palette, the font and the tmux leader, is set on the host itself.")
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Theme.Metric.grid * 3)

            SummaryRow(label: "KEY BAR", value: keyCount, detail: layoutNote) {
                route = .keyBar
            }
            Hairline()

            // The row names the setting; this states it. A settings index with
            // one entry and nothing else on it is a tap that answers no
            // question, and the bar drawn as itself is the whole answer — the
            // same device the font screen uses for its specimen.
            VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
                MicroLabel("AS THE TERMINAL WILL DRAW IT")
                KeyBar(keys: settings.resolvedKeyBar,
                       ctrlLatched: .constant(false),
                       altLatched: .constant(false),
                       leaderLatched: .constant(false),
                       leaderByte: 0x02,
                       send: nil)
                    // Cancels the page gutter: the bar is furniture that runs
                    // edge to edge, and inset it would read as a card.
                    .padding(.horizontal, -Theme.Metric.gutter)
            }
            .padding(.top, Theme.Metric.grid * 4)
        }
        .navigationDestination(item: $route) { _ in KeyBarSettingsView() }
        .task { if DemoSeed.opensKeyBar { route = .keyBar } }
    }

    private var keyCount: String {
        let count = settings.resolvedKeyBar.count
        return "\(count) \(count == 1 ? "KEY" : "KEYS")"
    }

    private var layoutNote: String? {
        settings.isDefaultKeyBar ? "DEFAULT" : "CUSTOM"
    }
}

// MARK: - Key bar

/// The row, in order, with the ordering as the point.
///
/// A `List` rather than the `ScrollView` every other setting screen uses,
/// because this is the one screen whose content is rearranged: `onMove` is what
/// makes a drag work, and it only exists on `List`. Everything visible is still
/// this world's — plain style, hidden separators, our own hairlines, `ground`
/// row backgrounds — so it reads as the index, not as a settings app.
///
/// Reorder is offered twice on purpose. A drag is fast when both hands are
/// free; the ▲ ▼ pair is what works one-handed on a train, which is the scene
/// this app is actually used in (PRODUCT.md).
struct KeyBarSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var route: Route?

    enum Route: Hashable {
        case catalog
        /// nil adds a new custom key; an id edits that one.
        case custom(UUID?)
    }

    var body: some View {
        VStack(spacing: 0) {
            specimen
            if settings.keyBar.isEmpty { empty } else { list }
        }
        .background(Theme.panel)
        .safeAreaInset(edge: .top, spacing: 0) {
            SettingHeader(title: "KEY BAR", annotation: annotation)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $route) { destination($0) }
        .task {
            if DemoSeed.opensCustomKey { route = .custom(nil) }
            if DemoSeed.opensCatalog { route = .catalog }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .catalog:
            KeyBarCatalogView()
        case .custom(let id):
            KeyBarCustomKeyView(editing: id)
        }
    }

    private var annotation: String {
        let count = settings.keyBar.count
        return "\(count) \(count == 1 ? "KEY" : "KEYS") / IN ORDER, LEFT TO RIGHT"
    }

    // MARK: Specimen
    //
    // The font screen's device: the setting drawn as the thing it produces. A
    // list of key names does not answer "is my thumb going to land on the right
    // one", and the actual bar does.

    private var specimen: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            MicroLabel("AS THE TERMINAL WILL DRAW IT")
                .padding(.horizontal, Theme.Metric.gutter)
            // At rest, because the label above it says this is what the terminal
            // will draw. A latched cell here would read as a live setting.
            KeyBar(keys: settings.resolvedKeyBar,
                   ctrlLatched: .constant(false),
                   altLatched: .constant(false),
                   leaderLatched: .constant(false),
                   leaderByte: 0x02,
                   send: nil)
        }
        .padding(.top, Theme.Metric.grid * 3)
        .padding(.bottom, Theme.Metric.grid * 3)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: Rows

    private var list: some View {
        List {
            ForEach(Array(settings.keyBar.enumerated()), id: \.element.id) { index, key in
                row(key, at: index)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.ground)
                    .overlay(alignment: .bottom) { Hairline() }
                    .deleteDisabled(true)
            }
            // Long-press drag. Not in edit mode: an active `List` draws a grey
            // system grip on every row, which is precisely the iOS chrome this
            // world refuses (DESIGN.md), and the ▲ ▼ pair in the row is both
            // the visible affordance and the one that works one-handed.
            .onMove { settings.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .environment(\.defaultMinListRowHeight, Theme.Metric.rowHeight)
    }

    private func row(_ key: KeyBarKey, at index: Int) -> some View {
        HStack(spacing: Theme.Metric.grid * 3) {
            // Position in the row, because position is the setting.
            Text(String(format: "%02d", index + 1))
                .llValue(Theme.inkMuted)
                .llMeasuredColumn()

            // The cell as the bar prints it, at the width the bar gives it.
            Text(key.resolved?.label ?? "?")
                .font(.llMicroLabel)
                .tracking(0.8)
                .foregroundStyle(key.resolved == nil ? Theme.alertText : Theme.inkBright)
                .lineLimit(1)
                .frame(width: 40, height: 28)
                .overlay { Rectangle().strokeBorder(Theme.rule, lineWidth: 0.5) }

            VStack(alignment: .leading, spacing: 1) {
                Text(key.settingsName)
                    .llValue()
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A custom key is the only row that opens something, so it is
                // the only row that says so. A key you wrote and cannot find
                // your way back into is a key you have to delete and retype.
                MicroLabel(key.isCustom ? "CUSTOM / \(key.settingsDetail) \u{203A}" : key.settingsDetail,
                           color: key.resolved == nil ? Theme.alertText : Theme.inkMuted)
                    .llMeasuredColumn()
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Metric.grid)

            glyph("\u{25B2}", label: "move earlier", enabled: index > 0) {
                settings.nudge(id: key.id, by: -1)
            }
            glyph("\u{25BC}", label: "move later", enabled: index < settings.keyBar.count - 1) {
                settings.nudge(id: key.id, by: 1)
            }
            glyph("\u{00D7}", label: "remove", tint: Theme.alertText) {
                settings.remove(id: key.id)
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, Theme.Metric.grid * 2)
        .frame(minHeight: Theme.Metric.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if key.isCustom { route = .custom(key.id) } }
        .accessibilityElement(children: .contain)
    }

    private func glyph(
        _ mark: String,
        label: String,
        enabled: Bool = true,
        tint: Color = Theme.ink,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(mark)
        }
        .buttonStyle(SquareGlyphButtonStyle(tint: tint))
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 4) {
            MicroLabel("NO KEYS")
            proseText("The bar is empty, so the terminal keeps its full height. Add a key, or reset to the default row.")
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, Theme.Metric.grid * 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: Theme.Metric.grid * 3) {
                Button("+ ADD KEY") { route = .catalog }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                Button("+ CUSTOM") { route = .custom(nil) }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                Spacer(minLength: 0)
                Button("RESET") {
                    withAnimation(Theme.Motion.state) { settings.resetKeyBar() }
                }
                .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                .disabled(settings.isDefaultKeyBar)
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, Theme.Metric.grid * 3)
        }
        .background(Theme.panel)
    }
}

// MARK: - Catalog

/// Everything the bar can be given, grouped, each row stating the bytes it
/// sends. Tapping appends to the end of the row and comes straight back, since
/// where it lands is settable on the screen behind this one.
struct KeyBarCatalogView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingScreen(title: "ADD KEY", annotation: "TAP TO APPEND TO THE ROW") {
            ForEach(KeyBarCatalog.groups) { group in
                HStack(spacing: Theme.Metric.grid * 2) {
                    MicroLabel(group.id, color: Theme.accent)
                    Rectangle().fill(Theme.rule).frame(height: 0.5)
                }
                .padding(.top, Theme.Metric.grid * 6)
                .padding(.bottom, Theme.Metric.grid * 2)

                VStack(spacing: 0) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Hairline() }
                        row(entry)
                    }
                }
            }
        }
    }

    private func row(_ entry: KeyBarCatalogEntry) -> some View {
        Button {
            settings.append(KeyBarKey(catalogID: entry.id))
            dismiss()
        } label: {
            HStack(spacing: Theme.Metric.grid * 3) {
                Text(entry.label)
                    .font(.llMicroLabel)
                    .tracking(0.8)
                    .foregroundStyle(Theme.inkBright)
                    .lineLimit(1)
                    .frame(width: 40, height: 28)
                    .overlay { Rectangle().strokeBorder(Theme.rule, lineWidth: 0.5) }
                Text(entry.name)
                    .llValue()
                    .lineLimit(1)
                Spacer(minLength: Theme.Metric.grid * 2)
                MicroLabel(detail(entry))
                    .llMeasuredColumn()
                Text("+")
                    .llValueStrong(Theme.accent)
            }
            .frame(minHeight: Theme.Metric.hitTarget)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(InstrumentRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("add \(entry.name)"))
        .accessibilityValue(Text(detail(entry)))
    }

    /// What the key puts on the wire, in hex — the same readout the custom
    /// editor shows, so the two are read the same way. A tmux key prints its
    /// leader slot as `LDR`, because this screen is app-wide and the byte is
    /// per host.
    private func detail(_ entry: KeyBarCatalogEntry) -> String {
        switch entry.action {
        case .send(let template): return KeySequence.hex(template)
        case .latchCtrl, .latchAlt, .latchLeader: return "LATCHES"
        }
    }
}

// MARK: - Custom key

/// A key the user writes: a label, and the bytes it sends.
///
/// The rule this screen enforces is the whole reason it validates as you type:
/// a custom key that silently sends the wrong bytes is worse than no custom key
/// at all. So the resolved bytes are printed in hex under the field, and SAVE is
/// dead until the sequence parses.
struct KeyBarCustomKeyView: View {
    /// nil adds a new key; an id edits the stored one.
    let editing: UUID?

    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var sequence = ""
    @FocusState private var focused: Field?

    private enum Field: Hashable { case label, sequence }

    var body: some View {
        SettingScreen(title: editing == nil ? "CUSTOM KEY" : "EDIT KEY", annotation: annotation) {
            FieldRow(label: "LABEL", annotation: "PRINTED ON THE CELL") {
                TextField("", text: $label, prompt: prompt("^W"))
                    .focused($focused, equals: .label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Hairline()
            FieldRow(label: "SENDS", annotation: "SEQUENCE", error: error) {
                TextField("", text: $sequence, prompt: prompt("\\e[1;5D"))
                    .focused($focused, equals: .sequence)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.llValue)
            }

            bytesPlate
            Hairline()
            syntax

            HStack(spacing: Theme.Metric.grid * 3) {
                Button(editing == nil ? "ADD KEY" : "SAVE") { save() }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                    .disabled(!isSaveable)
                if editing != nil {
                    Button("REMOVE") {
                        if let editing { settings.remove(id: editing) }
                        dismiss()
                    }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .destructive))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, Theme.Metric.grid * 4)
        }
        .task {
            if let editing, let key = settings.key(id: editing) {
                label = key.label
                sequence = key.sequence
            } else if let seed = Self.demoSequenceSeed ?? DemoSeed.customKeySeed {
                // Debug screenshot hook: a sequence in the field, so the hex
                // readout, the syntax table and the refusal can be looked at.
                label = seed.label
                sequence = seed.sequence
            }
        }
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundColor(Theme.inkMuted)
    }

    /// Debug screenshot hook, the same idiom as `DemoSeed`: put any sequence in
    /// the field from the environment, so a readout like `LDR 63` can be looked
    /// at rather than reasoned about. Off unless the variable is set, and
    /// compiled out of release.
    private static var demoSequenceSeed: (label: String, sequence: String)? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let sequence = environment["LANDLINE_DEMO_SEQ"] else { return nil }
        return (environment["LANDLINE_DEMO_LABEL"] ?? "Lc", sequence)
        #else
        return nil
        #endif
    }

    private var parsed: Result<KeySequence.Template, KeySequence.ParseError> {
        KeySequence.parse(sequence)
    }

    /// The parsed sequence, still holding its leader slot. These settings are
    /// app-wide, so there is no host here to fill it in and the readout says so
    /// rather than printing a byte nobody chose.
    private var template: KeySequence.Template? {
        if case .success(let template) = parsed { return template }
        return nil
    }

    private var error: String? {
        // An empty field is not a mistake yet, it is a field nobody has filled
        // in. Only something typed can be wrong.
        guard !sequence.isEmpty, case .failure(let failure) = parsed else { return nil }
        return failure.message
    }

    private var annotation: String {
        guard let template, !template.isEmpty else { return "UNRESOLVED" }
        let count = template.byteCount
        return "\(count) \(count == 1 ? "BYTE" : "BYTES") / \(KeySequence.hex(template))"
    }

    /// The readout that makes a wrong sequence visible before it is saved.
    /// Drawn as a plate, the way the font screen draws its specimen: two
    /// registration marks, `ground`, and the value set large enough to read at
    /// arm's length.
    ///
    /// A `\L` prints as `LDR`, not as a byte. This screen has no host, so the
    /// only honest thing it can show for the leader is the slot itself, with one
    /// line under the plate saying who fills it in.
    private var bytesPlate: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            HStack(spacing: Theme.Metric.grid * 2) {
                MicroLabel("RESOLVED BYTES")
                Spacer(minLength: 0)
                MicroLabel(template.map { "\($0.byteCount)" } ?? "—").llMeasuredColumn()
            }
            Text(template.map { $0.isEmpty ? "—" : KeySequence.hex($0) } ?? "—")
                .llValueStrong(template == nil ? Theme.inkMuted : Theme.inkBright)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Metric.grid * 3)
                .padding(.horizontal, Theme.Metric.grid * 3)
                .background(Theme.ground)
                .overlay { RegistrationMarks(diagonal: .topLeadingBottomTrailing) }
                .accessibilityLabel(Text("resolved bytes"))
                .accessibilityValue(Text(template.map { KeySequence.hex($0) } ?? "does not parse"))
            if template?.needsLeader == true {
                proseText("LDR is filled in per host, from that host's tmux leader.")
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Metric.grid * 3)
    }

    /// The whole syntax, printed. It is four lines; hiding it behind a link
    /// would mean typing an escape from memory, which is how a wrong byte gets
    /// saved.
    private var syntax: some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel("SYNTAX")
                .padding(.top, Theme.Metric.grid * 3)
                .padding(.bottom, Theme.Metric.grid * 2)
            ForEach(Array(KeySequence.syntaxRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Theme.Metric.grid * 3) {
                    Text(row.token)
                        .llValue(Theme.inkBright)
                        .frame(width: 92, alignment: .leading)
                        .llMeasuredColumn()
                    proseText(row.meaning)
                        .llProse()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Theme.Metric.grid + 2)
            }
        }
    }

    /// A sequence that needs a leader is saveable here even though this screen
    /// cannot resolve it: the byte arrives with the host. What is refused is the
    /// same as before, a sequence that does not parse or produces nothing.
    private var isSaveable: Bool {
        guard let template, !template.isEmpty else { return false }
        return !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        guard isSaveable else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        if let editing, var key = settings.key(id: editing) {
            key.label = trimmedLabel
            key.sequence = sequence
            settings.replace(key)
        } else {
            settings.append(KeyBarKey(label: trimmedLabel, sequence: sequence))
        }
        dismiss()
    }
}

// MARK: - Square glyph control

/// A 32pt square bordered cell holding one mono glyph: the ▲ ▼ × controls in
/// the key bar list. `InstrumentButtonStyle` is the same world but is sized for
/// a word, and three of them side by side would not leave room for the row.
struct SquareGlyphButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        StatefulBody(configuration: configuration, tint: tint)
    }

    private struct StatefulBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.llValue)
                .foregroundStyle(isEnabled ? tint : Theme.inkDim)
                .frame(width: 32, height: 32)
                .background(configuration.isPressed ? Theme.raised : Color.clear)
                .overlay {
                    Rectangle().strokeBorder(
                        isEnabled ? Theme.rule : Theme.rule.opacity(0.5),
                        lineWidth: 0.5
                    )
                }
                // The glyph is 32pt but the finger gets the row's full height,
                // so the 44pt floor is met without three fat squares crowding
                // the name column out of the row.
                .contentShape(Rectangle().inset(by: -6))
                .animation(Theme.Motion.state, value: configuration.isPressed)
        }
    }
}
