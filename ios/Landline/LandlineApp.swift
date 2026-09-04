import SwiftUI

@main
struct LandlineApp: App {
    @State private var hostStore = HostStore()
    /// App-wide settings, alongside the host list. The key bar's layout is one
    /// arrangement for every machine, so it cannot live on a `Host`.
    @State private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            // `RootView` picks the stack or the split by horizontal size class.
            // The stores are attached above it so neither shape re-creates them.
            RootView()
                .environment(hostStore)
                .environment(settingsStore)
        }
    }
}
