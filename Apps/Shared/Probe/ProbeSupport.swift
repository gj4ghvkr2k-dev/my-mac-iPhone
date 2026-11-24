import Foundation

/// 検証用アプリ（M2）だけで使う UDP の往復確認パケット。
///
/// `| 種類 1B | 連番 UInt32 BE | 送信時刻 UInt64 BE（送った側の時計） |`
///
/// 種類 0x10 が iPhone → Mac、0x11 が Mac → iPhone（中身はそのまま返す）。
/// 映像パケット（先頭 0x01）と同じ UDP の通信路を使う。
enum ProbeDatagram {
    static let pingType: UInt8 = 0x10
    static let pongType: UInt8 = 0x11
    static let length = 13

    static func ping(sequence: UInt32, timestampMicros: UInt64) -> Data {
        var data = Data([pingType])
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampMicros.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// ping を受け取ったら、種類だけ書き換えて返す。
    static func pong(forPing ping: Data) -> Data? {
        guard ping.count == length, ping.first == pingType else { return nil }
        var pong = Data(ping)
        pong[pong.startIndex] = pongType
        return pong
    }

    /// pong から送信時刻を取り出す。
    static func timestamp(ofPong pong: Data) -> UInt64? {
        guard pong.count == length, pong.first == pongType else { return nil }
        let bytes = Data(pong)
        var value: UInt64 = 0
        for byte in bytes[5..<13] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}

/// 往復の遅延の統計。直近の値だけを残す。
struct LatencyStats {
    private(set) var samplesMillis: [Double] = []
    private(set) var totalCount = 0
    let capacity: Int

    init(capacity: Int = 300) {
        self.capacity = capacity
    }

    mutating func add(micros: UInt64) {
        samplesMillis.append(Double(micros) / 1000)
        if samplesMillis.count > capacity {
            samplesMillis.removeFirst(samplesMillis.count - capacity)
        }
        totalCount += 1
    }

    mutating func reset() {
        samplesMillis = []
        totalCount = 0
    }

    private func percentile(_ p: Double) -> Double? {
        guard !samplesMillis.isEmpty else { return nil }
        let sorted = samplesMillis.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[index]
    }

    var minimum: Double? { samplesMillis.min() }
    var median: Double? { percentile(0.5) }
    var p95: Double? { percentile(0.95) }
    var maximum: Double? { samplesMillis.max() }

    var summary: String {
        guard let minimum, let median, let p95, let maximum else { return "まだ計測していません" }
        return String(format: "最小 %.1f / 中央 %.1f / 95%% %.1f / 最大 %.1f ms（%ld 回）",
                      minimum, median, p95, maximum, totalCount)
    }
}

/// 1 秒ごとの量（フレーム数・バイト数など）を数える。
struct RateCounter {
    private var windowStart = monotonicMicros()
    private var count = 0
    private var bytes = 0
    private(set) var perSecond: Double = 0
    private(set) var megabitsPerSecond: Double = 0

    /// 1 秒たったら true を返し、`perSecond` などを更新する。
    mutating func add(bytes: Int) -> Bool {
        count += 1
        self.bytes += bytes
        return flushIfNeeded()
    }

    mutating func flushIfNeeded() -> Bool {
        let now = monotonicMicros()
        let elapsed = Double(now - windowStart) / 1_000_000
        guard elapsed >= 1 else { return false }
        perSecond = Double(count) / elapsed
        megabitsPerSecond = Double(bytes) * 8 / elapsed / 1_000_000
        windowStart = now
        count = 0
        bytes = 0
        return true
    }
}
