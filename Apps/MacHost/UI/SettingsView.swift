import RemoteCore
import SwiftUI

/// 登録済みの端末の一覧と、許可・ログ。
struct SettingsView: View {
    @ObservedObject var controller: HostController
    @State private var peerToRemove: TrustedPeer?

    var body: some View {
        Form {
            Section("この Mac") {
                LabeledContent("名前", value: controller.hostName)
                LabeledContent("ID", value: controller.identity.hostID)
                LabeledContent("状態", value: controller.statusText)
            }

            Section("登録済みの端末") {
                if controller.trustedPeers.isEmpty {
                    Text("まだ登録されていません。メニューの「iPhone／iPad を追加」から登録できます。")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.trustedPeers) { peer in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text("登録日：\(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("削除", role: .destructive) { peerToRemove = peer }
                    }
                }
            }

            Section("許可") {
                LabeledContent("画面収録", value: controller.hasScreenRecording ? "許可済み" : "未許可")
                LabeledContent("アクセシビリティ", value: controller.hasAccessibility ? "許可済み" : "未許可")
                if !controller.hasScreenRecording || !controller.hasAccessibility {
                    PermissionsNotice(controller: controller)
                }
            }

            Section("ログ") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.logLines.enumerated().reversed()), id: \.offset) { item in
                            Text(item.element)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "「\(peerToRemove?.name ?? "")」の登録を削除しますか？",
            isPresented: Binding(get: { peerToRemove != nil }, set: { if !$0 { peerToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let peerToRemove { controller.removeTrustedPeer(peerToRemove) }
                peerToRemove = nil
            }
        } message: {
            Text("削除した端末は、もう一度 QR コードで登録するまで接続できなくなります。")
        }
    }
}
