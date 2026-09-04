import Foundation
import Observation

/// Loads and saves the app-wide settings as JSON in Documents, alongside
/// `hosts.json`. Same pattern as `HostStore`, deliberately: one small
/// `@Observable`, one file, written atomically on every mutation.
@Observable
final class SettingsStore {
    private(set) var settings: AppSettings

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? AppSettings.decode(from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    // MARK: - Key bar

    var keyBar: [KeyBarKey] { settings.keyBar }

    /// The bar as it will actually draw: unresolvable slots dropped. See
    /// `KeyBarKey.resolved` for why they are dropped here rather than on load.
    var resolvedKeyBar: [ResolvedKey] { settings.keyBar.compactMap(\.resolved) }

    func append(_ key: KeyBarKey) {
        settings.keyBar.append(key)
        save()
    }

    func remove(id: UUID) {
        settings.keyBar.removeAll { $0.id == id }
        save()
    }

    func replace(_ key: KeyBarKey) {
        guard let index = settings.keyBar.firstIndex(where: { $0.id == key.id }) else { return }
        settings.keyBar[index] = key
        save()
    }

    func key(id: UUID) -> KeyBarKey? {
        settings.keyBar.first { $0.id == id }
    }

    /// Drag reordering, the `List` shape.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        settings.keyBar.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// One step along the row. The buttons exist because which keys sit under
    /// the thumb is the whole point of this screen, and a one-handed nudge has
    /// to work without a drag gesture.
    func nudge(id: UUID, by delta: Int) {
        guard let index = settings.keyBar.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard settings.keyBar.indices.contains(target) else { return }
        settings.keyBar.swapAt(index, target)
        save()
    }

    func resetKeyBar() {
        // Fresh ids: the identity of a slot is the slot, not the key in it.
        settings.keyBar = KeyBarKey.defaultLayout.map {
            KeyBarKey(catalogID: $0.catalogID, label: $0.label, sequence: $0.sequence)
        }
        save()
    }

    var isDefaultKeyBar: Bool {
        settings.keyBar.map { [$0.catalogID, $0.label, $0.sequence] }
            == KeyBarKey.defaultLayout.map { [$0.catalogID, $0.label, $0.sequence] }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? AppSettings.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
