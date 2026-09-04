import SwiftUI

/// The SESSION section's startup command, written as steps.
///
/// A startup command gets written as a numbered list, because that is what it
/// is:
///
///     1.  cd ~/project
///     2.  tmux attach -t main
///     3.  npm run dev
///
/// So the editor is a numbered list. The steps are joined with `&&` into the
/// one `cmd` string ATTACH already carries, which needs no protocol change:
/// the daemon runs the value through `$SHELL -l -i -c`, and that handles `&&`.
/// `&&` rather than `;` so a failed step stops the chain, because a `cd` that
/// failed must not leave the steps after it running in the wrong directory.
///
/// Two things this view exists to do beyond holding text:
///
/// - **Show what is sent.** The joined string is printed underneath, exactly as
///   the daemon will receive it. A chain that is assembled invisibly is a chain
///   nobody can debug from a phone.
/// - **Warn about the step that takes over.** Step 2 above blocks, so the list
///   does not do what it reads like: the dev server starts after you *detach*,
///   in the outer shell, outside tmux. `StartupChain` finds a blocking step
///   that is not last, and this view names it. It is a warning and never a
///   validation error: someone may genuinely want to land in tmux and leave
///   the rest of the chain for later.
///
/// One step, and none, stay the single line they already were. Someone who
/// wants one command does not pay for the chain.
struct StartupChainEditor: View {
    /// The stored value: one step per line (see `Host.startCommand`).
    @Binding var command: String

    /// The rows as drawn. Identified rather than indexed so a reorder animates
    /// as a move and a focused field keeps its focus when it changes position.
    @State private var steps: [Step]
    @FocusState private var focused: Step.ID?

    /// One row. Blank rows are legal while editing; `StartupChain` drops them
    /// on the way out, so clearing a field never deletes its own row.
    private struct Step: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    init(command: Binding<String>) {
        _command = command
        let written = StartupChain.steps(in: command.wrappedValue)
        _steps = State(initialValue: (written.isEmpty ? [""] : written).map { Step(text: $0) })
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if steps.count == 1 {
                singleStep
            } else {
                chain
            }
            addStepButton
            warnings
            if steps.count > 1 { preview }
            note
        }
        .onChange(of: steps) { _, rows in
            command = rows.map(\.text).joined(separator: "\n")
        }
    }

    // MARK: The light case

    /// Exactly the field this section always had: one line, one label, one
    /// annotation. The chain only exists once a second step does.
    private var singleStep: some View {
        FieldRow(label: Self.label, annotation: "OPTIONAL") {
            // The placeholder is an example a stranger reads first, so it is a
            // command that exists on every machine and belongs to nobody:
            // `-A` attaches if the session is there and creates it if it is
            // not, which is also the idiom the rest of this screen teaches.
            TextField("", text: $steps[0].text, prompt: prompt("tmux new -A -s main"))
                .focused($focused, equals: steps[0].id)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Startup command"))
        }
    }

    // MARK: The chain

    private var chain: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Metric.grid * 2) {
                MicroLabel(Self.label)
                Spacer(minLength: 0)
                MicroLabel("\(steps.count) STEPS").llMeasuredColumn()
            }
            .padding(.top, Theme.Metric.grid * 2)
            .padding(.bottom, Theme.Metric.grid)

            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Hairline() }
                row(at: index, step: step)
            }
            Hairline()
        }
    }

    private func row(at index: Int, step: Step) -> some View {
        HStack(spacing: Theme.Metric.grid * 2) {
            // The gutter number, in tabular mono: this is the numbering the
            // owner writes, printed where a drawing prints its callouts.
            Text("\(index + 1)")
                .llValue(Theme.inkMuted)
                .frame(width: Self.gutterWidth, alignment: .trailing)
                .llMeasuredColumn()
                .accessibilityHidden(true)

            TextField("", text: $steps[index].text)
                .font(.llValue)
                .foregroundStyle(Theme.inkBright)
                .tint(Theme.accent)
                .focused($focused, equals: step.id)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Step \(index + 1)"))

            // Reordering is the fix for the trap this whole section is about:
            // a blocking step is corrected by moving it last, so moving is a
            // first-class control and not a hidden drag gesture.
            control("\u{25B2}", label: "Move step \(index + 1) up", enabled: index > 0) {
                move(at: index, by: -1)
            }
            control("\u{25BC}", label: "Move step \(index + 1) down", enabled: index < steps.count - 1) {
                move(at: index, by: 1)
            }
            control("\u{00D7}", label: "Remove step \(index + 1)", tint: Theme.alertText) {
                remove(at: index)
            }
        }
        // DESIGN.md's row minimum, not the smaller control minimum: this is a
        // row in a list, and it is thumbed at a walk.
        .frame(minHeight: Theme.Metric.rowHeight)
    }

    private var addStepButton: some View {
        Button("+ STEP") { addStep() }
            .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
            .padding(.top, Theme.Metric.grid * 2)
            .accessibilityLabel(Text("Add step"))
    }

    // MARK: The warning

    /// Named, not decorated. The message says which step blocks and what that
    /// costs, because "invalid" would be a lie: the chain is valid, it just
    /// does something other than what it looks like.
    @ViewBuilder
    private var warnings: some View {
        let blocking = StartupChain.blockingSteps(in: steps.map(\.text))
        if !blocking.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metric.grid) {
                ForEach(blocking, id: \.number) { step in
                    HStack(alignment: .top, spacing: Theme.Metric.grid * 2) {
                        // `warn` measures 8.10:1 on `ground` and more on
                        // `panel`, so it is allowed to carry the sentence as
                        // well as the mark.
                        MicroLabel("WARN", color: Theme.warn)
                            .padding(.top, 1)
                        proseText(message(for: step))
                            .llProse(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, Theme.Metric.grid * 3)
            .transition(.opacity)
            .animation(Theme.Motion.state, value: blocking)
        }
    }

    private func message(for step: StartupChain.BlockingStep) -> String {
        "Step \(step.number) runs `\(step.program)`, which takes over the terminal. "
            + "Nothing after it runs until it exits. Move it to the end if the other steps should run."
    }

    // MARK: What gets sent

    /// The joined string, printed as the daemon receives it. No ellipsis and
    /// no paraphrase: this is the value, wrapped if it has to be.
    private var preview: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid) {
            MicroLabel("SENDS")
            Text(StartupChain.command(steps.map(\.text).joined(separator: "\n")) ?? "\u{2014}")
                .llValue(Theme.inkBright)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.top, Theme.Metric.grid * 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: The note

    /// Kept from the single-line field: that the command runs through the
    /// login shell interactively is genuinely surprising, and it is the whole
    /// reason an alias from your own dotfiles resolves at all. The second
    /// sentence appears only once there is a chain to explain.
    private var note: some View {
        proseText(
            steps.count > 1
                ? "Runs through your login shell interactively, so aliases and functions resolve. Steps are joined with `&&`, so a step that fails stops the ones after it."
                : "Runs through your login shell interactively, so aliases and functions resolve."
        )
        .llProse()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Theme.Metric.grid * 3)
        .padding(.bottom, Theme.Metric.grid * 3)
    }

    // MARK: Editing

    private func addStep() {
        let step = Step(text: "")
        withAnimation(Theme.Motion.state) { steps.append(step) }
        focused = step.id
    }

    private func move(at index: Int, by offset: Int) {
        let destination = index + offset
        guard steps.indices.contains(destination) else { return }
        withAnimation(Theme.Motion.state) { steps.swapAt(index, destination) }
    }

    private func remove(at index: Int) {
        guard steps.indices.contains(index) else { return }
        withAnimation(Theme.Motion.state) {
            steps.remove(at: index)
            // The section is never stepless: an empty list is the same thing
            // as one empty step, and one empty step is the light case.
            if steps.isEmpty { steps = [Step(text: "")] }
        }
    }

    // MARK: Chrome

    private func control(
        _ glyph: String,
        label: String,
        tint: Color = Theme.inkMuted,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Text(glyph) }
            .buttonStyle(StepControlButtonStyle(tint: tint))
            .disabled(!enabled)
            .accessibilityLabel(Text(label))
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundColor(Theme.inkMuted)
    }

    private static let label = "STARTUP COMMAND"
    /// Wide enough for two tabular digits, which is more steps than anyone
    /// should be typing on a phone.
    private static let gutterWidth: CGFloat = 16
}

/// A bare glyph control on the mono grid: no border in its resting state,
/// because a row of three bordered boxes per step reads as a toolbar and this
/// world does not have toolbars. Pressed is the `raised` layer, disabled drops
/// to `inkDim` (the one place that token is allowed near a glyph), and focus is
/// the accent hairline.
struct StepControlButtonStyle: ButtonStyle {
    var tint: Color = Theme.inkMuted

    func makeBody(configuration: Configuration) -> some View {
        StatefulBody(configuration: configuration, tint: tint)
    }

    private struct StatefulBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.llValue)
                .foregroundStyle(isEnabled ? tint : Theme.inkDim)
                .frame(width: 30, height: Theme.Metric.hitTarget)
                .background(configuration.isPressed ? Theme.raised : Color.clear)
                .overlay {
                    Rectangle()
                        .strokeBorder(Theme.accent, lineWidth: isFocused ? 1 : 0)
                }
                .animation(Theme.Motion.state, value: configuration.isPressed)
                .animation(Theme.Motion.state, value: isEnabled)
                .contentShape(Rectangle())
        }
    }
}
