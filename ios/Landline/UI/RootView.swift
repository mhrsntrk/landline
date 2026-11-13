import SwiftUI

// Where the app decides what shape it is.
//
// Two structures, chosen by horizontal size class and the window's measured
// width, never by device idiom:
//
//   compact  a pushed stack. Every iPhone, and an iPad in a narrow Split View
//            or Slide Over, which is a phone-shaped window and must behave like
//            one rather than growing a 320pt sidebar inside a 320pt window.
//
//   regular  a two-column split. The index is a persistent sidebar and the
//            terminal fills the detail pane, so a wide screen shows both and
//            changing machines is one tap that never takes the terminal away.
//
// A regular window narrower than `NavigationMode.minimumSplitWidth` is a stack
// too. iPhone Duo held open in portrait is regular and 669pt wide, and there
// SwiftUI will not draw a balanced split: it floats the index over the terminal
// and dims the session, the one thing this layout exists to prevent.
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
    @State private var hinge = HingeObserver()

    var body: some View {
        // Measured rather than inferred: the size class alone cannot tell a
        // 669pt regular window from a 1032pt one. The rule reads the full
        // window, safe areas added back, because the crease is a property of
        // the glass: the midline of a safe-area-inset frame is not where the
        // fold is. The reader itself keeps the safe area, so every page still
        // clears the status bar and the home indicator.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let window = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                                height: proxy.size.height + insets.top + insets.bottom)
            content(NavigationMode(horizontalSizeClass,
                                   width: window.width,
                                   height: window.height,
                                   hinge: hinge.posture,
                                   fillsScreen: hinge.windowFillsScreen),
                    insets: insets)
        }
        .background(HingeProbe(observer: hinge).accessibilityHidden(true))
    }

    private func content(_ mode: NavigationMode, insets: EdgeInsets) -> some View {
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
            case .folio(let folio):
                pages(folio, insets: insets)
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
        .withSplitBehaviour(self)
    }

    // MARK: - Folio
    //
    // Two pages this app lays out itself, for a window on a fold. Not
    // `NavigationSplitView`: it cannot be told where to put its seam, and below
    // 700pt it stops drawing a split at all and floats the index over the
    // terminal. Here the seam goes exactly where the folio says, which on a
    // half-open device is the crease, so no row of the terminal and no row of
    // the index is ever drawn across the fold.
    //
    // The index page is the same sidebar the system split uses, in its own
    // stack so its session list can still push. The terminal's index toggle
    // works unchanged: it writes `columnVisibility`, and a hidden index gives
    // the terminal the whole window.

    @ViewBuilder
    private func pages(_ folio: Folio, insets: EdgeInsets) -> some View {
        let indexShown = columnVisibility != .detailOnly
        Group {
            switch folio.axis {
            case .sideBySide:
                HStack(spacing: 0) {
                    if indexShown {
                        // `indexLength` is measured from the window's edge;
                        // this frame starts at the safe area's.
                        indexPage
                            .frame(width: max(0, folio.indexLength - insets.leading))
                            .overlay(alignment: .trailing) { Seam(axis: .vertical) }
                            .transition(.move(edge: .leading))
                    }
                    detailPage
                }
            case .stacked:
                VStack(spacing: 0) {
                    detailPage
                        .frame(height: indexShown ? max(0, folio.indexLength - insets.top) : nil)
                    if indexShown {
                        indexPage
                            .overlay(alignment: .top) { Seam(axis: .horizontal) }
                            .transition(.move(edge: .bottom))
                    }
                }
                // Laptop posture: the software keyboard rises over the bottom
                // page, which is the index. Letting it push the pages up would
                // slide the terminal down across the crease, so the pages hold
                // still and the terminal's key bar stays on the top page, just
                // above the fold.
                .ignoresSafeArea(.keyboard, edges: indexShown ? .bottom : [])
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .withSplitBehaviour(self)
    }

    private var indexPage: some View {
        NavigationStack {
            HostListView(selection: $selection, settingsPresented: $showingSettings)
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var detailPage: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel.ignoresSafeArea())
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
enum NavigationMode: Equatable {
    /// A pushed stack. Compact width, whatever the device is.
    case stack
    /// A persistent index beside the terminal. Regular width.
    case split
    /// Two pages laid out by this app rather than by `NavigationSplitView`,
    /// for a window on a fold. See `Folio`.
    case folio(Folio)

    /// The narrowest window that gets the split. Below it SwiftUI overlays
    /// the index on the terminal instead of setting them side by side. 700pt
    /// sends iPhone Duo open in portrait (669pt) away from the split and keeps
    /// every iPad full-screen window, iPad mini's 744pt portrait included, on
    /// the split it already had.
    static let minimumSplitWidth: CGFloat = 700

    /// The index column when the app draws the split itself in a narrow
    /// window. Narrower than the system split's 300pt so the terminal keeps
    /// about fifty columns at 13pt beside it on a 669pt window.
    static let narrowIndexWidth: CGFloat = 272

    /// - Parameters:
    ///   - hinge: the fold's posture, `nil` on hardware without one.
    ///   - fillsScreen: whether the window covers its screen, which is what
    ///     puts the crease on the window's midline.
    init(_ horizontalSizeClass: UserInterfaceSizeClass?,
         width: CGFloat? = nil,
         height: CGFloat? = nil,
         hinge: HingePosture? = nil,
         fillsScreen: Bool = false) {
        // nil is the state SwiftUI reports before a window has been measured.
        // Compact is the safe answer: a stack laid out in a wide window looks
        // sparse for one frame, a split laid out in a narrow one has no room
        // for either column.
        guard horizontalSizeClass == .regular else { self = .stack; return }

        // Half open and filling the inner display: the crease is a physical
        // edge across the middle of the window, and nothing should sit on it.
        // The index takes one page and the terminal the other.
        if hinge == .partial, fillsScreen, let width, let height {
            self = .folio(width >= height
                ? Folio(axis: .sideBySide, indexLength: width / 2)
                : Folio(axis: .stacked, indexLength: height / 2))
            return
        }

        if let width, width < Self.minimumSplitWidth {
            // A hinged device open flat in portrait has the room for an index
            // beside the terminal; SwiftUI's split just will not draw one
            // there. Anything else this narrow keeps the stack.
            self = hinge == nil || hinge == .closed
                ? .stack
                : .folio(Folio(axis: .sideBySide, indexLength: Self.narrowIndexWidth))
        } else {
            self = .split
        }
    }
}

/// How two pages share a window.
struct Folio: Equatable {
    enum Axis: Equatable {
        /// Index on the leading page, terminal on the trailing one.
        case sideBySide
        /// Terminal on the top page, index on the bottom one: laptop posture,
        /// where the bottom page lies flat under your thumbs like a keyboard
        /// deck and the top page stands up facing you.
        case stacked
    }

    let axis: Axis
    /// The index page's width for `.sideBySide`, the terminal page's height
    /// for `.stacked`. In both cases, half the window puts the seam on the
    /// crease.
    let indexLength: CGFloat
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
            ForEach(HostSetup.steps, id: \.label) { setupStep in
                step(label: setupStep.label, command: setupStep.command, text: setupStep.note)
                Hairline()
            }
            ShareLink(item: HostSetup.shareText) {
                Text("SEND SETUP TO YOUR COMPUTER")
            }
            .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
            .padding(.vertical, Theme.Metric.grid * 4)
            Hairline()
            step(label: "04",
                 text: "Add the machine with + HOST in the index, using the tailnet name `landlined doctor` prints.")
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

// MARK: - Behaviour shared by both two-pane shapes

extension View {
    /// The settings sheet, the remembered index preference and the demo hooks,
    /// which the system split and the folio both need.
    fileprivate func withSplitBehaviour(_ root: RootView) -> some View {
        root.splitBehaviour(self)
    }
}

extension RootView {
    fileprivate func splitBehaviour<Content: View>(_ content: Content) -> some View {
        content
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
}

/// The rule drawn on a folio's seam. A hairline in `rule`, like every other
/// division in this app: the crease is already a visible edge on the glass,
/// and the drawing should agree with it rather than decorate it.
private struct Seam: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.rule)
            .frame(width: axis == .vertical ? 1 / displayScale : nil,
                   height: axis == .horizontal ? 1 / displayScale : nil)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
