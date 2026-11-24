import SwiftUI

@main
struct iOSClientApp: App {
    @StateObject private var store = ClientStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HostListView(store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.startBrowsing()
            case .background: store.stopBrowsing()
            default: break
            }
        }
    }
}
