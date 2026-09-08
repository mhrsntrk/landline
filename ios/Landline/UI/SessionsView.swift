import SwiftUI

/// What is running on one host, and the two things worth doing about it.
///
/// The daemon has always known this. Until now only a process on the host could
/// ask, over the admin socket, which is exactly the machine you are not sitting
/// at when it matters: a session you orphaned from a phone was invisible from
/// the phone that orphaned it.
///
/// Resuming is a push into the terminal with the session already chosen.
/// Killing is killing, and says so.
struct SessionsView: View {
    let host: Host
    /// Called with a session id the caller should attach to.
    var resume: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var api = HostAPI()
    @State private var sessions: [HostSession] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var killing: String?

    var body: some View {
        VStack(spacing: 0) {
            if loading && sessions.isEmpty {
                message("CHECKING", "Asking \(host.displayName) what it is running.")
            } else if let failure {
                message("UNREACHABLE", failure, isError: true)
            } else if sessions.isEmpty {
                message("NOTHING RUNNING",
                        "No sessions on this machine. Opening the terminal starts one.")
            } else {
                list
            }
        }
        .background(Theme.panel)
        .safeAreaInset(edge: .top, spacing: 0) {
            SettingHeader(title: "SESSIONS", annotation: annotation)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private var annotation: String {
        if loading && sessions.isEmpty { return host.displayName.uppercased() }
        let count = sessions.count
        guard count > 0 else { return "NONE ON \(host.displayName.uppercased())" }
        return "\(count) \(count == 1 ? "SESSION" : "SESSIONS") / \(host.displayName.uppercased())"
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sessions) { session in
                    row(session)
                    Hairline()
                }
            }
            .padding(.bottom, Theme.Metric.grid * 8)
        }
        .background(Theme.ground)
    }

    private func row(_ session: HostSession) -> some View {
        HStack(spacing: Theme.Metric.grid * 3) {
            StatusSquare(level: session.attached ? .connected : .offline)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(session.id.prefix(8)).uppercased())
                    .llValue(Theme.inkBright)
                    .lineLimit(1)
                MicroLabel("\(session.shellLabel) / \(session.attached ? "ATTACHED" : "DETACHED")")
                    .llMeasuredColumn()
            }

            Spacer(minLength: Theme.Metric.grid)

            VStack(alignment: .trailing, spacing: 1) {
                MicroLabel("IDLE")
                Text(Self.idleLabel(session.idleSecs))
                    .llValue(Theme.inkMuted)
                    .llMeasuredColumn()
            }

            Button("OPEN") { resume(session.id) }
                .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
            Button(killing == session.id ? "..." : "KILL") {
                Task { await kill(session) }
            }
            .buttonStyle(InstrumentButtonStyle(emphasis: .destructive))
            .disabled(killing != nil)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, Theme.Metric.grid * 2)
        .frame(minHeight: Theme.Metric.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ label: String, _ body: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 4) {
            MicroLabel(label, color: isError ? Theme.alert : Theme.inkMuted)
            proseText(body)
                .llProse(isError ? Theme.alertText : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if isError {
                Button("RETRY") { Task { await load() } }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, Theme.Metric.grid * 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
    }

    /// Coarse, and never wider than the column: this answers "is that the one I
    /// left this morning", which minutes do not.
    static func idleLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(0, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        let secret = Keychain.unlockSecret(hostID: host.id) ?? ""
        do {
            sessions = try await api.sessions(on: host, secret: secret)
            failure = nil
        } catch {
            failure = (error as? UploadError)?.message ?? error.localizedDescription
        }
    }

    @MainActor
    private func kill(_ session: HostSession) async {
        killing = session.id
        defer { killing = nil }
        let secret = Keychain.unlockSecret(hostID: host.id) ?? ""
        do {
            try await api.killSession(id: session.id, on: host, secret: secret)
            // Drop it locally rather than re-listing: the daemon reaps on its
            // own schedule and a row that lingers for a second reads as a kill
            // that did not work.
            sessions.removeAll { $0.id == session.id }
        } catch {
            failure = (error as? UploadError)?.message ?? error.localizedDescription
        }
    }
}
