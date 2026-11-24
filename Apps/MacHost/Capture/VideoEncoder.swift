import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import VideoToolbox

/// VideoToolbox で映像を圧縮する。
///
/// 出力は `VideoBitstream` の形式（長さ付き NAL ユニットの並び）。キーフレームの先頭にはパラメータセットが入る。
final class VideoEncoder {
    struct EncodedFrame {
        let data: Data
        let isKeyFrame: Bool
        let captureMicros: UInt64
    }

    let codec: VideoCodec
    let width: Int
    let height: Int
    private var session: VTCompressionSession?

    /// 圧縮が終わったフレーム。VideoToolbox の内部のスレッドで呼ばれる。
    var onEncodedFrame: ((EncodedFrame) -> Void)?
    var onError: ((String) -> Void)?

    init(codec: VideoCodec, width: Int, height: Int, framesPerSecond: Int, bitrateKbps: Int) throws {
        self.codec = codec
        self.width = width
        self.height = height

        let codecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        // 低遅延のビットレート制御を使う。対応していない環境では、指定なしで作り直す。
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
            encoderSpecification: lowLatency, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        if status != noErr || created == nil {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created
            )
        }
        guard status == noErr, let session = created else { throw EncoderError.creationFailed(status) }
        self.session = session

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: framesPerSecond))
        // キーフレームは最長 10 秒ごと。欠けたときは iPhone から要求が来る。
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: framesPerSecond * 10))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 10))
        setBitrate(kbps: bitrateKbps)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    /// ビットレートを変える。急に増えすぎないよう、1 秒あたりの上限も平均の 1.5 倍にする。
    func setBitrate(kbps: Int) {
        let bitsPerSecond = max(200, kbps) * 1000
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitsPerSecond))
        let limits = [NSNumber(value: Double(bitsPerSecond) / 8 * 1.5), NSNumber(value: 1.0)] as CFArray
        set(kVTCompressionPropertyKey_DataRateLimits, limits)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, captureMicros: UInt64, forceKeyFrame: Bool) {
        guard let session else { return }
        let properties = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let timestamp = CMTime(value: CMTimeValue(captureMicros), timescale: 1_000_000)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: timestamp, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer else {
                self.onError?("圧縮に失敗しました（\(status)）")
                return
            }
            self.handle(sampleBuffer, captureMicros: captureMicros)
        }
        if status != noErr {
            onError?("圧縮を開始できません（\(status)）")
        }
    }

    // MARK: - 内部

    private func handle(_ sampleBuffer: CMSampleBuffer, captureMicros: UInt64) {
        guard let block = sampleBuffer.dataBuffer,
              let format = sampleBuffer.formatDescription else { return }

        let isKeyFrame: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[CFString: Any]],
                  let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool else {
                return true
            }
            return !notSync
        }()

        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let copyStatus = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == noErr else { return }

        let (parameterSets, lengthSize) = Self.parameterSets(of: format, codec: codec)
        do {
            var units = try VideoBitstream.split(bytes, lengthSize: lengthSize)
            if isKeyFrame {
                units.removeAll { VideoBitstream.isParameterSet($0, codec: codec) }
                units.insert(contentsOf: parameterSets, at: 0)
            }
            onEncodedFrame?(EncodedFrame(data: VideoBitstream.join(units), isKeyFrame: isKeyFrame,
                                         captureMicros: captureMicros))
        } catch {
            onError?("圧縮データの形式が想定外です：\(error)")
        }
    }

    /// 映像の形式から、パラメータセットと NAL ユニットの長さ部分のバイト数を取り出す。
    private static func parameterSets(of format: CMFormatDescription, codec: VideoCodec) -> ([Data], Int) {
        var count = 0
        var headerLength: Int32 = 4
        var sets: [Data] = []

        func get(_ index: Int, _ pointer: inout UnsafePointer<UInt8>?, _ size: inout Int) -> OSStatus {
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            case .h264:
                return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            }
        }

        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard get(0, &pointer, &size) == noErr else { return ([], Int(headerLength)) }
        for index in 0..<count {
            if get(index, &pointer, &size) == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return (sets, Int(headerLength))
    }

    private func set(_ key: CFString, _ value: CFTypeRef?) {
        guard let session, let value else { return }
        VTSessionSetProperty(session, key: key, value: value)
    }

    enum EncoderError: LocalizedError {
        case creationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let status): return "映像の圧縮を準備できません（\(status)）"
            }
        }
    }
}
