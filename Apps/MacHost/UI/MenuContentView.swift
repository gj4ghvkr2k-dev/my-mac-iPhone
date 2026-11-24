import AppKit
import SwiftUI

/// メニューバーのアイコンを押したときに開く画面。
struct MenuContentView: View {
    @ObservedObject var controller: HostController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: controller.activeClientName == nil ? "display" : "dot.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(controller.activeClientName == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading) {
                    Text("MacRemote").font(.headline)
                    Text(controller.statusText).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let name = controller.activeClientName {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(name, systemImage: "iphone")
                        Text("経路：\(controller.activePath ?? "不明")").font(.caption)
                        Text("映像：\(controller.streamStats)").font(.caption.monospacedDigit())
                        Button("切断") { controller.disconnectActiveClient() }
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !controller.hasScreenRecording || !controller.hasAccessibility {
                PermissionsNotice(controller: controller)
            }

            Divider()

            Button {
                controller.startPairing()
                show(WindowID.pairing)
            } label: {
                Label("iPhone／iPad を追加…", systemImage: "qrcode")
            }

            Button {
                show(WindowID.settings)
            } label: {
                Label("登録済みの端末と設定…", systemImage: "gearshape")
            }

            Divider()

            Button("MacRemote を終了") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding()
        .frame(width: 300)
    }

    private func show(_ id: String) {
        openWindow(id: id)
        // メニューバーだけのアプリなので、ウィンドウを前面に出すには自分で有効にする必要がある。
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 許可が足りないときの案内。
struct PermissionsNotice: View {
    @ObservedObject var controller: HostController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("許可が必要です", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if !controller.hasScreenRecording {
                    permissionRow(
                        "画面収録", detail: "Mac の画面を iPhone に映すために必要です",
                        request: Permissions.requestScreenRecording, open: Permissions.openScreenRecordingSettings
                    )
                }
                if !controller.hasAccessibility {
                    permissionRow(
                        "アクセシビリティ", detail: "iPhone からマウスやキーボードを操作するために必要です",
                        request: Permissions.requestAccessibility, open: Permissions.openAccessibilitySettings
                    )
                }
                Text("許可したあと、MacRemote を一度終了して起動し直す必要がある場合があります。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionRow(_ title: String, detail: String,
                               request: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("許可を求める") { request() }
                Button("システム設定を開く") { open() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
