import SwiftUI

// First run, as a guide that finishes itself.
//
// Two steps: one command on the computer, then the machine's name here. Once a
// name is typed the guide keeps asking that machine whether Landline answers,
// and the moment the daemon does, the host is saved and opened. Nobody has to
// find + HOST, and nobody has to guess whether the setup worked.
//
// The phone cannot list tailnet peers, so the name is the one thing the user
// has to bring back from the computer. `landlined doctor` prints it.

struct SetupGuideView: View {
    /// Called once, with a host the daemon has answered for.
    let onFound: (Host) -> Void
    /// The manual path, for anything the guide does not cover.
    var addManually: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var hostname = ""
    @State private var state: SetupProbe.State = .idle
    @State private var finished = false

    private var normalized: String { SetupProbe.normalize(hostname) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            step("01", title: "ON YOUR COMPUTER") {
                proseText("Tailscale on, signed in to the same tailnet as this device. Then paste this one line into a terminal:")
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.grid * 2) {
                    Text(HostSetup.oneLine)
                        .llValue(Theme.inkBright)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Metric.grid)
                    CopyButton(text: HostSetup.oneLine)
                }
                // The instructions are read here and typed there. One share
                // puts the whole setup on the computer: AirDrop, Messages or
                // Mail, then paste.
                ShareLink(item: HostSetup.shareText,
                          subject: Text("Landline setup"),
                          message: Text("Run this on the computer you want to reach.")) {
                    Text("SEND SETUP LINK TO MY COMPUTER")
                }
                .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                proseText("No Homebrew, Linux or Windows: the shared setup has the other ways in.")
                    .llProse(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
            step("02", title: "THE MACHINE'S NAME") {
                proseText("Type the name from the `app url` line that `landlined doctor` printed.")
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $hostname,
                          prompt: Text(Host.tailnetExample).foregroundColor(Theme.inkMuted))
                    .llValue(Theme.inkBright)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .padding(.vertical, Theme.Metric.grid * 2)
                    .overlay(alignment: .bottom) { Hairline() }
                    .accessibilityLabel(Text("machine name"))
                status
            }
            Hairline()
            if let addManually {
                Button("+ ADD HOST MANUALLY", action: addManually)
                    .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                    .padding(.vertical, Theme.Metric.grid * 4)
            }
        }
        // Re-asked on every keystroke (debounced by the loop's first sleep)
        // and whenever the app comes back to the front, which is the moment
        // the user returns from the computer.
        .task(id: "\(normalized)|\(scenePhase != .background)") { await watch() }
        .onAppear { if hostname.isEmpty, let seeded = DemoSeed.setupHostname { hostname = seeded } }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .idle:
            EmptyView()
        case .waiting(let note):
            HStack(alignment: .top, spacing: Theme.Metric.grid * 2) {
                // A filled `warn` square is this world's "checking": no rings.
                StatusSquare(level: .connecting).padding(.top, 3)
                VStack(alignment: .leading, spacing: Theme.Metric.grid) {
                    MicroLabel("WAITING FOR YOUR MACHINE", color: Theme.accent)
                    proseText(note).llProse().fixedSize(horizontal: false, vertical: true)
                }
            }
        case .notAllowed:
            VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
                HStack(spacing: Theme.Metric.grid * 2) {
                    StatusSquare(level: .failed)
                    MicroLabel("FOUND, BUT NOT ALLOWED YET", color: Theme.warn)
                }
                proseText("The daemon answered and does not know this tailnet login. Run this on the computer, then come back:")
                    .llProse()
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline) {
                    Text("landlined allow").llValue(Theme.inkBright).textSelection(.enabled)
                    Spacer(minLength: Theme.Metric.grid)
                    CopyButton(text: "landlined allow")
                }
            }
        case .found:
            HStack(spacing: Theme.Metric.grid * 2) {
                StatusSquare(level: .connected)
                MicroLabel("FOUND. OPENING THE TERMINAL", color: Theme.ok)
            }
        }
    }

    private func step<Content: View>(_ label: String, title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 3) {
            HStack(spacing: Theme.Metric.grid * 2) {
                MicroLabel(label, color: Theme.accent).llMeasuredColumn()
                MicroLabel(title)
            }
            content()
        }
        .padding(.vertical, Theme.Metric.grid * 4)
    }

    private func watch() async {
        let name = normalized
        guard !finished, scenePhase != .background else { return }
        guard SetupProbe.isPlausible(name) else {
            state = name.isEmpty ? .idle
                : .waiting("Just the name, with no port and no spaces. The guide assumes tailscale serve on 443.")
            return
        }
        // Debounce: a name being typed is not worth a request per letter.
        try? await Task.sleep(for: .milliseconds(600))
        while !Task.isCancelled, !finished {
            let result = await SetupProbe.check(hostname: name)
            guard !Task.isCancelled else { return }
            state = result
            if result == .found {
                finished = true
                var host = Host()
                host.hostname = name
                // A beat on FOUND, so the jump to the terminal reads as the
                // guide finishing rather than the screen glitching.
                try? await Task.sleep(for: .milliseconds(700))
                onFound(host)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

/// Asks one machine whether a Landline daemon answers there.
enum SetupProbe {
    enum State: Equatable {
        case idle
        case waiting(String)
        case notAllowed
        case found
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// What people actually paste: the whole `wss://name/v1/shell` line from
    /// `landlined doctor`, a trailing dot from `tailscale status`, a space.
    static func normalize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = name.range(of: "://") { name = String(name[scheme.upperBound...]) }
        if let slash = name.firstIndex(of: "/") { name = String(name[..<slash]) }
        if name.hasSuffix(":443") { name.removeLast(4) }
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    static func isPlausible(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(" ") && !name.contains(":")
    }

    static func check(hostname: String) async -> State {
        var host = Host()
        host.hostname = hostname
        var request = URLRequest(url: host.apiURL(path: "/v1/sessions"))
        request.timeoutInterval = 4
        do {
            let (_, response) = try await session.data(for: request)
            return classify(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            return classify(error: error.code, hostname: hostname)
        } catch {
            return .waiting(stillInstalling)
        }
    }

    private static let stillInstalling =
        "Checking every few seconds. This moves on by itself once the command on the computer finishes."

    /// Only the daemon's own answer counts as found. `GET /v1/sessions`
    /// checks the tailnet login before anything else: a login the daemon does
    /// not allow gets 403, an allowed one without a bearer token gets 401.
    /// (`/v1/shell` is no use here: its WebSocket extractor refuses a plain
    /// GET with 400 before the login is ever looked at.)
    static func classify(status: Int) -> State {
        switch status {
        case 401: .found
        case 403: .notAllowed
        case 502, 503, 504:
            .waiting("Tailscale serve is on, but the daemon is not answering yet. If this lasts, run `landlined doctor` on the computer.")
        default:
            .waiting("Something answered at that name, but it is not Landline. Check the name against `landlined doctor`.")
        }
    }

    static func classify(error: URLError.Code, hostname: String) -> State {
        switch error {
        case .cannotFindHost, .dnsLookupFailed:
            hostname.hasSuffix(".ts.net")
                ? .waiting("That name does not resolve yet. Is Tailscale on, on this device?")
                : .waiting("Use the full name, ending in .ts.net, from the `app url` line.")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            .waiting("The machine answered without a valid certificate. Use the full .ts.net name, and give `landlined install` a moment to turn on HTTPS.")
        case .notConnectedToInternet:
            .waiting("This device is offline.")
        default:
            .waiting(stillInstalling)
        }
    }
}
