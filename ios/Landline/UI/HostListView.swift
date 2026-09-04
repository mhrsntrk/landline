import SwiftUI
import LocalAuthentication

// The index of machines. A dense, measured, labelled drawing, not a stack of
// cards: rows are full bleed and delimited by hairlines, every machine value is
// mono with tabular figures, and the columns line up down the page.

struct HostListView: View {
    /// Non-nil when this view is a split view's sidebar: choosing a host sets
    /// the selection the detail pane reads instead of pushing a screen, and the
    /// chosen row stays marked because it is still on screen beside its
    /// terminal. Nil is the stack, which is every phone.
    var selection: Binding<UUID?>?
    /// The settings route, in the shape the split view needs. In the stack this
    /// view still owns its own push.
    var settingsPresented: Binding<Bool>?

    @Environment(HostStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// The sidebar of a split view, rather than the root of a stack. Named
    /// rather than tested inline, because it changes four separate decisions on
    /// this screen and each of them should say which one it is answering.
    private var isSidebar: Bool { selection != nil }

    @State private var reachability = HostReachability()
    @State private var editingHost: Host?
    @State private var showingAddSheet = false
    @State private var openedHost: Host?
    @State private var authError: String?
    /// Drives the session-age column so the figures stay honest while the
    /// screen is open. Tabular by construction, so nothing shifts when it ticks.
    @State private var now = Date()
    /// Where the filled rows stop, so the ruling can carry on from there.
    @State private var extent = IndexExtent()
    /// The app-wide settings push. Its own route type rather than a `Bool`, so
    /// it can share the stack with `openedHost` without the two colliding.
    @State private var settingsRoute: SettingsRoute?

    private enum SettingsRoute: String, Hashable { case settings }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.hosts.isEmpty {
                // In the split the detail pane is already teaching the
                // mechanism at a readable measure, so the 300pt column does not
                // print the same two shell commands a second time in a ribbon.
                EmptyIndexView(dense: isSidebar) { showingAddSheet = true }
            } else {
                index
            }
        }
        .background(Theme.ground)
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(Theme.ground, for: .navigationBar)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingAddSheet) {
            HostEditView(host: Host()) { newHost, secret in
                store.add(newHost)
                persistSecret(secret, for: newHost)
                reachability.probe([newHost])
            }
        }
        .sheet(item: $editingHost) { host in
            HostEditView(host: host) { updated, secret in
                store.update(updated)
                persistSecret(secret, for: updated)
                reachability.probe([updated])
            }
        }
        // The stack's own pushes. A sidebar never sets either route — it writes
        // the selection binding instead, and the detail pane is the destination
        // — so both stay nil there and neither push can fire.
        .navigationDestination(item: $openedHost) { host in
            TerminalScreen(host: host)
        }
        .navigationDestination(item: $settingsRoute) { _ in SettingsView() }
        .alert("Face ID could not unlock this host", isPresented: .init(
            get: { authError != nil },
            set: { if !$0 { authError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authError ?? "")
        }
        .task {
            DemoSeed.seedIfRequested(into: store)
            if DemoSeed.opensEditor, let first = store.hosts.first { editingHost = first }
            // The two screenshot hooks that name a *route* are the stack's. In a
            // split view `RootView` drives the same two, because there the
            // destination is the detail pane and the sheet, not a push.
            if !isSidebar {
                if DemoSeed.opensTerminal, let first = store.hosts.first { openedHost = first }
                if DemoSeed.opensSettings { settingsRoute = .settings }
            }
            reachability.probe(store.hosts)
            // 30s is finer than the coarsest unit the age column prints, so the
            // number is never stale by more than one glyph.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reachability.probe(store.hosts) }
        }
    }

    // MARK: - Header
    //
    // Not a stock large title: a mono title plus a micro-caps annotation line
    // that counts what the drawing shows. The screen's one tick scale sits
    // directly under it and marks the index as the live region.

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.Metric.grid * 2) {
                Text("LANDLINE")
                    .llTitle()
                    .lineLimit(1)
                Spacer(minLength: Theme.Metric.grid * 2)
                if !store.hosts.isEmpty {
                    Button("RECHECK") { reachability.probe(store.hosts) }
                        .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                }
                Button("+ HOST") { showingAddSheet = true }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
            }
            // The app-wide settings live on the annotation line rather than in
            // the title row. Three bordered controls beside a 20pt title wrap
            // "LANDLINE" onto two lines on the narrowest phone this app
            // supports, and a header that breaks its own title is not a header.
            // The annotation register was empty to the right, it is already the
            // line that states facts about the whole screen rather than acting
            // on one row, and `›` is the mark this world already uses for "there
            // is a screen behind this" (see `SummaryRow`).
            HStack(alignment: .lastTextBaseline, spacing: Theme.Metric.grid * 2) {
                MicroLabel(countsAnnotation)
                    .llMeasuredColumn()
                    .animation(Theme.Motion.state, value: countsAnnotation)
                Spacer(minLength: Theme.Metric.grid * 2)
                settingsControl
            }
            .padding(.top, Theme.Metric.grid)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, Theme.Metric.grid * 3)
        .padding(.bottom, Theme.Metric.grid)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Hairline() }
        .overlay(alignment: .bottomLeading) {
            // The one tick scale on this screen (DESIGN.md: at most one).
            // Inside the header's own bounds: anything offset past the edge is
            // painted over by the next view's ground.
            TickScale(edge: .horizontal)
                .padding(.leading, Theme.Metric.gutter)
        }
    }

    /// Annotation grammar, not a button: micro-caps and the `›` mark, with no
    /// border, because it states where something is rather than acting on this
    /// screen. It still carries a full 44pt target, taken out of the header's
    /// own padding so the strip does not grow to hold it.
    private var settingsControl: some View {
        Button {
            if let settingsPresented {
                settingsPresented.wrappedValue = true
            } else {
                settingsRoute = .settings
            }
        } label: {
            // No `MicroLabel` and no `llValue` here: both set their own colour,
            // which would win over the style's and leave the control with no
            // pressed state at all.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.grid) {
                Text("SETTINGS").font(.llMicroLabel).tracking(0.8)
                Text("\u{203A}").font(.llValue)
            }
            .llMeasuredColumn()
            .padding(.vertical, Theme.Metric.grid * 3)
            .padding(.leading, Theme.Metric.grid * 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(AnnotationControlStyle())
        .accessibilityLabel(Text("app settings"))
    }

    private var countsAnnotation: String {
        let total = store.hosts.count
        let reachable = store.hosts.filter { reachability.level(for: $0) == .connected }.count
        let hostWord = total == 1 ? "HOST" : "HOSTS"
        return "\(total) \(hostWord) / \(reachable) REACHABLE"
    }

    // MARK: - Index

    private var index: some View {
        List {
            ForEach(store.hosts) { host in
                Button {
                    open(host)
                } label: {
                    HostRow(host: host,
                            level: reachability.level(for: host),
                            now: now,
                            dense: isSidebar)
                        .background { extentReporter }
                }
                .buttonStyle(InstrumentRowButtonStyle(selected: isSelected(host)))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.ground)
                .overlay(alignment: .bottom) { Hairline() }
                .contextMenu {
                    Button("Open") { open(host) }
                    Button("Edit") { editingHost = host }
                    Button("Delete", role: .destructive) { store.delete(host) }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        store.delete(host)
                    } label: {
                        Text("DELETE")
                    }
                    Button {
                        editingHost = host
                    } label: {
                        Text("EDIT")
                    }
                    .tint(Theme.raised)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Order matters: the ruling sits directly behind the list, the ground
        // behind the ruling. Filled rows paint over their own share of it, so
        // only the unused slots below the last host are ever visible.
        .background { IndexRuling(extent: extent) }
        .background(Theme.ground)
        .environment(\.defaultMinListRowHeight, Theme.Metric.rowHeight)
        .onPreferenceChange(IndexExtentKey.self) { extent = $0 }
    }

    /// Reports where the drawn rows end, so the blank slots below can pick the
    /// row rhythm up exactly where it stops.
    ///
    /// Screen coordinates, not a named space: List hosts each row in its own
    /// UIKit cell, and a `.named` space declared on the List does not resolve
    /// from inside one. It silently falls back to global and the ruling lands a
    /// header's worth too low, which is exactly the bug this comment prevents.
    private var extentReporter: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(
                key: IndexExtentKey.self,
                value: IndexExtent(bottom: frame.maxY, pitch: frame.height)
            )
        }
    }

    // MARK: - Actions

    private func isSelected(_ host: Host) -> Bool {
        selection?.wrappedValue == host.id
    }

    /// Opening means "push a terminal" in the stack and "point the detail pane
    /// at this machine" in the split. One function, so the Face ID gate in
    /// front of it cannot be right in one shape and missing in the other.
    private func reveal(_ host: Host) {
        if let selection {
            selection.wrappedValue = host.id
        } else {
            openedHost = host
        }
    }

    private func open(_ host: Host) {
        guard host.requireFaceID else {
            reveal(host)
            return
        }
        // Client-side and therefore cosmetic (SCOPE.md 8); the unlock secret
        // is the real gate.
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authError = error?.localizedDescription ?? "Face ID is unavailable on this phone. Turn Face ID off for this host to open it with the unlock secret instead."
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock \(host.displayName)"
        ) { success, evalError in
            DispatchQueue.main.async {
                if success {
                    reveal(host)
                } else if let evalError {
                    authError = evalError.localizedDescription
                }
            }
        }
    }

    private func persistSecret(_ secret: String?, for host: Host) {
        guard let secret else { return } // untouched
        if secret.isEmpty {
            try? Keychain.deleteUnlockSecret(hostID: host.id)
        } else {
            try? Keychain.setUnlockSecret(secret, hostID: host.id)
        }
    }
}

/// A control drawn in the annotation register: no border, the label brightens
/// on press. `InstrumentButtonStyle` is the same world but draws a box, and a
/// third box in a header is what pushed the title onto two lines.
private struct AnnotationControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.inkBright : Theme.inkMuted)
            .animation(Theme.Motion.state, value: configuration.isPressed)
    }
}

// MARK: - Ruled empty slots
//
// A technical plate does not stop halfway down the sheet, and a ledger does not
// stop ruling once the entries run out: the blank lines are part of the form.
// Three hosts used to leave most of the screen as bare ground, which read as an
// unfinished drawing rather than as an index with room in it. So the row rhythm
// carries on to the bottom edge in the same 0.5pt `rule`, at the pitch the last
// filled row actually measured, so the spacing never breaks at the handover.
//
// This is deliberately only hairlines: no ticks, no registration marks, no
// placeholder glyphs. Their scarcity is what makes them read as instrument
// marking (DESIGN.md), and an empty slot has nothing to annotate.

private struct IndexExtent: Equatable {
    /// Bottom of the deepest filled row, in screen coordinates.
    var bottom: CGFloat = 0
    /// That row's height, which is the rhythm to continue.
    var pitch: CGFloat = 0
}

private struct IndexExtentKey: PreferenceKey {
    static let defaultValue = IndexExtent()

    static func reduce(value: inout IndexExtent, nextValue: () -> IndexExtent) {
        let next = nextValue()
        if next.bottom > value.bottom { value = next }
    }
}

private struct IndexRuling: View {
    @Environment(\.displayScale) private var displayScale
    let extent: IndexExtent

    var body: some View {
        GeometryReader { proxy in
            // The rows report in screen coordinates, so convert into this
            // view's own space before drawing.
            let start = extent.bottom - proxy.frame(in: .global).minY
            let pitch = max(extent.pitch, Theme.Metric.rowHeight)
            Canvas { context, size in
                // Nothing measured yet, or the hosts already fill the viewport
                // and the list scrolls: either way there is no unused sheet.
                guard extent.bottom > 0, start > 0, start < size.height else { return }
                let weight = 1 / displayScale
                var y = start + pitch
                while y < size.height {
                    context.fill(
                        Path(CGRect(x: 0, y: y - weight, width: size.width, height: weight)),
                        with: .color(Theme.rule)
                    )
                    y += pitch
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Row

private struct HostRow: View {
    let host: Host
    let level: StatusSquare.Level
    let now: Date
    /// The sidebar column, at roughly two thirds of the width the same row gets
    /// on a phone once its gutters are paid. See the `Lines` note below for
    /// what that costs and why.
    var dense: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metric.grid * 3) {
            StatusSquare(level: level)
                // Optically aligned with the cap height of the name line.
                .padding(.top, Theme.Metric.grid + 2)
            VStack(alignment: .leading, spacing: Theme.Metric.grid + 2) {
                nameLine
                endpointLine
                if dense { denseFlags }
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, Theme.Metric.grid * 3)
        .frame(minHeight: Theme.Metric.rowHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(host.displayName), \(host.hostname), \(level.label)"))
    }

    // MARK: Lines
    //
    // Two layouts, on purpose, because the row is asked to hold the same facts
    // at two very different widths.
    //
    // A phone gives this row about 430pt and it spends them on two lines of
    // four columns. The sidebar gives it 300 to 380pt, of which the gutters and
    // the status square take 54, and at that width the phone's arrangement does
    // not compress, it *lies*: the shell column and the age column squeeze the
    // hostname to a stub, and a line reading `…4f1a.ts.net:443` beside
    // `…w -A -s main` tells you nothing about any machine. Truncating every
    // column equally is not a narrow layout, it is a wide layout that has
    // stopped working.
    //
    // So the sidebar drops a column and stacks the rest. The shell leaves the
    // value line and joins the flags as a micro-caps mark, where it costs three
    // glyphs instead of a 52pt column. The startup command stops being echoed:
    // it is the longest string the row can hold, it is the one fact here that
    // is a *setting* rather than a state, and the host editor already prints
    // it, so `CMD` stays as the presence mark, which is what a glance actually
    // asks. What keeps its full width is the name, the endpoint and the age,
    // which are the three facts a machine is picked by.

    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.grid * 2) {
            Text(host.displayName)
                .llValueStrong()
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Metric.grid * 2)
            if !dense {
                Text(host.shellLabel)
                    .llValue(Theme.ink)
                    .frame(width: 52, alignment: .trailing)
            }
            Text(host.sessionAgeLabel(now: now))
                .llValue(Theme.inkMuted)
                .frame(width: 32, alignment: .trailing)
        }
        // The right-hand columns are a measured scale; letting them grow with
        // Dynamic Type would wrap them and destroy the alignment that makes
        // this read as one drawing. Capped on purpose; the name and the
        // annotations below still scale.
        .llMeasuredColumn()
    }

    private var endpointLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.grid * 2) {
            // String(port), not "\(port)": SwiftUI's localized
            // interpolation would group the digits and print 8.443.
            Text("\(host.hostname):" + String(host.port))
                .llValue(Theme.inkMuted)
                .lineLimit(1)
                .truncationMode(.head)
            if !dense {
                Spacer(minLength: Theme.Metric.grid * 2)
                flags
            }
        }
    }

    /// The sidebar's own line: every remaining fact reduced to a mark, in a
    /// fixed order left to right, so the column reads down the page as a set of
    /// ticked boxes rather than as four ragged fragments.
    private var denseFlags: some View {
        HStack(spacing: Theme.Metric.grid * 3) {
            MicroLabel(HostRow.shellMark(host.shellLabel))
            if !host.startCommand.isEmpty { MicroLabel("CMD") }
            if host.requireFaceID { MicroLabel("FACE ID") }
            MicroLabel(host.useTLS ? "TLS" : "PLAIN", color: host.useTLS ? Theme.inkMuted : Theme.warn)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .llMeasuredColumn()
        .padding(.top, Theme.Metric.grid)
    }

    /// The shell as a flag rather than as a column. `Host.shellLabel` prints an
    /// em dash when the daemon has not said yet, and a bare dash in a row of
    /// words reads as a missing glyph rather than as a fact.
    static func shellMark(_ shellLabel: String) -> String {
        shellLabel == "\u{2014}" ? "NO SHELL" : shellLabel.uppercased()
    }

    /// The phone's flag cluster: the startup command echoed in full, because
    /// there is room for it.
    @ViewBuilder
    private var flags: some View {
        HStack(spacing: Theme.Metric.grid * 2) {
            if !host.startCommand.isEmpty {
                HStack(spacing: Theme.Metric.grid) {
                    MicroLabel("CMD")
                    // The command itself is a machine value: same 10pt mono as
                    // the annotation beside it, but never uppercased, because
                    // shell commands are case sensitive.
                    Text(host.startCommand)
                        .llMicroLabel(Theme.ink)
                        .lineLimit(1)
                }
            }
            if host.requireFaceID {
                MicroLabel("FACE ID")
            }
            MicroLabel(host.useTLS ? "TLS" : "PLAIN", color: host.useTLS ? Theme.inkMuted : Theme.warn)
        }
        .llMeasuredColumn()
    }
}

// MARK: - Empty state
//
// The first-run screen, and therefore the one that has to teach the mechanism:
// a host only exists here once the daemon runs on the machine and
// `tailscale serve` fronts it. Sentences are SF Pro, commands are mono.

private struct EmptyIndexView: View {
    /// The sidebar column. The detail pane beside it is already printing the
    /// setup, so this reduces to the one thing the column is for.
    var dense: Bool = false
    let addHost: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.grid * 5) {
                MicroLabel("NO HOSTS")

                Text(dense
                     ? "Nothing in the index yet. The pane beside this one says what has to be running on the machine first."
                     : "Landline reaches machines you already own, over your own tailnet. A machine appears here once two things are true on it.")
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)

                if !dense {
                    fullSetup
                    proseText("Then add the machine's tailnet name, the `\(Host.tailnetExample)` shape that `tailscale status` prints.")
                        .llProse()
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("+ ADD HOST", action: addHost)
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.top, Theme.Metric.grid * 6)
            .padding(.bottom, Theme.Metric.grid * 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.ground)
    }

    private var fullSetup: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 4) {
            command(
                step: "01",
                text: "landlined",
                note: "The daemon runs on the machine and binds loopback only."
            )
            Hairline()
            command(
                step: "02",
                text: "tailscale serve --bg --https=443 http://127.0.0.1:7777",
                note: "Tailscale terminates TLS and proves who is calling. No open port, no SSH key."
            )
        }
        .padding(.vertical, Theme.Metric.grid * 4)
        .padding(.horizontal, Theme.Metric.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
        // Two opposite corners only. Four would read as a frame, and a
        // frame is a card with the fill removed.
        .overlay { RegistrationMarks(diagonal: .topLeadingBottomTrailing) }
        // Cancels the page gutter: a region here is bounded by rules
        // running edge to edge, never by an inset rectangle.
        .padding(.horizontal, -Theme.Metric.gutter)
    }

    private func command(step: String, text: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.grid * 2) {
                MicroLabel(step, color: Theme.accent)
                    .llMeasuredColumn()
                Text(text)
                    .llValue(Theme.inkBright)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            proseText(note)
                .llProse()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Reachability
//
// The daemon is the source of truth, so this asks it rather than guessing: one
// HTTP request to the same origin the WebSocket uses. Any answer at all, even a
// 400 because the request was not an upgrade, proves the machine is up and
// `tailscale serve` is in front of it. A transport failure means it is not.

@Observable
final class HostReachability {
    private(set) var levels: [UUID: StatusSquare.Level] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func level(for host: Host) -> StatusSquare.Level {
        levels[host.id] ?? .offline
    }

    func probe(_ hosts: [Host]) {
        if let scripted = DemoSeed.scriptedLevels(for: hosts) {
            levels = scripted
            return
        }
        for host in hosts where !host.hostname.isEmpty {
            levels[host.id] = .connecting
            Task { [weak self] in
                let level = await Self.probeOne(host: host, session: self?.session ?? .shared)
                await MainActor.run { self?.levels[host.id] = level }
            }
        }
    }

    private static func probeOne(host: Host, session: URLSession) async -> StatusSquare.Level {
        var request = URLRequest(url: host.httpURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        do {
            _ = try await session.data(for: request)
            return .connected
        } catch let error as URLError {
            // An HTTP error response is still an answer; only transport
            // failures mean unreachable.
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .timedOut,
                 .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
                return .offline
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return .failed
            default:
                return .offline
            }
        } catch {
            return .offline
        }
    }
}

// MARK: - Demo seeding
//
// Screenshot and layout scaffolding only. Compiled out of release builds, and
// even in debug it does nothing unless LANDLINE_DEMO is set in the environment,
// so a real install can never grow hosts it was not given.

enum DemoSeed {
    private static var mode: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LANDLINE_DEMO"]
        #else
        return nil
        #endif
    }

    /// Debug screenshot hook: open the edit sheet straight away, since a
    /// screenshot run has no fingers.
    static var opensEditor: Bool { mode == "edit" || mode == "editbottom" || showsValidation }

    /// Debug screenshot hook: land the edit sheet at its bottom, since a
    /// screenshot run cannot scroll either.
    static var scrollsToBottom: Bool { mode == "editbottom" }

    /// Debug screenshot hook: seed a host that fails validation and open the
    /// sheet with the errors already showing, so the error styling can be
    /// looked at rather than reasoned about.
    static var showsValidation: Bool { mode == "editerror" }

    /// Debug hook for the split view's resize path, which is the one thing on
    /// an iPad that cannot be checked from a single still: hide the index
    /// column a few seconds in and show it again a few seconds after that, so
    /// two screenshots of the *same running session* can be compared. The
    /// header's `GEOM` readout is written only by `TerminalController.onResize`,
    /// which is the same closure that sends the RESIZE frame, so a `GEOM` that
    /// changed between the two stills is proof the daemon was told.
    static var togglesIndex: Bool { mode == "resize" || mode == "liveresize" }

    /// Debug hook: seed a first host pointing at a `landlined` built with the
    /// `harness` feature and running on this machine, so a screenshot can hold
    /// a real attached session instead of a CLOSED band. Deliberately not port
    /// 7777: that is where a real daemon listens, and a screenshot run has no
    /// business connecting to it.
    static var seedsLiveHost: Bool {
        mode == "live" || mode == "liveresize" || mode == "liveleader" || switchesHosts
    }

    /// Debug hook: attach, point the detail pane at a different machine, then
    /// point it back, so two stills of the same run can be compared. A session
    /// the switch *detached* rather than killed comes back with the same `SESS`
    /// and a still-running age.
    static var switchesHosts: Bool { mode == "liveswitch" }

    /// Debug screenshot hooks for the key bar work: park the run on the
    /// terminal (optionally with the leader already armed), or on one of the
    /// app-wide settings screens, each of which auto-pushes the next.
    static var opensTerminal: Bool {
        mode == "terminal" || armsLeader || togglesIndex || seedsLiveHost
    }
    /// `liveleader` is `live` with the leader latch already down, so a still can
    /// hold the armed key bar over a session that is genuinely attached rather
    /// than over a CLOSED band.
    static var armsLeader: Bool { mode == "leaderarmed" || mode == "liveleader" }
    static var opensSettings: Bool { mode == "settings" || opensKeyBar }
    static var opensKeyBar: Bool { mode == "keybar" || opensCustomKey || opensCatalog }
    static var opensCatalog: Bool { mode == "catalog" }
    static var opensCustomKey: Bool { mode == "customkey" || mode == "customkeybad" }

    /// Debug screenshot hook: prefill the custom key editor with a sequence
    /// that parses, or with one that does not, so the refusal can be looked at
    /// rather than reasoned about.
    static var customKeySeed: (label: String, sequence: String)? {
        switch mode {
        case "customkey": return ("^W", "\\e[1;5D")
        case "customkeybad": return ("^W", "\\e[1;5\\q")
        default: return nil
        }
    }

    /// Debug screenshot hook: the machines a store frame of the index needs and
    /// a layout check does not. Three rows leave two thirds of a phone screen
    /// empty, which reads as an app with nothing in it rather than as an index,
    /// so `index` and `fullindex` seed a plausible tailnet on top of the three
    /// every other mode gets. Empty for every other mode, so no existing run
    /// changes shape.
    private static var extraHosts: [Host] {
        #if DEBUG
        guard mode == "index" || mode == "fullindex" else { return [] }
        let more: [(String, String, UInt16, String, TimeInterval)] = [
            ("edge", "edge.tail4f1a.ts.net", 443, "/bin/bash", -4 * 3600),
            ("nas", "nas.tail4f1a.ts.net", 443, "/bin/zsh", -3 * 86_400),
            ("builder", "builder.tail4f1a.ts.net", 443, "/bin/zsh", -5 * 3600),
            ("pi", "pi.tail4f1a.ts.net", 443, "/bin/bash", -6 * 86_400),
            ("vps", "vps.tail4f1a.ts.net", 8443, "/usr/bin/fish", -9 * 3600),
        ]
        return more.map { name, hostname, port, shell, age in
            var host = Host()
            host.name = name
            host.hostname = hostname
            host.port = port
            host.lastShell = shell
            host.lastAttachedAt = Date().addingTimeInterval(age)
            return host
        }
        #else
        return []
        #endif
    }

    static func seedIfRequested(into store: HostStore) {
        #if DEBUG
        guard mode != nil, mode != "empty", store.hosts.isEmpty else { return }
        var one = Host()
        // One name in both shapes: a store screenshot of a live session prints
        // this in the header band, and "harness" reads as scaffolding there.
        one.name = "studio"
        // A live seed keeps the tailnet name and port it prints; where it
        // actually dials is `LANDLINE_DEMO_ENDPOINT` (see `Host.demoEndpoint`),
        // because the iPad header band prints `ENDPOINT` and a store frame of a
        // Tailscale client may not advertise a loopback address.
        one.hostname = showsValidation ? "https://studio tail4f1a" : "studio.tail4f1a.ts.net"
        one.port = showsValidation ? 0 : 443
        one.useTLS = !showsValidation
        // A live run starts tmux for real, because tmux redrawing itself is the
        // half of the resize path that lives on the far end.
        // The index frames drop it: the row prints the whole command as a flag,
        // and at phone width that pushes the endpoint into a head-truncated
        // stub, which is two ellipses on one line and reads as a broken layout
        // rather than as a machine.
        one.startCommand = seedsLiveHost ? "tmux new -A -s landline"
            : (extraHosts.isEmpty ? "tmux new -A -s main" : "")
        one.leaderKey = "C-a"
        one.lastShell = "/bin/zsh"
        one.lastAttachedAt = Date().addingTimeInterval(-14 * 60)
        var two = Host()
        two.name = "macbook"
        two.hostname = "macbook.tail4f1a.ts.net"
        two.requireFaceID = true
        two.lastShell = "/bin/zsh"
        two.lastAttachedAt = Date().addingTimeInterval(-3 * 3600)
        var three = Host()
        three.name = "rack"
        three.hostname = "rack.tail4f1a.ts.net"
        three.port = 8443
        three.lastShell = "/usr/bin/fish"
        three.lastAttachedAt = Date().addingTimeInterval(-2 * 86_400)
        for host in [one, two, three] { store.add(host) }
        for host in extraHosts { store.add(host) }
        #endif
    }

    /// Fixed status squares so the screenshots show all three states without
    /// pretending a simulator can reach a real tailnet.
    static func scriptedLevels(for hosts: [Host]) -> [UUID: StatusSquare.Level]? {
        #if DEBUG
        // A live run probes for real: the whole point of it is that the status
        // square and the session are telling the truth.
        guard mode != nil, mode != "empty", !seedsLiveHost else { return nil }
        let script: [StatusSquare.Level] = [.connected, .connected, .offline]
        var result: [UUID: StatusSquare.Level] = [:]
        for (index, host) in hosts.enumerated() {
            result[host.id] = script[index % script.count]
        }
        return result
        #else
        return nil
        #endif
    }
}
