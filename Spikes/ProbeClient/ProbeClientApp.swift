import SwiftUI
import UIKit

@main
struct ProbeClientApp: App {
    @StateObject private var model = ProbeClientModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HostListView(model: model)
            }
            .onAppear {
                // 計測中に画面が消えないようにする。
                UIApplication.shared.isIdleTimerDisabled = true
                model.startBrowsing()
            }
        }
    }
}

struct HostListView: View {
    @ObservedObject var model: ProbeClientModel

    var body: some View {
        List {
            Section {
                if model.hosts.isEmpty {
                    Text(model.browserStatus)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.hosts) { host in
                    NavigationLink {
                        MeasurementView(model: model, host: host)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).font(.headline)
                            Text("経路の候補：\(host.interfaces)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let hostID = host.hostID {
                                Text("ID：\(hostID)")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("見つかった Mac")
            } footer: {
                Text("Mac で「MacRemote 検証（Mac）」を起動しておいてください。Wi-Fi 直結を試すときは、Mac と iPhone の両方で Wi-Fi をオンにしたまま、Wi-Fi ネットワークへの接続だけを切ります。")
            }
        }
        .navigationTitle("MacRemote 検証")
    }
}

struct MeasurementView: View {
    @ObservedObject var model: ProbeClientModel
    let host: DiscoveredHost
    @State private var copied = false

    private let bitrates = [2_000, 5_000, 10_000, 20_000, 40_000]

    var body: some View {
        List {
            Section("接続") {
                LabeledContent("状態", value: model.phaseDescription)
                LabeledContent("TCP の経路", value: model.tcpPath)
                LabeledContent("UDP の経路", value: model.udpPath)
            }

            Section("往復の遅延") {
                VStack(alignment: .leading) {
                    Text("TCP（操作・制御）").font(.subheadline)
                    Text(model.tcpLatency.summary).font(.caption.monospacedDigit())
                }
                VStack(alignment: .leading) {
                    Text("UDP（映像）").font(.subheadline)
                    Text(model.udpLatency.summary).font(.caption.monospacedDigit())
                }
            }

            Section("擬似映像") {
                Picker("ビットレート", selection: $model.bitrateKbps) {
                    ForEach(bitrates, id: \.self) { kbps in
                        Text("\(kbps / 1000) Mbps").tag(kbps)
                    }
                }
                .onChange(of: model.bitrateKbps) { _, _ in model.restartStream() }
                Text(model.videoSummary).font(.caption.monospacedDigit())
            }

            Section {
                Button(copied ? "コピーしました" : "結果をコピー") {
                    UIPasteboard.general.string = model.reportText
                    copied = true
                }
                Button("計測をやり直す") { model.restartStream() }
                Button("再接続") { model.connect(to: host) }
            }

            Section("ログ") {
                ForEach(Array(model.logLines.suffix(50).enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption2.monospaced())
                }
            }
        }
        .navigationTitle(host.name)
        .onAppear { model.connect(to: host) }
        .onDisappear { model.disconnect() }
    }
}
