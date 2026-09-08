import SwiftUI

// Saved text, and the two places it is met: the picker a session opens, and the
// list where it is written. See `Snippet` for why the app keeps text at all.

// MARK: - The picker

/// What the `SNIP` key opens: the list, one tap, done.
///
/// A sheet rather than a push, because this interrupts a session rather than
/// navigating away from one, and it closes on the tap that chooses. Nothing is
/// editable here: choosing and writing are different moods and the thumb that
/// is mid-command wants only the first.
struct SnippetPickerView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let choose: (Snippet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if settings.snippets.isEmpty { empty } else { list }
            }
            .background(Theme.panel)
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingHeader(title: "SNIPPETS", annotation: annotation, leading: .close)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var annotation: String {
        let count = settings.snippets.count
        guard count > 0 else { return "NOTHING SAVED YET" }
        return "\(count) SAVED / TAP TO TYPE"
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(settings.snippets) { snippet in
                    Button { choose(snippet) } label: { row(snippet) }
                        .buttonStyle(InstrumentRowButtonStyle())
                    Hairline()
                }
            }
            .padding(.bottom, Theme.Metric.grid * 8)
        }
        .background(Theme.ground)
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: Theme.Metric.grid * 3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.displayName)
                    .llValue()
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Not `MicroLabel`: that register uppercases, and a shell
                // command is case sensitive. `CD ~/SRC` is not a command
                // anyone can run, and printing it as though it were is worse
                // than printing nothing.
                Text(snippet.summary)
                    .llMicroLabel()
                    .lineLimit(1)
                    .llMeasuredColumn()
            }
            Spacer(minLength: Theme.Metric.grid)
            // The one thing about a snippet that changes what a tap does, so
            // the one thing the picker states.
            if snippet.runsImmediately {
                MicroLabel("RUNS", color: Theme.warn)
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, Theme.Metric.grid * 2)
        .frame(minHeight: Theme.Metric.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 4) {
            MicroLabel("NOTHING SAVED")
            proseText("Snippets are text you keep so you do not have to type it on a phone. Write them in Settings, then reach them from this key.")
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
            Button("CLOSE") { dismiss() }
                .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, Theme.Metric.grid * 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
    }
}

// MARK: - The list

/// Where snippets are written and ordered. Same shape as the key bar screen,
/// because it is the same kind of thing: an ordered list the owner rearranges.
struct SnippetSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var editing: UUID??

    var body: some View {
        VStack(spacing: 0) {
            if settings.snippets.isEmpty { empty } else { list }
        }
        .background(Theme.panel)
        .safeAreaInset(edge: .top, spacing: 0) {
            SettingHeader(title: "SNIPPETS", annotation: annotation)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $editing) { SnippetEditView(editing: $0) }
        .task {
            for snippet in DemoSeed.seededSnippets where settings.snippet(id: snippet.id) == nil {
                settings.appendSnippet(snippet)
            }
            if DemoSeed.opensSnippetEditor { editing = .some(nil) }
        }
    }

    private var annotation: String {
        let count = settings.snippets.count
        guard count > 0 else { return "NOTHING SAVED YET" }
        return "\(count) SAVED / HOLD A ROW TO REORDER"
    }

    private var list: some View {
        List {
            ForEach(settings.snippets) { snippet in
                row(snippet)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.ground)
                    .overlay(alignment: .bottom) { Hairline() }
                    .deleteDisabled(true)
            }
            .onMove { settings.moveSnippets(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .environment(\.defaultMinListRowHeight, Theme.Metric.rowHeight)
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: Theme.Metric.grid * 3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.displayName)
                    .llValue()
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: Theme.Metric.grid) {
                    if snippet.runsImmediately {
                        MicroLabel("RUNS", color: Theme.warn)
                    }
                    // Verbatim, for the reason given in the picker.
                    Text("\(snippet.summary) \u{203A}")
                        .llMicroLabel()
                        .lineLimit(1)
                }
                .llMeasuredColumn()
            }
            Spacer(minLength: Theme.Metric.grid)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, Theme.Metric.grid * 2)
        .frame(minHeight: Theme.Metric.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { editing = .some(snippet.id) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 4) {
            MicroLabel("NOTHING SAVED")
            proseText("A snippet is text you keep so you do not have to type it on a phone: a long command, a path you always mistype, a prompt you send an agent. Add the `SNIP` key to the key bar to reach them from a session.")
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, Theme.Metric.grid * 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: Theme.Metric.grid * 3) {
                Button("+ SNIPPET") { editing = .some(nil) }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, Theme.Metric.grid * 3)
        }
        .background(Theme.panel)
    }
}

// MARK: - The editor

/// One snippet: a name, the text, and whether choosing it presses return.
struct SnippetEditView: View {
    /// nil adds a new one; an id edits that one.
    let editing: UUID?

    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var text = ""
    @State private var runsImmediately = false

    var body: some View {
        SettingScreen(title: editing == nil ? "NEW SNIPPET" : "EDIT SNIPPET",
                      annotation: annotation) {
            FieldRow(label: "NAME", annotation: "OPTIONAL") {
                TextField("", text: $name, prompt: prompt("deploy staging"))
                    .autocorrectionDisabled()
            }
            Hairline()

            VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
                HStack(spacing: Theme.Metric.grid * 2) {
                    MicroLabel("TEXT")
                    Spacer(minLength: 0)
                    MicroLabel(sizeNote).llMeasuredColumn()
                }
                // Multi-line, because a snippet is routinely several commands
                // and a single-line field would make that impossible to read
                // back. Mono, because every character of it is going to a
                // shell and the alignment is the proofreading.
                TextEditor(text: $text)
                    .font(.llValue)
                    .foregroundStyle(Theme.inkBright)
                    .tint(Theme.accent)
                    .scrollContentBackground(.hidden)
                    .background(Theme.ground)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 120)
                    .overlay { Rectangle().strokeBorder(Theme.rule, lineWidth: 0.5) }
            }
            .padding(.vertical, Theme.Metric.grid * 3)
            Hairline()

            // The note is the whole reason this is a setting rather than the
            // default. A snippet lands at whatever prompt happens to be there.
            InstrumentToggle(
                title: "PRESS RETURN AFTER TYPING IT",
                isOn: $runsImmediately,
                note: runsImmediately
                    ? "This snippet runs the moment it is chosen, at whatever prompt is open."
                    : "The text is typed and left at the prompt, for you to check and press return yourself."
            )
            .padding(.vertical, Theme.Metric.grid * 3)

            HStack(spacing: Theme.Metric.grid * 3) {
                Button(editing == nil ? "ADD" : "SAVE") { save() }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                    .disabled(text.isEmpty)
                if editing != nil {
                    Button("REMOVE") {
                        if let editing { settings.removeSnippet(id: editing) }
                        dismiss()
                    }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .destructive))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, Theme.Metric.grid * 4)
        }
        .task {
            guard let editing, let snippet = settings.snippet(id: editing) else { return }
            name = snippet.name
            text = snippet.text
            runsImmediately = snippet.runsImmediately
        }
    }

    private var annotation: String {
        text.isEmpty ? "EMPTY" : sizeNote
    }

    private var sizeNote: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let characters = text.count
        return "\(lines) \(lines == 1 ? "LINE" : "LINES") / \(characters) CHARS"
    }

    private func prompt(_ value: String) -> Text {
        Text(value).foregroundColor(Theme.inkMuted)
    }

    private func save() {
        guard !text.isEmpty else { return }
        if let editing, var snippet = settings.snippet(id: editing) {
            snippet.name = name
            snippet.text = text
            snippet.runsImmediately = runsImmediately
            settings.replaceSnippet(snippet)
        } else {
            settings.appendSnippet(
                Snippet(name: name, text: text, runsImmediately: runsImmediately)
            )
        }
        dismiss()
    }
}
