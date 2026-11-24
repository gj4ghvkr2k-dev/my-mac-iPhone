import AppKit
import CoreGraphics
import RemoteCore

/// iPhone から届いた操作を、CGEvent で Mac に再現する。
///
/// 「アクセシビリティ」の許可がないと、イベントを送っても無視される。
/// メインキューから呼ぶこと。
final class InputInjector {
    /// 操作の対象にしているモニター。
    var display: DisplayGeometry

    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<MouseButton> = []
    private var heldKeys: Set<UInt16> = []
    private var scrollRemainder = (x: 0.0, y: 0.0)

    init(display: DisplayGeometry) {
        self.display = display
    }

    // MARK: マウス

    func move(_ move: PointerMove) {
        let target: (x: Double, y: Double)
        var delta = (x: 0.0, y: 0.0)
        switch move {
        case .absolute(let x, let y):
            target = display.globalPoint(normalizedX: x, normalizedY: y)
        case .relative(let dx, let dy):
            let current = cursorLocation()
            target = display.clamp(x: current.x + Double(dx), y: current.y + Double(dy))
            delta = (Double(dx), Double(dy))
        }

        let (type, button) = dragState()
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: CGPoint(x: target.x, y: target.y), mouseButton: button) else { return }
        // ゲームなど、移動量を直接読むアプリのために入れておく。
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        event.post(tap: .cghidEventTap)
    }

    func button(_ input: PointerButton) {
        let location = cursorLocation()
        let (type, cgButton) = Self.eventType(for: input.button, isDown: input.isDown)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: CGPoint(x: location.x, y: location.y), mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, input.clickCount)))
        if input.button == .middle {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
        }
        event.post(tap: .cghidEventTap)
        if input.isDown { buttonsDown.insert(input.button) } else { buttonsDown.remove(input.button) }
    }

    func scroll(_ input: Scroll) {
        // 1 ピクセル未満の量は、次に回す。
        let totalX = scrollRemainder.x + Double(input.dx)
        let totalY = scrollRemainder.y + Double(input.dy)
        let stepX = min(max(totalX.rounded(.towardZero), -10_000), 10_000)
        let stepY = min(max(totalY.rounded(.towardZero), -10_000), 10_000)
        scrollRemainder = (totalX - stepX, totalY - stepY)
        if input.phase == .ended || input.phase == .momentumEnded { scrollRemainder = (0, 0) }

        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(stepY), wheel2: Int32(stepX), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let (scrollPhase, momentumPhase) = Self.phases(input.phase)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.post(tap: .cghidEventTap)
    }

    /// 今のカーソルの位置（グローバル座標）。
    func cursorLocation() -> (x: Double, y: Double) {
        let point = CGEvent(source: nil)?.location ?? .zero
        return (Double(point.x), Double(point.y))
    }

    // MARK: キーボード

    func key(_ input: KeyEvent) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(input.keyCode), keyDown: input.isDown) else { return }
        event.flags = Self.flags(input.modifiers)
        event.post(tap: .cghidEventTap)
        if input.isDown { heldKeys.insert(input.keyCode) } else { heldKeys.remove(input.keyCode) }
    }

    /// 確定した文字列を入力する。改行とタブは、それぞれのキーとして送る。
    func type(_ text: String) {
        var pending: [UniChar] = []
        func flush() {
            // 1 つのイベントで送れる文字数には上限があるので、20 文字ずつに分ける。
            var index = 0
            while index < pending.count {
                let chunk = Array(pending[index..<min(index + 20, pending.count)])
                for isDown in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                    event.flags = []
                    chunk.withUnsafeBufferPointer { buffer in
                        event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                    }
                    event.post(tap: .cghidEventTap)
                }
                index += 20
            }
            pending.removeAll()
        }

        for character in text {
            switch character {
            case "\n", "\r", "\r\n":
                flush()
                tap(keyCode: KeyCode.returnKey)
            case "\t":
                flush()
                tap(keyCode: KeyCode.tab)
            default:
                pending.append(contentsOf: String(character).utf16)
            }
        }
        flush()
    }

    // MARK: 決まった操作

    func perform(_ action: RemoteAction) {
        switch action {
        case .missionControl:
            // キーボードショートカットは利用者が変えている場合があるので、アプリを直接開く。
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .previousDesktop:
            tap(keyCode: KeyCode.leftArrow, modifiers: [.control])
        case .nextDesktop:
            tap(keyCode: KeyCode.rightArrow, modifiers: [.control])
        case .spotlight:
            tap(keyCode: KeyCode.space, modifiers: [.command])
        case .showDesktop:
            tap(keyCode: KeyCode.f11)
        }
    }

    /// 押したままのボタンやキーをすべて離す（切断したときなど）。
    func releaseAll() {
        for button in buttonsDown {
            self.button(PointerButton(button: button, isDown: false))
        }
        for keyCode in heldKeys {
            key(KeyEvent(keyCode: keyCode, isDown: false))
        }
        buttonsDown.removeAll()
        heldKeys.removeAll()
    }

    // MARK: - 内部

    private func tap(keyCode: UInt16, modifiers: KeyModifiers = []) {
        key(KeyEvent(keyCode: keyCode, isDown: true, modifiers: modifiers))
        key(KeyEvent(keyCode: keyCode, isDown: false, modifiers: modifiers))
    }

    private func dragState() -> (CGEventType, CGMouseButton) {
        if buttonsDown.contains(.left) { return (.leftMouseDragged, .left) }
        if buttonsDown.contains(.right) { return (.rightMouseDragged, .right) }
        if buttonsDown.contains(.middle) { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    private static func eventType(for button: MouseButton, isDown: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case .left: return (isDown ? .leftMouseDown : .leftMouseUp, .left)
        case .right: return (isDown ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: return (isDown ? .otherMouseDown : .otherMouseUp, .center)
        }
    }

    static func flags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        return flags
    }

    /// スクロールの段階を、CGEvent の値（CGScrollPhase と CGMomentumScrollPhase）にする。
    private static func phases(_ phase: ScrollPhase) -> (Int64, Int64) {
        switch phase {
        case .none: return (0, 0)
        case .began: return (1, 0)          // kCGScrollPhaseBegan
        case .changed: return (2, 0)        // kCGScrollPhaseChanged
        case .ended: return (4, 0)          // kCGScrollPhaseEnded
        case .momentumBegan: return (0, 1)  // kCGMomentumScrollPhaseBegin
        case .momentum: return (0, 2)       // kCGMomentumScrollPhaseContinue
        case .momentumEnded: return (0, 3)  // kCGMomentumScrollPhaseEnd
        }
    }
}

/// macOS の仮想キーコード（Carbon の kVK_*）のうち、このアプリで使うもの。
enum KeyCode {
    static let returnKey: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let space: UInt16 = 0x31
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let f11: UInt16 = 0x67
}
