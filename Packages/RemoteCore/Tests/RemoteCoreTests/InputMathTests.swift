import Foundation
import Testing
@testable import RemoteCore

@Suite("キー対応表")
struct KeyMappingTests {
    @Test("外付けキーボードの主なキー")
    func hidUsages() {
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x04) == 0x00) // a
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x1D) == 0x06) // z
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x1E) == 0x12) // 1
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x27) == 0x1D) // 0
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x28) == MacKeyCode.returnKey)
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x2A) == MacKeyCode.delete)
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x3A) == 0x7A) // F1
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x45) == 0x6F) // F12
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x52) == MacKeyCode.upArrow)
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0xE3) == MacKeyCode.command)
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x90) == MacKeyCode.jisKana)
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0x91) == MacKeyCode.jisEisu)
        #expect(KeyMapping.macKeyCode(forHIDUsage: 0xFFFF) == nil)
    }

    @Test("文字から US 配列のキーへ")
    func characters() {
        #expect(KeyMapping.macKey(for: "c")! == (0x08, false))
        #expect(KeyMapping.macKey(for: "C")! == (0x08, true))
        #expect(KeyMapping.macKey(for: "5")! == (0x17, false))
        #expect(KeyMapping.macKey(for: "%")! == (0x17, true))
        #expect(KeyMapping.macKey(for: "?")! == (0x2C, true))
        #expect(KeyMapping.macKey(for: " ")! == (MacKeyCode.space, false))
        #expect(KeyMapping.macKey(for: "あ") == nil)
    }

    @Test("修飾キーの判定")
    func modifiers() {
        #expect(KeyMapping.modifier(forMacKeyCode: MacKeyCode.rightCommand) == .command)
        #expect(KeyMapping.modifier(forMacKeyCode: MacKeyCode.shift) == .shift)
        #expect(KeyMapping.modifier(forMacKeyCode: 0x00) == nil)
    }
}

@Suite("ポインターと慣性スクロール")
struct PointerMathTests {
    @Test("ゆっくり動かすと等倍、速く動かすと大きく動く")
    func acceleration() {
        let curve = PointerAcceleration(sensitivity: 1, acceleration: 1)
        let slow = curve.transform(dx: 2, dy: 0, elapsed: 0.016)   // 125 pt/s
        let fast = curve.transform(dx: 30, dy: 0, elapsed: 0.016)  // 1875 pt/s
        #expect(slow.dx == 3)               // 1.5 倍
        #expect(fast.dx / 30 > slow.dx / 2) // 速いほど倍率が大きい
        #expect(fast.dx / 30 <= 1.5 * 4)    // 上限
        #expect(curve.transform(dx: 0, dy: 0, elapsed: 0.016) == (0, 0))
    }

    @Test("慣性スクロールは減速して止まる")
    func momentum() {
        var momentum = MomentumScroll(velocityX: 0, velocityY: 2000)
        var total = 0.0
        var steps = 0
        while !momentum.isFinished && steps < 1000 {
            total += momentum.step(elapsed: 1.0 / 60).dy
            steps += 1
        }
        #expect(momentum.isFinished)
        #expect(steps < 200)            // 3 秒ほどで止まる
        #expect(total > 300 && total < 2000)
    }
}

@Suite("拡大表示の計算")
struct ViewportTests {
    // iPhone の横向き（852×393）に、16:10 の Mac の映像
    func makeViewport() -> Viewport {
        Viewport(viewWidth: 852, viewHeight: 393, contentWidth: 2560, contentHeight: 1600)
    }

    @Test("拡大していないときは、縦横比を保って中央に収める")
    func fitted() {
        let viewport = makeViewport()
        let rect = viewport.contentRect
        #expect(abs(rect.height - 393) < 0.001)
        #expect(abs(rect.width - 628.8) < 0.001)
        #expect(abs(rect.midX - 426) < 0.001)
        let center = viewport.normalizedPoint(viewX: 426, viewY: 196.5)
        #expect(abs(center.x - 0.5) < 0.001 && abs(center.y - 0.5) < 0.001)
        // 映像の外（左の余白）を触ったら、左端に寄せる
        #expect(viewport.normalizedPoint(viewX: 10, viewY: 196.5).x == 0)
    }

    @Test("ピンチの中心にある映像の位置は、拡大しても動かない")
    func zoomAroundAnchor() {
        var viewport = makeViewport()
        let before = viewport.normalizedPoint(viewX: 500, viewY: 250)
        viewport.zoom(by: 2, aroundViewX: 500, viewY: 250)
        #expect(viewport.zoom == 2)
        let after = viewport.normalizedPoint(viewX: 500, viewY: 250)
        #expect(abs(before.x - after.x) < 0.0001 && abs(before.y - after.y) < 0.0001)
    }

    @Test("拡大率は 1〜6 倍、表示は映像の外に出ない")
    func clamping() {
        var viewport = makeViewport()
        viewport.zoom(by: 0.5, aroundViewX: 426, viewY: 196)
        #expect(viewport.zoom == 1)
        viewport.zoom(by: 100, aroundViewX: 426, viewY: 196)
        #expect(viewport.zoom == Viewport.maxZoom)

        viewport.pan(byViewDX: 100_000, dy: 100_000) // 左上の端まで
        let rect = viewport.contentRect
        #expect(abs(rect.x) < 0.001 && abs(rect.y) < 0.001)
    }

    @Test("拡大中は、カーソルが画面の端に近づくと表示を動かす")
    func followCursor() {
        var viewport = makeViewport()
        viewport.zoom(by: 3, aroundViewX: 426, viewY: 196)
        viewport.follow(normalizedX: 0.95, normalizedY: 0.5)
        let point = viewport.viewPoint(normalizedX: 0.95, normalizedY: 0.5)
        #expect(point.x <= 852 - 40 + 0.001)

        var unzoomed = makeViewport()
        let before = unzoomed.contentRect
        unzoomed.follow(normalizedX: 1, normalizedY: 1)
        #expect(unzoomed.contentRect == before)
    }
}
