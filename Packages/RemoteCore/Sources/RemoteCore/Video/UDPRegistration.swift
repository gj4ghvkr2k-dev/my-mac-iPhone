import Foundation

/// iPhone → Mac の UDP パケット。「映像はこの宛先（送ってきた IP とポート）に送って」と知らせる。
///
/// `| 種類 0x20 | カウンタ UInt64 BE | 認証コード 16 バイト |`
///
/// - 認証コードは、映像用の鍵による HMAC-SHA256 の先頭 16 バイト。鍵を知らない第三者は作れない。
/// - カウンタは送るたびに増やす。Mac は前回より大きいものだけを受け付けるので、盗み見たパケットを
///   別の宛先から送り直して映像の送り先を奪う、といったことを防げる。
/// - iPhone は 1 秒ごとに送り直す。経路が変わったときや、ルーターの変換表が消えたときの備え。
public enum UDPRegistration {
    public static let packetType: UInt8 = 0x20
    public static let length = 1 + 8 + 16
    static let macLength = 16
    static let label = Data("macremote udp register v1".utf8)

    public static func make(counter: UInt64, videoKey: Data) -> Data {
        var w = ByteWriter()
        w.write(packetType)
        w.write(counter)
        let body = w.data
        return body + mac(body, videoKey: videoKey)
    }

    /// 正しい登録パケットならカウンタを返す。
    public static func verify(_ packet: Data, videoKey: Data) -> UInt64? {
        guard packet.count == length else { return nil }
        let bytes = Data(packet)
        guard bytes.first == packetType else { return nil }
        let body = bytes.prefix(9)
        let receivedMAC = bytes.suffix(macLength)
        guard CryptoPrimitives.constantTimeEquals(Data(receivedMAC), mac(Data(body), videoKey: videoKey)) else { return nil }
        var reader = ByteReader(Data(body))
        _ = try? reader.readUInt8()
        return try? reader.readUInt64()
    }

    private static func mac(_ body: Data, videoKey: Data) -> Data {
        Data(CryptoPrimitives.hmac(key: videoKey, data: label + body).prefix(macLength))
    }
}

/// Mac 側：登録パケットのカウンタが前回より大きいかを確かめる。
public struct UDPRegistrationVerifier: Sendable {
    private let videoKey: Data
    private var lastCounter: UInt64?

    public init(videoKey: Data) {
        self.videoKey = videoKey
    }

    /// 受け付けてよい登録パケットなら true。
    public mutating func accept(_ packet: Data) -> Bool {
        guard let counter = UDPRegistration.verify(packet, videoKey: videoKey) else { return false }
        if let lastCounter, counter <= lastCounter { return false }
        lastCounter = counter
        return true
    }
}
