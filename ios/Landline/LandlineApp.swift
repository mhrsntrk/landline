import SwiftUI

@main
struct LandlineApp: App {
    @State private var hostStore = HostStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HostListView()
            }
            .environment(hostStore)
        }
    }
}
