import Foundation
import Observation

/// Loads and saves the host list as JSON in the app's Documents directory.
@Observable
final class HostStore {
    private(set) var hosts: [Host] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("hosts.json")
        load()
    }

    // MARK: - CRUD

    func add(_ host: Host) {
        hosts.append(host)
        save()
    }

    func update(_ host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        save()
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        try? Keychain.deleteUnlockSecret(hostID: host.id)
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            try? Keychain.deleteUnlockSecret(hostID: hosts[index].id)
        }
        hosts.remove(atOffsets: offsets)
        save()
    }

    func host(id: UUID) -> Host? {
        hosts.first { $0.id == id }
    }

    /// Record the session id handed back by ATTACHED so the next connect resumes it.
    func setLastSessionID(_ sessionID: String?, forHostID id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastSessionID = sessionID
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
