import SwiftUI

@main
struct MacHostApp: App {
    @StateObject private var controller = HostController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(controller: controller)
        } label: {
            Image(systemName: controller.activeClientName == nil ? "display" : "dot.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.window)

        Window("iPhone／iPad を追加", id: WindowID.pairing) {
            PairingView(controller: controller)
        }
        .windowResizability(.contentSize)

        Window("MacRemote の設定", id: WindowID.settings) {
            SettingsView(controller: controller)
        }
        .defaultSize(width: 560, height: 520)
    }
}

enum WindowID {
    static let pairing = "pairing"
    static let settings = "settings"
}
