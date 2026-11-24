import Foundation

/// 映像 1 フレーム分のデータ形式。
///
/// `| 長さ UInt32 BE | NAL ユニット | 長さ UInt32 BE | NAL ユニット | …`
///
/// キーフレームの先頭には、復元に必要なパラメータセットを必ず入れる。
/// - HEVC：VPS、SPS、PPS
/// - H.264：SPS、PPS
///
/// iPhone 側は、キーフレームのパラメータセットから映像の形式（CMVideoFormatDescription）を作り、
/// 残りの NAL ユニットを復元する。
public enum VideoBitstream {
    public static let lengthPrefixSize = 4

    /// NAL ユニットを長さ付きで並べる。
    public static func join(_ nalUnits: [Data]) -> Data {
        var w = ByteWriter()
        for nal in nalUnits {
            w.write(UInt32(nal.count))
            w.write(nal)
        }
        return w.data
    }

    /// 長さ付きの並びを NAL ユニットに分ける。
    ///
    /// - Parameter lengthSize: 長さの部分のバイト数。VideoToolbox の出力は通常 4 だが、1・2・4 のどれもありうる。
    public static func split(_ data: Data, lengthSize: Int = lengthPrefixSize) throws -> [Data] {
        guard [1, 2, 4].contains(lengthSize) else { throw RemoteCoreError.invalidValue("NAL length size \(lengthSize)") }
        var reader = ByteReader(data)
        var units: [Data] = []
        while reader.remainingCount > 0 {
            let length: Int
            switch lengthSize {
            case 1: length = Int(try reader.readUInt8())
            case 2: length = Int(try reader.readUInt16())
            default: length = Int(try reader.readUInt32())
            }
            guard length > 0 else { throw RemoteCoreError.invalidValue("empty NAL unit") }
            units.append(try reader.readBytes(length))
        }
        return units
    }

    /// NAL ユニットの種類の番号。
    public static func nalType(_ nal: Data, codec: VideoCodec) -> UInt8? {
        guard let first = nal.first else { return nil }
        switch codec {
        case .h264: return first & 0x1F
        case .hevc: return (first >> 1) & 0x3F
        }
    }

    /// パラメータセット（VPS／SPS／PPS）かどうか。
    public static func isParameterSet(_ nal: Data, codec: VideoCodec) -> Bool {
        guard let type = nalType(nal, codec: codec) else { return false }
        switch codec {
        case .h264: return type == 7 || type == 8
        case .hevc: return type == 32 || type == 33 || type == 34
        }
    }

    /// パラメータセットを、形式の作成に必要な順番（VPS → SPS → PPS）に並べて返す。
    /// 必要なものが揃っていなければ `nil`。
    public static func parameterSets(in nalUnits: [Data], codec: VideoCodec) -> [Data]? {
        let order: [UInt8] = codec == .hevc ? [32, 33, 34] : [7, 8]
        var found: [UInt8: Data] = [:]
        for nal in nalUnits {
            if let type = nalType(nal, codec: codec), order.contains(type), found[type] == nil {
                found[type] = nal
            }
        }
        let sets = order.compactMap { found[$0] }
        return sets.count == order.count ? sets : nil
    }
}
