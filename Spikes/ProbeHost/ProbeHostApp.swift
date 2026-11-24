import SwiftUI

@main
struct ProbeHostApp: App {
    @StateObject private var service = ProbeHostService()

    var body: some Scene {
        WindowGroup("MacRemote 検証（Mac）") {
            ProbeHostView(service: service)
                .frame(minWidth: 560, minHeight: 420)
                .onAppear { service.start() }
        }
    }
}

struct ProbeHostView: View {
    @ObservedObject var service: ProbeHostService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacRemote 検証用アプリ（Mac 側）")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("状態", service.status)
                row("Mac の名前", service.hostName)
                row("TCP ポート", service.tcpPort)
                row("UDP ポート", service.udpPort)
                row("接続中の端末", service.clientDescription)
                row("擬似映像", service.streamDescription)
            }

            Text("ログ")
                .font(.headline)
            ScrollViewReader { proxy in
                List(Array(service.logLines.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .id(item.offset)
                }
                .onChange(of: service.logLines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .padding()
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
