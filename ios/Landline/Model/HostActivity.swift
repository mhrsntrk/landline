import Foundation
import Observation

// Which machines have a program waiting on you, for the host list.
//
// The list may only ask a host that will not spend an unlock attempt on the
// question. Minting a token with the wrong secret, or with none on a host that
// has one, is a failed guess against the daemon's budget, and a list that
// polled blind every 30 seconds would lock a machine out. So a host is asked
// only when its secret is in the keychain, or when it has already been seen to
// need none (`OpenHosts`). Everything else stays unmarked until the person
// opens it.

/// Hosts that have been seen to grant access with no unlock secret.
enum OpenHosts {
    static let defaultsKey = "openHosts"

    static func contains(_ id: UUID, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: defaultsKey) ?? []).contains(id.uuidString)
    }

    static func mark(_ id: UUID, open: Bool, defaults: UserDefaults = .standard) {
        var ids = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
        if open { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
        defaults.set(ids.sorted(), forKey: defaultsKey)
    }
}

@MainActor @Observable
final class HostActivity {
    /// Per host: how many sessions are waiting on their user. Absent when the
    /// host was not asked or did not answer.
    private(set) var waiting: [UUID: Int] = [:]

    private let api = HostAPI()

    func count(for host: Host) -> Int { waiting[host.id] ?? 0 }

    /// Whether the list may ask this host at all. See the note at the top.
    nonisolated static func mayAsk(_ host: Host, defaults: UserDefaults = .standard) -> Bool {
        Keychain.unlockSecret(hostID: host.id) != nil || OpenHosts.contains(host.id, defaults: defaults)
    }

    func refresh(_ hosts: [Host], isReachable: (Host) -> Bool) {
        if let scripted = DemoSeed.scriptedWaiting(for: hosts) {
            waiting = scripted
            return
        }
        for host in hosts where isReachable(host) && Self.mayAsk(host) {
            let secret = Keychain.unlockSecret(hostID: host.id) ?? ""
            Task {
                do {
                    let sessions = try await api.sessions(on: host, secret: secret)
                    waiting[host.id] = sessions.filter { $0.attention != nil }.count
                } catch {
                    waiting[host.id] = nil
                }
            }
        }
    }
}
