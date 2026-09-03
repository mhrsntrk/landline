import SwiftUI
import LocalAuthentication

struct HostListView: View {
    @Environment(HostStore.self) private var store

    @State private var editingHost: Host?
    @State private var showingAddSheet = false
    @State private var openedHost: Host?
    @State private var authError: String?

    var body: some View {
        List {
            if store.hosts.isEmpty {
                ContentUnavailableView(
                    "No hosts yet",
                    systemImage: "server.rack",
                    description: Text("Add a machine running landlined on your tailnet.")
                )
            }
            ForEach(store.hosts) { host in
                Button {
                    open(host)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name.isEmpty ? host.hostname : host.name)
                                .font(.headline)
                            Text(host.hostname)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if host.requireFaceID {
                            Image(systemName: "faceid")
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.delete(host)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingHost = host
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
        }
        .navigationTitle("Landline")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            HostEditView(host: Host()) { newHost, secret in
                store.add(newHost)
                persistSecret(secret, for: newHost)
            }
        }
        .sheet(item: $editingHost) { host in
            HostEditView(host: host) { updated, secret in
                store.update(updated)
                persistSecret(secret, for: updated)
            }
        }
        .navigationDestination(item: $openedHost) { host in
            TerminalScreen(host: host)
        }
        .alert("Authentication failed", isPresented: .init(
            get: { authError != nil },
            set: { if !$0 { authError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authError ?? "")
        }
    }

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
            authError = error?.localizedDescription ?? "Face ID unavailable."
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock \(host.name.isEmpty ? host.hostname : host.name)"
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

// MARK: - Add / edit form

struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State var host: Host
    /// nil = the user never touched the field; "" = clear the stored secret.
    @State private var unlockSecret: String = ""
    @State private var secretEdited = false

    let onSave: (Host, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name", text: $host.name)
                    TextField("macbook.tail1234.ts.net", text: $host.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.body.monospaced())
                    TextField("Port", value: $host.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    Toggle("TLS", isOn: $host.useTLS)
                }
                Section {
                    Toggle("Require Face ID", isOn: $host.requireFaceID)
                    SecureField("Unlock secret (optional)", text: $unlockSecret)
                        .onChange(of: unlockSecret) { secretEdited = true }
                } header: {
                    Text("Security")
                } footer: {
                    Text("The unlock secret is stored in the Keychain and sent when the daemon asks for it.")
                }
            }
            .navigationTitle(host.name.isEmpty ? "Add Host" : host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(host, secretEdited ? unlockSecret : nil)
                        dismiss()
                    }
                    .disabled(host.hostname.isEmpty)
                }
            }
        }
    }
}
