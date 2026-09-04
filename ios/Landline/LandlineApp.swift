import SwiftUI

@main
struct LandlineApp: App {
    @State private var hostStore = HostStore()
    /// App-wide settings, alongside the host list. The key bar's layout is one
    /// arrangement for every machine, so it cannot live on a `Host`.
    @State private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HostListView()
            }
            .environment(hostStore)
            .environment(settingsStore)
        }
    }
}
