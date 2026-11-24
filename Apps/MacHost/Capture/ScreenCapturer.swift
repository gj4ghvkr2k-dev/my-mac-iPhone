import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit で、1 台のモニターの画面を取り込む。
///
/// 画面に変化がないときは、ScreenCaptureKit は新しいフレームを渡してこない。
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Settings: Equatable {
        var displayID: CGDirectDisplayID
        var width: Int
        var height: Int
        var framesPerSecond: Int
    }

    /// 取り込んだフレーム。`sampleQueue` の上で呼ばれる。
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    /// 取り込みが止まった。メインキューで呼ばれる。
    var onStop: ((Error?) -> Void)?

    private let sampleQueue = DispatchQueue(label: "macremote.capture", qos: .userInteractive)
    private var stream: SCStream?
    private(set) var settings: Settings?

    func start(_ settings: Settings) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == settings.displayID }) else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = settings.width
        configuration.height = settings.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.framesPerSecond)))
        // NV12。VideoToolbox にそのまま渡せる。
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 4
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        self.settings = settings
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        settings = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // 変化のない（idle）フレームなどは捨て、完成したフレームだけを使う。
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        onFrame?(pixelBuffer, monotonicMicros())
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.settings = nil
            self.onStop?(error)
        }
    }

    enum CaptureError: LocalizedError {
        case displayNotFound

        var errorDescription: String? {
            switch self {
            case .displayNotFound: return "取り込むモニターが見つかりません"
            }
        }
    }
}
