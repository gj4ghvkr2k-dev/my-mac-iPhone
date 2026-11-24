import AppKit
import ApplicationServices
import CoreGraphics
import RemoteCore

/// 「画面収録」と「アクセシビリティ」の許可。
enum Permissions {
    /// 画面を取り込めるか。
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// マウスやキーボードの操作を送れるか。
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Mac につながっているモニター 1 台。
struct HostDisplay: Equatable {
    let id: CGDirectDisplayID
    let name: String
    /// グローバル座標での位置と大きさ（ポイント）。
    let geometry: DisplayGeometry
    let pixelWidth: Int
    let pixelHeight: Int
    let isMain: Bool

    var scale: Double { geometry.width > 0 ? Double(pixelWidth) / geometry.width : 1 }

    var info: DisplayInfo {
        DisplayInfo(id: id, name: name, widthPixels: pixelWidth, heightPixels: pixelHeight,
                    scale: scale, isMain: isMain)
    }
}

enum DisplayDirectory {
    /// 今つながっているモニターの一覧。メインモニターが先頭。
    static func current() -> [HostDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let mainID = CGMainDisplayID()
        let displays = ids.prefix(Int(count)).map { id -> HostDisplay in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            return HostDisplay(
                id: id,
                name: screenName(for: id) ?? "モニター \(id)",
                geometry: DisplayGeometry(originX: Double(bounds.origin.x), originY: Double(bounds.origin.y),
                                          width: Double(bounds.width), height: Double(bounds.height)),
                pixelWidth: mode?.pixelWidth ?? Int(bounds.width),
                pixelHeight: mode?.pixelHeight ?? Int(bounds.height),
                isMain: id == mainID
            )
        }
        return displays.sorted { $0.isMain && !$1.isMain }
    }

    private static func screenName(for id: CGDirectDisplayID) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }
}
