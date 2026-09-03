import SwiftUI
import LocalAuthentication

// The index of machines. A dense, measured, labelled drawing, not a stack of
// cards: rows are full bleed and delimited by hairlines, every machine value is
// mono with tabular figures, and the columns line up down the page.

struct HostListView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var reachability = HostReachability()
    @State private var editingHost: Host?
    @State private var showingAddSheet = false
    @State private var openedHost: Host?
    @State private var authError: String?
    /// Drives the session-age column so the figures stay honest while the
    /// screen is open. Tabular by construction, so nothing shifts when it ticks.
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.hosts.isEmpty {
                EmptyIndexView { showingAddSheet = true }
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
        .navigationDestination(item: $openedHost) { host in
            TerminalScreen(host: host)
        }
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
                Spacer(minLength: Theme.Metric.grid * 2)
                if !store.hosts.isEmpty {
                    Button("RECHECK") { reachability.probe(store.hosts) }
                        .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                }
                Button("+ HOST") { showingAddSheet = true }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
            }
            MicroLabel(countsAnnotation)
                .padding(.top, Theme.Metric.grid * 2)
                .llMeasuredColumn()
                .animation(Theme.Motion.state, value: countsAnnotation)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, Theme.Metric.grid * 3)
        .padding(.bottom, Theme.Metric.grid * 3)
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
                    HostRow(host: host, level: reachability.level(for: host), now: now)
                }
                .buttonStyle(InstrumentRowButtonStyle())
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
        .background(Theme.ground)
        .environment(\.defaultMinListRowHeight, Theme.Metric.rowHeight)
    }

    // MARK: - Actions

    private func open(_ host: Host) {
        guard host.requireFaceID else {
            openedHost = host
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
                    openedHost = host
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

// MARK: - Row

private struct HostRow: View {
    let host: Host
    let level: StatusSquare.Level
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metric.grid * 3) {
            StatusSquare(level: level)
                // Optically aligned with the cap height of the name line.
                .padding(.top, Theme.Metric.grid + 2)
            VStack(alignment: .leading, spacing: Theme.Metric.grid + 2) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.grid * 2) {
                    Text(host.displayName)
                        .llValueStrong()
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Metric.grid * 2)
                    Text(host.shellLabel)
                        .llValue(Theme.ink)
                        .frame(width: 52, alignment: .trailing)
                    Text(host.sessionAgeLabel(now: now))
                        .llValue(Theme.inkDim)
                        .frame(width: 32, alignment: .trailing)
                }
                // The two right-hand columns are a measured scale; letting them
                // grow with Dynamic Type would wrap them and destroy the
                // alignment that makes this read as one drawing. Capped on
                // purpose; the name and the annotations below still scale.
                .llMeasuredColumn()

                HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.grid * 2) {
                    // String(port), not "\(port)": SwiftUI's localized
                    // interpolation would group the digits and print 8.443.
                    Text("\(host.hostname):" + String(host.port))
                        .llValue(Theme.inkDim)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: Theme.Metric.grid * 2)
                    flags
                }
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
            MicroLabel(host.useTLS ? "TLS" : "PLAIN", color: host.useTLS ? Theme.inkDim : Theme.warn)
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
    let addHost: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.grid * 5) {
                MicroLabel("NO HOSTS")

                Text("Landline reaches machines you already own, over your own tailnet. A machine appears here once two things are true on it.")
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)

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

                proseText("Then add the machine's tailnet name, the `\(Host.tailnetExample)` shape that `tailscale status` prints.")
                    .llProse(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)

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
                .llProse(Theme.inkDim)
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
    static var opensEditor: Bool { mode == "edit" }

    static func seedIfRequested(into store: HostStore) {
        #if DEBUG
        guard mode == "hosts" || mode == "edit", store.hosts.isEmpty else { return }
        var one = Host()
        one.name = "studio"
        one.hostname = "studio.tail4f1a.ts.net"
        one.startCommand = "tmuxon"
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
        #endif
    }

    /// Fixed status squares so the screenshots show all three states without
    /// pretending a simulator can reach a real tailnet.
    static func scriptedLevels(for hosts: [Host]) -> [UUID: StatusSquare.Level]? {
        #if DEBUG
        guard mode == "hosts" || mode == "edit" else { return nil }
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
