import AVFoundation
import CoreMedia
import RemoteCore
import UIKit

/// Mac の映像を表示するビュー。中身は AVSampleBufferDisplayLayer で、復元もこのレイヤーが行う。
final class VideoRenderView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // layerClass で決めているので、必ずこの型になる。
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        // ビューの大きさは Viewport.contentRect に合わせるので、引き伸ばしで表示する。
        displayLayer.videoGravity = .resize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// 届いたフレーム（`VideoBitstream` の形式）を、CMSampleBuffer にしてレイヤーに渡す。
///
/// メインキューから呼ぶこと。
final class VideoFrameRenderer {
    let codec: VideoCodec
    private weak var view: VideoRenderView?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    /// 復元できないのでキーフレームが必要。
    var onNeedsKeyFrame: (() -> Void)?
    /// 映像の大きさ（ピクセル）が分かった・変わった。
    var onVideoSize: ((Int, Int) -> Void)?
    /// 表示したフレーム数（統計用）。
    private(set) var renderedFrames = 0

    init(codec: VideoCodec, view: VideoRenderView) {
        self.codec = codec
        self.view = view
    }

    func render(_ frame: VideoFrame) {
        guard let layer = view?.displayLayer else { return }
        if layer.status == .failed {
            layer.flush()
            formatDescription = nil
            parameterSets = []
            onNeedsKeyFrame?()
            return
        }

        guard let units = try? VideoBitstream.split(frame.data), !units.isEmpty else { return }

        if frame.isKeyFrame, let sets = VideoBitstream.parameterSets(in: units, codec: codec), sets != parameterSets {
            guard let description = Self.makeFormatDescription(sets, codec: codec) else {
                onNeedsKeyFrame?()
                return
            }
            formatDescription = description
            parameterSets = sets
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            onVideoSize?(Int(dimensions.width), Int(dimensions.height))
        }

        guard let formatDescription else {
            onNeedsKeyFrame?()
            return
        }

        let body = VideoBitstream.join(units.filter { !VideoBitstream.isParameterSet($0, codec: codec) })
        guard let sampleBuffer = Self.makeSampleBuffer(body, formatDescription: formatDescription) else { return }
        layer.enqueue(sampleBuffer)
        renderedFrames += 1
    }

    func reset() {
        view?.displayLayer.flushAndRemoveImage()
        formatDescription = nil
        parameterSets = []
    }

    // MARK: - CoreMedia

    private static func makeFormatDescription(_ sets: [Data], codec: VideoCodec) -> CMVideoFormatDescription? {
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { data in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var description: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(VideoBitstream.lengthPrefixSize),
                extensions: nil, formatDescriptionOut: &description)
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(VideoBitstream.lengthPrefixSize),
                formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(_ data: Data, formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { return nil }

        status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0,
                                                 dataLength: data.count)
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        // 届いたらすぐに表示する（時刻合わせをしない）。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
