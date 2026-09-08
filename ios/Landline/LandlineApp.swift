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
                // Files fetched out of a host's outbox land in `tmp` and were
                // never cleaned. What a machine pushes is often the sensitive
                // end of what it holds, so they do not get to sit there until
                // iOS feels like reclaiming the space.
                .task { HostAPI.sweepFetchedOffers() }
        }
    }
}
