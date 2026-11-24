import Foundation

/// 圧縮済みの映像 1 フレーム分。
public struct VideoFrame: Equatable, Sendable {
    public var frameNumber: UInt32
    public var isKeyFrame: Bool
    /// 取り込んだ時刻（マイクロ秒）。遅延の計測に使う。
    public var timestampMicros: UInt64
    /// 圧縮されたデータ（長さ付き NAL ユニットの並び）。
    public var data: Data

    public init(frameNumber: UInt32, isKeyFrame: Bool, timestampMicros: UInt64, data: Data) {
        self.frameNumber = frameNumber
        self.isKeyFrame = isKeyFrame
        self.timestampMicros = timestampMicros
        self.data = data
    }
}

/// 映像パケット（UDP）1つ分。
///
/// `| 種類 1B | フレーム番号 UInt32 | 分割番号 UInt16 | 分割数 UInt16 | フラグ 1B | 時刻 UInt64 | 暗号化データ ‖ タグ 16B |`
///
/// ヘッダー（先頭 18 バイト）は暗号化しないが、認証の対象に含めるので改ざんはできない。
struct VideoFragment: Equatable, Sendable {
    static let packetType: UInt8 = 0x01
    static let headerLength = 18
    static let keyFrameFlag: UInt8 = 0x01

    var frameNumber: UInt32
    var fragmentIndex: UInt16
    var fragmentCount: UInt16
    var isKeyFrame: Bool
    var timestampMicros: UInt64
    var payload: Data

    var header: Data {
        var w = ByteWriter()
        w.write(Self.packetType)
        w.write(frameNumber)
        w.write(fragmentIndex)
        w.write(fragmentCount)
        w.write(isKeyFrame ? Self.keyFrameFlag : UInt8(0))
        w.write(timestampMicros)
        return w.data
    }

    /// nonce：フレーム番号と分割番号の組は 1 回の接続で重複しないので、そのまま使う。
    var nonce: Data {
        var w = ByteWriter()
        w.write(UInt32(0))
        w.write(frameNumber)
        w.write(fragmentIndex)
        w.write(UInt16(0))
        return w.data
    }
}

/// 映像パケットの暗号化と復号。
public struct VideoPacketCodec: Sendable {
    /// UDP パケット 1 つの最大長。経路の MTU で分割されない大きさにしている。
    public static let maxPacketLength = 1200
    public static let maxPayloadPerPacket = maxPacketLength - VideoFragment.headerLength - CryptoPrimitives.tagLength

    private let key: Data

    public init(key: Data) throws {
        guard key.count == CryptoPrimitives.keyLength else { throw RemoteCoreError.invalidKey }
        self.key = key
    }

    func seal(_ fragment: VideoFragment) throws -> Data {
        let header = fragment.header
        return header + (try CryptoPrimitives.seal(
            key: key, nonce: fragment.nonce, associatedData: header, plaintext: fragment.payload
        ))
    }

    func open(_ packet: Data) throws -> VideoFragment {
        guard packet.count >= VideoFragment.headerLength + CryptoPrimitives.tagLength,
              packet.count <= Self.maxPacketLength else {
            throw RemoteCoreError.videoPacketMalformed
        }
        var r = ByteReader(packet)
        guard try r.readUInt8() == VideoFragment.packetType else { throw RemoteCoreError.videoPacketMalformed }
        var fragment = VideoFragment(
            frameNumber: try r.readUInt32(),
            fragmentIndex: try r.readUInt16(),
            fragmentCount: try r.readUInt16(),
            isKeyFrame: try r.readUInt8() & VideoFragment.keyFrameFlag != 0,
            timestampMicros: try r.readUInt64(),
            payload: Data()
        )
        guard fragment.fragmentCount > 0, fragment.fragmentIndex < fragment.fragmentCount else {
            throw RemoteCoreError.videoPacketMalformed
        }
        let header = Data(packet.prefix(VideoFragment.headerLength))
        fragment.payload = try CryptoPrimitives.open(
            key: key, nonce: fragment.nonce, associatedData: header, ciphertext: r.readRemaining()
        )
        return fragment
    }
}

/// Mac 側：フレームを UDP パケットに分けて暗号化する。
public struct VideoPacketizer: Sendable {
    private let codec: VideoPacketCodec
    private var nextFrameNumber: UInt32 = 0

    public init(key: Data) throws {
        self.codec = try VideoPacketCodec(key: key)
    }

    /// 1 フレームを送るための UDP パケットの並びを返す。フレーム番号はここで振る。
    public mutating func packetize(data: Data, isKeyFrame: Bool, timestampMicros: UInt64) throws -> [Data] {
        // フレーム番号が一周すると nonce が重複するので、その前に接続をやり直すこと（60fps で約 2 年）。
        guard nextFrameNumber < UInt32.max else { throw RemoteCoreError.frameNumberExhausted }
        let frameNumber = nextFrameNumber
        nextFrameNumber += 1

        let chunkSize = VideoPacketCodec.maxPayloadPerPacket
        let count = max(1, (data.count + chunkSize - 1) / chunkSize)
        guard count <= Int(UInt16.max) else { throw RemoteCoreError.frameTooLarge(data.count) }

        let bytes = Data(data)
        return try (0..<count).map { index in
            let start = index * chunkSize
            let end = min(start + chunkSize, bytes.count)
            let fragment = VideoFragment(
                frameNumber: frameNumber,
                fragmentIndex: UInt16(index),
                fragmentCount: UInt16(count),
                isKeyFrame: isKeyFrame,
                timestampMicros: timestampMicros,
                payload: bytes.subdata(in: start..<end)
            )
            return try codec.seal(fragment)
        }
    }
}

/// iPhone 側：UDP パケットを復号し、フレームに組み立てる。
///
/// - 欠けた分割があるフレームは捨て、`requestKeyFrame` を返す。
/// - 欠けたあとは、次のキーフレームが揃うまでフレームを返さない（復元すると画面が崩れるため）。
/// - 遅れて届いたパケットや重複したパケットは捨てる。
public struct VideoReassembler: Sendable {
    public enum Event: Equatable, Sendable {
        case frame(VideoFrame)
        /// Mac にキーフレームを要求すべき。短時間に何度も出ることがあるので、送る側で間引くこと。
        case requestKeyFrame
    }

    private struct PendingFrame: Sendable {
        var fragments: [Data?]
        var receivedCount = 0
        let isKeyFrame: Bool
        let timestampMicros: UInt64
    }

    private let codec: VideoPacketCodec
    private let maxPendingFrames: Int
    private var pending: [UInt32: PendingFrame] = [:]
    /// これより前のフレーム番号は、もう受け付けない。
    private var nextExpectedFrame: UInt32 = 0
    private var awaitingKeyFrame = true
    /// 改ざん・壊れたパケットの数（統計用）。
    public private(set) var rejectedPacketCount = 0

    public init(key: Data, maxPendingFrames: Int = 4) throws {
        self.codec = try VideoPacketCodec(key: key)
        self.maxPendingFrames = maxPendingFrames
    }

    public mutating func ingest(_ packet: Data) -> [Event] {
        let fragment: VideoFragment
        do {
            fragment = try codec.open(packet)
        } catch {
            rejectedPacketCount += 1
            return []
        }

        let number = fragment.frameNumber
        guard number >= nextExpectedFrame else { return [] } // 遅れて届いた・重複

        var frame = pending[number] ?? PendingFrame(
            fragments: Array(repeating: nil, count: Int(fragment.fragmentCount)),
            isKeyFrame: fragment.isKeyFrame,
            timestampMicros: fragment.timestampMicros
        )
        let index = Int(fragment.fragmentIndex)
        guard frame.fragments.count == Int(fragment.fragmentCount), frame.fragments[index] == nil else {
            return [] // 分割数の食い違い、または重複
        }
        frame.fragments[index] = fragment.payload
        frame.receivedCount += 1

        var events: [Event] = []

        guard frame.receivedCount == frame.fragments.count else {
            pending[number] = frame
            events += dropOverflowingFrames()
            return events
        }

        // フレームが揃った。これより前で揃っていないフレームは欠けたものとみなす。
        pending[number] = nil
        let skippedFrames = number > nextExpectedFrame
        let olderPending = pending.keys.filter { $0 < number }
        for key in olderPending { pending[key] = nil }
        nextExpectedFrame = number + 1

        if skippedFrames || !olderPending.isEmpty {
            awaitingKeyFrame = true
        }

        if awaitingKeyFrame && !frame.isKeyFrame {
            events.append(.requestKeyFrame)
            return events
        }

        awaitingKeyFrame = false
        let data = frame.fragments.reduce(into: Data()) { $0.append($1!) }
        events.append(.frame(VideoFrame(
            frameNumber: number,
            isKeyFrame: frame.isKeyFrame,
            timestampMicros: frame.timestampMicros,
            data: data
        )))
        return events
    }

    /// 組み立て途中のフレームが多すぎるときは、古いものを欠けたとみなして捨てる。
    private mutating func dropOverflowingFrames() -> [Event] {
        guard pending.count > maxPendingFrames else { return [] }
        let excess = pending.keys.sorted().prefix(pending.count - maxPendingFrames)
        for key in excess { pending[key] = nil }
        if let newestDropped = excess.last {
            nextExpectedFrame = max(nextExpectedFrame, newestDropped + 1)
        }
        awaitingKeyFrame = true
        return [.requestKeyFrame]
    }
}
