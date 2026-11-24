import Foundation

/// トラックパッドモードで、指の動きをカーソルの移動量にする。
///
/// 指をゆっくり動かすと細かく、速く動かすと大きく動く（Mac のトラックパッドと同じ考え方）。
public struct PointerAcceleration: Equatable, Sendable {
    /// 全体の速さ（1 が標準）。
    public var sensitivity: Double
    /// 速く動かしたときにどれだけ大きくするか（0 なら加速しない）。
    public var acceleration: Double

    public init(sensitivity: Double = 1.0, acceleration: Double = 1.2) {
        self.sensitivity = sensitivity
        self.acceleration = acceleration
    }

    /// - Parameters:
    ///   - dx, dy: 指の移動量（iPhone の画面のポイント）
    ///   - elapsed: 前回からの経過秒数
    /// - Returns: Mac のカーソルの移動量（Mac の画面のポイント）
    public func transform(dx: Double, dy: Double, elapsed: Double) -> (dx: Double, dy: Double) {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return (0, 0) }
        let speed = distance / max(elapsed, 0.001) // ポイント／秒
        // 300 ポイント／秒までは等倍、そこから速さに応じて最大 (1 + 3 × acceleration) 倍まで大きくする。
        let boost = 1 + acceleration * min(max((speed - 300) / 700, 0), 3)
        let gain = 1.5 * sensitivity * boost
        return (dx * gain, dy * gain)
    }
}

/// 2 本指のスクロールを離したあとの慣性スクロール。
public struct MomentumScroll: Equatable, Sendable {
    public private(set) var velocityX: Double
    public private(set) var velocityY: Double
    /// 1 秒あたりに速さが何倍になるか（小さいほど早く止まる）。
    public let decayPerSecond: Double

    public init(velocityX: Double, velocityY: Double, decayPerSecond: Double = 0.05) {
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.decayPerSecond = decayPerSecond
    }

    public var isFinished: Bool { abs(velocityX) < 20 && abs(velocityY) < 20 }

    /// `elapsed` 秒ぶん進め、その間のスクロール量を返す。
    public mutating func step(elapsed: Double) -> (dx: Double, dy: Double) {
        let delta = (velocityX * elapsed, velocityY * elapsed)
        let factor = pow(decayPerSecond, elapsed)
        velocityX *= factor
        velocityY *= factor
        return delta
    }
}
