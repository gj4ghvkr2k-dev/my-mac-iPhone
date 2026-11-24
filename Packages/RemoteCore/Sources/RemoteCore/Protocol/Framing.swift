import Foundation

/// 制御の通信路（TCP）で使う区切り。
///
/// `| 長さ: UInt16 BE | 本体 |` の形で並べる。
/// 本体の最大長は、Noise の仕様に合わせて 65535 バイト。
public enum Framing {
    public static let maxFrameLength = 65_535

    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameLength else { throw RemoteCoreError.frameTooLarge(payload.count) }
        var writer = ByteWriter()
        writer.write(UInt16(payload.count))
        writer.write(payload)
        return writer.data
    }
}

/// 受け取ったバイト列から、区切られた本体を取り出す。
///
/// TCP では、1回の受信で届くのがメッセージの途中まで、または複数メッセージ分のこともある。
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// まだ取り出していないバイト列。
    public var bufferedBytes: Data { buffer }

    /// 本体が丸ごと届いていれば取り出す。まだなら `nil`。
    public mutating func nextFrame() -> Data? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer[start]) << 8 | Int(buffer[start + 1])
        guard buffer.count >= 2 + length else { return nil }
        let payload = buffer.subdata(in: (start + 2)..<(start + 2 + length))
        buffer = Data(buffer.dropFirst(2 + length))
        return payload
    }
}
