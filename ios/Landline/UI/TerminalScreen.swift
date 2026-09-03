import SwiftUI

struct TerminalScreen: View {
    let host: Host

    @Environment(HostStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var connection = Connection()
    @State private var terminal = TerminalController()
    @State private var state: Connection.State = .idle
    @State private var ctrlSticky = false

    // Unlock handling
    @State private var showUnlockPrompt = false
    @State private var typedSecret = ""
    @State private var unlockAttemptsLeft = 0
    /// True once the Keychain secret was tried on this connection, so a second
    /// NEED_UNLOCK falls through to the manual prompt instead of looping.
    @State private var triedKeychainSecret = false

    var body: some View {
        VStack(spacing: 0) {
            SwiftTermView(
                controller: terminal,
                onSend: { data in sendUserInput(data) },
                onResize: { cols, rows in
                    connection.send(.resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows)))
                }
            )
            KeyBar(ctrlSticky: $ctrlSticky) { bytes in
                sendUserInput(Data(bytes))
            }
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.08))
        .navigationTitle(host.name.isEmpty ? host.hostname : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                statusBadge
            }
        }
        .overlay {
            if case .closed(let reason) = state {
                closedOverlay(reason: reason)
            }
        }
        .alert("Unlock \(host.name.isEmpty ? host.hostname : host.name)", isPresented: $showUnlockPrompt) {
            SecureField("Unlock secret", text: $typedSecret)
            Button("Unlock") {
                connection.send(.unlock(typedSecret))
                typedSecret = ""
            }
            Button("Cancel", role: .cancel) {
                connection.disconnect(sendDetach: false)
            }
        } message: {
            Text(unlockAttemptsLeft > 0 ? "\(unlockAttemptsLeft) attempts left." : "This host requires an unlock secret.")
        }
        .onAppear { wireUpAndConnect() }
        .onDisappear { connection.disconnect(sendDetach: true) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // SCOPE.md 8: detach on backgrounding so the session stays
                // alive server-side without a dangling socket.
                connection.disconnect(sendDetach: true)
            case .active:
                if case .closed = state {
                    reconnect()
                }
            default:
                break
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .live:
            Image(systemName: "circle.fill").foregroundStyle(.green).imageScale(.small)
        case .connecting, .attaching, .needsUnlock:
            ProgressView()
        case .idle, .closed:
            Image(systemName: "circle.fill").foregroundStyle(.red).imageScale(.small)
        }
    }

    private func closedOverlay(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Reconnect") { reconnect() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    // MARK: - Connection plumbing

    private func wireUpAndConnect() {
        connection.onState = { newState in
            state = newState
            handleState(newState)
        }
        connection.onStdout = { data in
            terminal.feed(data)
        }
        connection.onSessionInvalidated = {
            store.setLastSessionID(nil, forHostID: host.id)
        }
        reconnect()
    }

    private func handleState(_ newState: Connection.State) {
        switch newState {
        case .live(let resp):
            // Persist the session id so backgrounding + relaunch can resume.
            store.setLastSessionID(resp.sessionID, forHostID: host.id)
        case .needsUnlock(let attemptsLeft):
            unlockAttemptsLeft = attemptsLeft
            if !triedKeychainSecret, let secret = Keychain.unlockSecret(hostID: host.id) {
                triedKeychainSecret = true
                connection.send(.unlock(secret))
            } else {
                showUnlockPrompt = true
            }
        default:
            break
        }
    }

    private func reconnect() {
        triedKeychainSecret = false
        // Resume via the persisted session id if the store has a newer copy.
        let current = store.host(id: host.id) ?? host
        connection.connect(host: current, cols: terminal.cols, rows: terminal.rows)
    }

    /// All user-originated bytes funnel through here so the sticky Ctrl
    /// modifier can intercept the next key.
    private func sendUserInput(_ data: Data) {
        var bytes = Data()
        if ctrlSticky, let first = data.first {
            // ^A..^Z etc.: fold the key onto the control plane, then untoggle.
            var mapped = first
            if first >= 0x40 && first <= 0x7f {
                mapped = first & 0x1f
            } else if first >= 0x61 && first <= 0x7a {
                mapped = first & 0x1f
            }
            bytes.append(mapped)
            bytes.append(contentsOf: data.dropFirst())
            ctrlSticky = false
        } else {
            bytes = data
        }
        connection.send(.stdin(bytes))
    }
}
