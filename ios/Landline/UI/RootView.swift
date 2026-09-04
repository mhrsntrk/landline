import SwiftUI

// Where the app decides what shape it is.
//
// Two structures, chosen by horizontal size class and never by device idiom:
//
//   compact  a pushed stack. Every iPhone, and an iPad in a narrow Split View
//            or Slide Over, which is a phone-shaped window and must behave like
//            one rather than growing a 320pt sidebar inside a 320pt window.
//
//   regular  a two-column split. The index is a persistent sidebar and the
//            terminal fills the detail pane, so a wide screen shows both and
//            changing machines is one tap that never takes the terminal away.
//
// The compact branch is byte-for-byte the structure this app always had: a
// `NavigationStack` around `HostListView`, which pushes `TerminalScreen` and
// `SettingsView` itself. Nothing about the phone changes.

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HostStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    /// The machine the detail pane is showing. An id rather than a `Host`, so a
    /// rename or a palette change does not look like a different selection.
    @State private var selection: UUID?
    /// App-wide settings. A sheet in regular width, a push in compact.
    @State private var showingSettings = false
    /// Seeded from the stored preference in `.task`, and written back on every
    /// change: someone who collapsed the index to give the terminal the whole
    /// screen wants it collapsed next launch too.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var mode: NavigationMode { NavigationMode(horizontalSizeClass) }

    var body: some View {
        // A window that grows from Slide Over to full screen swaps one whole
        // hierarchy for the other, which tears the terminal down and stands a
        // new one up. That is a detach and a reattach, never a kill: the session
        // id lives in the store, `TerminalScreen.onDisappear` sends DETACH, and
        // the fresh screen resumes the same session by id (PROTOCOL.md 6).
        Group {
            switch mode {
            case .stack:
                NavigationStack { HostListView() }
            case .split:
                split
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    // MARK: - Split

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HostListView(selection: $selection, settingsPresented: $showingSettings)
                // Wide enough for the dense sidebar row's three lines to hold
                // their columns, narrow enough to leave the terminal the screen.
                // Measured against the longest thing the row prints: a tailnet
                // hostname with its port.
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 380)
                .toolbar(.hidden, for: .navigationBar)
                .toolbarBackground(Theme.ground, for: .navigationBar)
        } detail: {
            detail
                .toolbar(.hidden, for: .navigationBar)
                // The detail column stops at the safe area, and what shows in
                // the strips above and below it is the window's own ground,
                // which is black. `panel` is the right ink there in both
                // states: the terminal's header band runs into the top strip
                // and its key bar runs into the bottom one, so the bands simply
                // reach the edge of the glass the way an instrument's fascia
                // does. The placeholder covers it with its own ground.
                .background(Theme.panel.ignoresSafeArea())
        }
        // .balanced rather than .prominentDetail: the index is not an overlay
        // that dims the terminal, it is the other half of the drawing.
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingSettings) {
            // A sheet, not the detail pane. The detail pane is where the session
            // is, and the app-wide settings are the ones that change how the
            // terminal behaves under your thumb (the key bar, the scroll speed),
            // so taking the terminal away to set them is exactly backwards.
            // Closing puts you back on a session that never stopped.
            NavigationStack {
                SettingsView(leading: .close)
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .presentationBackground(Theme.panel)
            .presentationCornerRadius(0)
        }
        // Written back rather than read every frame, so the split view stays the
        // owner of its own animation and the store only sees the settled value.
        .onChange(of: columnVisibility) { _, new in
            settings.setShowsIndexColumn(new != .detailOnly)
        }
        .task {
            columnVisibility = settings.showsIndexColumn ? .all : .detailOnly
            DemoSeed.seedIfRequested(into: store)
            if DemoSeed.opensTerminal { selection = store.hosts.first?.id }
            if DemoSeed.opensSettings { showingSettings = true }
            // Debug screenshot hook. See `DemoSeed.switchesHosts`.
            if DemoSeed.switchesHosts, store.hosts.count > 1 {
                try? await Task.sleep(for: .seconds(6))
                selection = store.hosts[1].id
                try? await Task.sleep(for: .seconds(5))
                selection = store.hosts[0].id
            }
            // Debug screenshot hook. See `DemoSeed.togglesIndex`.
            if DemoSeed.togglesIndex {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(Theme.Motion.state) { columnVisibility = .detailOnly }
                try? await Task.sleep(for: .seconds(8))
                withAnimation(Theme.Motion.state) { columnVisibility = .all }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let host = store.host(id: selection) {
            // Keyed on the host, so choosing a different machine tears this
            // screen down and stands the next one up: `onDisappear` detaches the
            // old session and the new screen reattaches its own by session id.
            TerminalScreen(host: host, indexColumn: $columnVisibility)
                .id(host.id)
        } else {
            DetailPlaceholderView(hasHosts: !store.hosts.isEmpty,
                                  indexColumn: $columnVisibility)
        }
    }
}

// MARK: - Navigation mode

/// The shape the app is in. A named value rather than a size-class comparison
/// scattered through the views, so the rule is stated once and can be tested.
enum NavigationMode: String, Equatable {
    /// A pushed stack. Compact width, whatever the device is.
    case stack
    /// A persistent index beside the terminal. Regular width.
    case split

    init(_ horizontalSizeClass: UserInterfaceSizeClass?) {
        // nil is the state SwiftUI reports before a window has been measured.
        // Compact is the safe answer: a stack laid out in a wide window looks
        // sparse for one frame, a split laid out in a narrow one has no room
        // for either column.
        self = horizontalSizeClass == .regular ? .split : .stack
    }
}

// MARK: - Detail placeholder
//
// The first thing anyone sees on an iPad, so it is drawn rather than defaulted.
// A plate waiting for its session: the same micrographics the rest of the app
// uses, registration marks on the region because that is what marks a terminal
// viewport, and one tick scale under the title because that is the rule.
//
// It says three things, in this order: what this is, what to do next, and what
// has to be true on the machine for a host to exist at all. The third only
// appears when the index is empty, because a user with hosts already knows.

struct DetailPlaceholderView: View {
    let hasHosts: Bool
    /// So the index can be brought back from here.
    ///
    /// The index-column preference is remembered between launches, so it is
    /// possible to open the app with the column collapsed and nothing selected,
    /// and in that one state the terminal's header — which is where the toggle
    /// normally lives — is not on screen at all. Without this the app would open
    /// on a pane with no way out of it.
    var indexColumn: Binding<NavigationSplitViewVisibility>?

    private var indexIsHidden: Bool { indexColumn?.wrappedValue == .detailOnly }

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            // Centred in the pane rather than pinned to the top: pinned, a
            // 300pt block on a 1300pt plate leaves three quarters of the pane
            // as bare ground, which is the same unfinished drawing the index's
            // ruled slots exist to answer. `minHeight` from the geometry rather
            // than `maxHeight: .infinity`, because a scroll view hands its
            // content unbounded height and there is nothing to centre in.
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        if hasHosts { next } else { setup }
                    }
                    // A measured block, not a stretched one. Prose set across
                    // 1000pt is unreadable whatever the face, and a drawing has
                    // a plate size.
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, Theme.Metric.gutter * 2)
                    .padding(.vertical, Theme.Metric.grid * 12)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // The marks that say "this is the terminal viewport", drawn on the
        // viewport that has no terminal in it yet.
        .overlay { RegistrationMarks(diagonal: .topTrailingBottomLeading) }
        .safeAreaInset(edge: .top, spacing: 0) { revealBand }
        .accessibilityElement(children: .contain)
    }

    /// The header band, reduced to the one thing this screen has to offer: the
    /// way back to the index. Drawn only while the index is hidden, because a
    /// band holding a control that would do nothing is decoration, and this
    /// world does not draw decoration.
    @ViewBuilder
    private var revealBand: some View {
        if let indexColumn, indexIsHidden {
            HStack(spacing: 0) {
                HeaderLeadingCell(kind: .index(showing: false)) {
                    withAnimation(Theme.Motion.state) { indexColumn.wrappedValue = .all }
                }
                Spacer(minLength: 0)
            }
            .frame(height: Theme.Metric.hitTarget + Theme.Metric.grid * 2)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Hairline() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel("NO SESSION")
            Text("LANDLINE")
                .llTitle()
                .padding(.top, Theme.Metric.grid * 2)
            // The one tick scale on this screen, marking the block as the
            // primary region the way the index's scale marks the index. Short
            // on purpose: run edge to edge it stops being a scale mark and
            // becomes a dotted rule, and DESIGN.md's whole point about this
            // device is that its scarcity is what makes it read.
            TickScale(edge: .horizontal)
                .frame(width: Theme.Metric.tickSpacing * 8, alignment: .leading)
                .padding(.top, Theme.Metric.grid * 3)
            proseText("A real terminal on the machines you already own, reached over your own tailnet. No hosted service, no account, no open port.")
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Metric.grid * 4)
        }
    }

    private var next: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline().padding(.top, Theme.Metric.grid * 6)
            step(label: "SELECT",
                 text: "Choose a machine in the index. Landline attaches to the session it left running there, or starts one.")
            Hairline()
            step(label: "KEEP",
                 text: "The session outlives the connection. Switch machines, lock the iPad, change networks: the shell on the far end keeps running.")
            Hairline()
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline().padding(.top, Theme.Metric.grid * 6)
            step(label: "01",
                 command: "landlined",
                 text: "The daemon runs on the machine and binds loopback only.")
            Hairline()
            step(label: "02",
                 command: "tailscale serve --bg --https=443 http://127.0.0.1:7777",
                 text: "Tailscale terminates TLS and proves who is calling.")
            Hairline()
            step(label: "03",
                 text: "Add the machine with + HOST in the index, using the tailnet name `tailscale status` prints.")
            Hairline()
        }
    }

    private func step(label: String, command: String? = nil, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Metric.grid * 4) {
            MicroLabel(label, color: Theme.accent)
                // A measured label column, so the sentences all start on the
                // same vertical rule.
                .frame(width: 56, alignment: .leading)
                .llMeasuredColumn()
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
                if let command {
                    Text(command)
                        .llValue(Theme.inkBright)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                proseText(text)
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Metric.grid * 4)
    }
}
