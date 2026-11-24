import Foundation

/// 長方形（iPhone の画面のポイント）。
public struct ViewRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// iPhone の画面に、Mac の映像をどの位置・大きさで表示するか。
///
/// - 拡大していないときは、縦横比を保って画面に収まる大きさで中央に表示する。
/// - ピンチで拡大し、パンで表示位置を動かせる。映像の端より外は見せない（映像が画面より小さい向きは中央に置く）。
/// - 拡大・移動は手元の表示だけで、Mac 側には影響しない。
public struct Viewport: Equatable, Sendable {
    public static let maxZoom = 6.0

    public var viewWidth: Double
    public var viewHeight: Double
    /// 映像の縦横比を決める大きさ（ピクセル数など、比が分かれば単位は問わない）。
    public var contentWidth: Double
    public var contentHeight: Double
    public private(set) var zoom: Double = 1
    /// 表示の中心にある映像上の位置（正規化。左上 (0,0)〜右下 (1,1)）。
    public private(set) var centerX: Double = 0.5
    public private(set) var centerY: Double = 0.5

    public init(viewWidth: Double, viewHeight: Double, contentWidth: Double, contentHeight: Double) {
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
    }

    /// 拡大していないときの、映像の大きさ。
    var fittedSize: (width: Double, height: Double) {
        guard contentWidth > 0, contentHeight > 0, viewWidth > 0, viewHeight > 0 else { return (0, 0) }
        let scale = min(viewWidth / contentWidth, viewHeight / contentHeight)
        return (contentWidth * scale, contentHeight * scale)
    }

    /// 映像を表示する長方形（画面の外にはみ出すこともある）。
    public var contentRect: ViewRect {
        let fitted = fittedSize
        let width = fitted.width * zoom
        let height = fitted.height * zoom
        return ViewRect(x: viewWidth / 2 - centerX * width, y: viewHeight / 2 - centerY * height,
                        width: width, height: height)
    }

    /// 画面上の点が、映像上のどこか（正規化）。映像の外なら端に寄せる。
    public func normalizedPoint(viewX: Double, viewY: Double) -> (x: Double, y: Double) {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let x = (viewX - rect.x) / rect.width
        let y = (viewY - rect.y) / rect.height
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// 映像上の位置（正規化）が、画面上のどこに表示されるか。
    public func viewPoint(normalizedX: Double, normalizedY: Double) -> (x: Double, y: Double) {
        let rect = contentRect
        return (rect.x + normalizedX * rect.width, rect.y + normalizedY * rect.height)
    }

    /// 画面上の 1 ポイントが、映像上の何ポイント分か（Mac の画面のポイント数を渡す）。
    public func contentPointsPerViewPoint(displayWidthPoints: Double) -> Double {
        let rect = contentRect
        guard rect.width > 0 else { return 1 }
        return displayWidthPoints / rect.width
    }

    /// 指定した点（画面上）を中心に、`factor` 倍する。
    public mutating func zoom(by factor: Double, aroundViewX viewX: Double, viewY: Double) {
        let anchor = normalizedPoint(viewX: viewX, viewY: viewY)
        let newZoom = min(max(zoom * factor, 1), Self.maxZoom)
        guard newZoom != zoom else { return }
        zoom = newZoom
        // 拡大の前後で、指の下の映像の位置が動かないようにする。
        let fitted = fittedSize
        let width = fitted.width * zoom
        let height = fitted.height * zoom
        if width > 0, height > 0 {
            centerX = anchor.x - (viewX - viewWidth / 2) / width
            centerY = anchor.y - (viewY - viewHeight / 2) / height
        }
        clampCenter()
    }

    /// 表示位置を、画面上で (dx, dy) だけ動かす（指の動きに合わせる）。
    public mutating func pan(byViewDX dx: Double, dy: Double) {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return }
        centerX -= dx / rect.width
        centerY -= dy / rect.height
        clampCenter()
    }

    /// 映像上の点（カーソルなど）が画面の端の `margin` より内側に入るよう、表示位置を動かす。
    public mutating func follow(normalizedX: Double, normalizedY: Double, margin: Double = 40) {
        guard zoom > 1 else { return }
        let point = viewPoint(normalizedX: normalizedX, normalizedY: normalizedY)
        var dx = 0.0
        var dy = 0.0
        let safeMargin = min(margin, viewWidth / 4, viewHeight / 4)
        if point.x < safeMargin { dx = safeMargin - point.x }
        if point.x > viewWidth - safeMargin { dx = (viewWidth - safeMargin) - point.x }
        if point.y < safeMargin { dy = safeMargin - point.y }
        if point.y > viewHeight - safeMargin { dy = (viewHeight - safeMargin) - point.y }
        if dx != 0 || dy != 0 { pan(byViewDX: dx, dy: dy) }
    }

    public mutating func reset() {
        zoom = 1
        centerX = 0.5
        centerY = 0.5
    }

    private mutating func clampCenter() {
        let fitted = fittedSize
        let width = fitted.width * zoom
        let height = fitted.height * zoom
        centerX = Self.clampedCenter(centerX, contentLength: width, viewLength: viewWidth)
        centerY = Self.clampedCenter(centerY, contentLength: height, viewLength: viewHeight)
    }

    /// 映像が画面より大きい向きは、端が画面の内側に入らない範囲に収める。小さい向きは中央に置く。
    private static func clampedCenter(_ center: Double, contentLength: Double, viewLength: Double) -> Double {
        guard contentLength > viewLength, contentLength > 0 else { return 0.5 }
        let half = viewLength / 2 / contentLength
        return min(max(center, half), 1 - half)
    }
}
