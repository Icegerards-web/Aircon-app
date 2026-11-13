import SwiftUI

@main
struct AircoApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .tint(Theme.blue)
                .onChange(of: scenePhase) { phase in
                    // Only talk to the adapters while the app is open (they are slow and don't like being hammered).
                    if phase == .active { store.startPolling() } else { store.stopPolling() }
                }
                .onAppear { store.startPolling() }
        }
    }
}
