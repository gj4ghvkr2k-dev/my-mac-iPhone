import Foundation

/// Mac のモニター 1 台の位置と大きさ。
///
/// macOS のグローバル座標（ポイント単位。メインモニターの左上が原点で、下向きが +y）で表す。
/// CGEvent のマウス座標も同じ座標系。
public struct DisplayGeometry: Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    /// 正規化した位置（左上 (0,0)〜右下 (1,1)）を、グローバル座標に変換する。範囲外は端に寄せる。
    public func globalPoint(normalizedX: Float, normalizedY: Float) -> (x: Double, y: Double) {
        let nx = Double(min(max(normalizedX, 0), 1))
        let ny = Double(min(max(normalizedY, 0), 1))
        return clamp(x: originX + nx * width, y: originY + ny * height)
    }

    /// グローバル座標を、このモニター上の正規化した位置に変換する。
    public func normalized(x: Double, y: Double) -> (x: Float, y: Float) {
        guard width > 0, height > 0 else { return (0, 0) }
        return (Float((x - originX) / width), Float((y - originY) / height))
    }

    /// 位置を、このモニターの中に収める。右端・下端は 1 ポイント内側にする（外に出るとほかのモニターに移るため）。
    public func clamp(x: Double, y: Double) -> (x: Double, y: Double) {
        let maxX = originX + max(0, width - 1)
        let maxY = originY + max(0, height - 1)
        return (min(max(x, originX), maxX), min(max(y, originY), maxY))
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= originX && x < originX + width && y >= originY && y < originY + height
    }
}

/// 映像の大きさの計算。
public enum VideoSizing {
    /// 縦横比を保ったまま、長い辺が `maxLongEdge` 以下になる大きさを返す。
    ///
    /// - 拡大はしない。
    /// - 映像の圧縮処理の都合で、幅と高さは偶数にそろえる。
    public static func scaledSize(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let longEdge = max(width, height)
        let limit = max(2, maxLongEdge)
        let scale = longEdge > limit ? Double(limit) / Double(longEdge) : 1
        func even(_ value: Double) -> Int { max(2, Int(value.rounded(.down)) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }
}
