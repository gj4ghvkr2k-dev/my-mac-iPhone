import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import RemoteCore
import SwiftUI

/// 端末登録の QR コードを表示する画面。
struct PairingView: View {
    @ObservedObject var controller: HostController

    var body: some View {
        VStack(spacing: 16) {
            if let invitation = controller.invitation {
                Text("iPhone／iPad の MacRemote アプリで、この QR コードを読み取ってください")
                    .multilineTextAlignment(.center)

                if let image = QRCode.image(for: invitation.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 260, height: 260)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if let expiresAt = controller.invitationExpiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                        Text("有効期限：あと \(remaining / 60) 分 \(remaining % 60) 秒")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Text("この Mac：\(controller.hostName)（ID: \(controller.identity.hostID)）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("キャンセル") { controller.cancelPairing() }
            } else {
                if let message = controller.pairingMessage {
                    Label(message, systemImage: message.contains("登録しました") ? "checkmark.circle.fill" : "clock")
                        .font(.title3)
                        .foregroundStyle(message.contains("登録しました") ? Color.green : Color.secondary)
                }
                Button("新しい QR コードを表示") { controller.startPairing() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onDisappear { controller.cancelPairing() }
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
