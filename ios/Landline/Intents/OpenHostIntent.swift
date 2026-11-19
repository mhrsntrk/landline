import AppIntents
import Foundation
import Observation

// "Open studio" from Shortcuts, Spotlight, Siri or the Action button.
//
// The intent only names a machine and brings the app forward. Opening it goes
// through the host list's own `open(_:)`, the same path a tap takes, so Face ID
// on a protected host and the trial gate in the terminal both still apply. An
// intent that set the route directly would skip them.

/// One saved machine, as Shortcuts sees it.
struct HostEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Machine")
    static let defaultQuery = HostEntityQuery()

    let id: UUID
    let name: String
    let hostname: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(hostname)")
    }

    init(_ host: Host) {
        id = host.id
        name = host.displayName
        hostname = host.hostname
    }
}

struct HostEntityQuery: EntityQuery, EnumerableEntityQuery {
    /// Read fresh each time: the intent may run before any view exists.
    private func saved() -> [HostEntity] {
        HostStore().hosts.map(HostEntity.init)
    }

    func entities(for identifiers: [UUID]) async throws -> [HostEntity] {
        saved().filter { identifiers.contains($0.id) }
    }

    func allEntities() async throws -> [HostEntity] { saved() }

    func suggestedEntities() async throws -> [HostEntity] { saved() }
}

/// Where an intent leaves the machine it named, for the host list to open.
@MainActor @Observable
final class IntentRouter {
    static let shared = IntentRouter()
    var pendingHostID: UUID?
}

struct OpenHostIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Machine"
    static let description = IntentDescription("Opens a terminal on one of your saved machines.")
    static let openAppWhenRun = true

    @Parameter(title: "Machine")
    var host: HostEntity

    init() {}

    init(host: HostEntity) {
        self.host = host
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingHostID = host.id
        return .result()
    }
}

struct LandlineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenHostIntent(),
            phrases: [
                "Open \(\.$host) in \(.applicationName)",
                "Connect to \(\.$host) with \(.applicationName)",
            ],
            shortTitle: "Open Machine",
            systemImageName: "terminal"
        )
    }
}
