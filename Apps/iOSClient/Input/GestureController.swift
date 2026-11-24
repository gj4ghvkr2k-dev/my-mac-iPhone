import QuartzCore
import RemoteCore
import UIKit

/// 操作モード。
enum InputMode: String {
    /// 画面全体をトラックパッドのように使う（指の動きでカーソルが動く）。iPhone の初期値。
    case trackpad
    /// 触った位置を直接クリックする。iPad の初期値。
    case direct

    static var deviceDefault: InputMode {
        UIDevice.current.userInterfaceIdiom == .pad ? .direct : .trackpad
    }
}

/// タッチ操作を、Mac へのメッセージに変える。
///
/// | 操作 | トラックパッドモード | 直接タッチモード |
/// |---|---|---|
/// | 1 本指タップ | 左クリック | その位置を左クリック |
/// | 2 本指タップ | 右クリック | その位置を右クリック |
/// | 1 本指ドラッグ | カーソル移動 | その位置からドラッグ |
/// | 長押しして動かす | ドラッグ | （長押し）その位置を右クリック |
/// | 2 本指ドラッグ | スクロール（離すと慣性） | 同じ |
/// | ピンチ | 手元の表示を拡大・移動 | 同じ |
/// | 3 本指スワイプ | 左右：デスクトップ切り替え、上：Mission Control | 同じ |
final class GestureController: NSObject, UIGestureRecognizerDelegate {
    var mode: InputMode
    var acceleration = PointerAcceleration()
    /// 2 本指スクロールの倍率（iPhone の 1 ポイントを Mac の何ピクセルにするか）。
    var scrollScale = 1.6

    /// Mac に送る。
    var send: ((ControlMessage) -> Void)?
    /// 表示位置の計算（拡大率など）。読み書きのたびに、呼び出し側でビューの配置を更新する。
    var getViewport: (() -> Viewport)?
    var setViewport: ((Viewport) -> Void)?
    /// 何か操作が始まった（ツールバーを隠すなどに使う）。
    var onInteraction: (() -> Void)?

    private weak var view: UIView?

    // クリックの回数（ダブルクリックの判定）
    private var lastClickTime: CFTimeInterval = 0
    private var lastClickPoint: CGPoint = .zero
    private var clickCount: UInt8 = 0

    // 1 本指の移動
    private var lastPanTranslation: CGPoint = .zero
    private var lastPanTime: CFTimeInterval = 0
    private var directDragging = false

    // 長押しドラッグ
    private var lastLongPressLocation: CGPoint = .zero
    private var lastLongPressTime: CFTimeInterval = 0

    // スクロール
    private var lastScrollTranslation: CGPoint = .zero
    private var scrolling = false
    private var momentum: MomentumScroll?
    private var momentumLink: CADisplayLink?
    private var momentumStarted = false
    private var lastMomentumTime: CFTimeInterval = 0

    // ピンチ
    private var lastPinchScale: CGFloat = 1
    private var lastPinchLocation: CGPoint = .zero
    private var pinchActive = false

    // iPad のポインター
    private var pointerScrollTranslation: CGPoint = .zero

    init(mode: InputMode) {
        self.mode = mode
    }

    func attach(to view: UIView) {
        self.view = view
        view.isMultipleTouchEnabled = true
        let touchTypes = [UITouch.TouchType.direct.rawValue, UITouch.TouchType.pencil.rawValue].map { NSNumber(value: $0) }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = touchTypes
        view.addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = touchTypes
        view.addGestureRecognizer(twoFingerTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = touchTypes
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowedTouchTypes = touchTypes
        longPress.delegate = self
        view.addGestureRecognizer(longPress)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedTouchTypes = touchTypes
        scroll.delegate = self
        view.addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let swipes: [(UISwipeGestureRecognizer.Direction, RemoteAction)] = [
            (.left, .nextDesktop), (.right, .previousDesktop), (.up, .missionControl),
        ]
        for (direction, action) in swipes {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.numberOfTouchesRequired = 3
            swipe.direction = direction
            swipe.name = String(action.rawValue)
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }

        attachPointerGestures(to: view)
    }

    // MARK: - タップ

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        stopMomentum()
        onInteraction?()
        let point = recognizer.location(in: view)
        if mode == .direct { moveAbsolute(to: point) }
        click(.left, at: point)
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        stopMomentum()
        let point = recognizer.location(in: view)
        if mode == .direct { moveAbsolute(to: point) }
        click(.right, at: point)
    }

    private func click(_ button: MouseButton, at point: CGPoint) {
        let now = CACurrentMediaTime()
        let distance = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y)
        if button == .left, now - lastClickTime < 0.35, distance < 30, clickCount < 3 {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickPoint = point
        let count = button == .left ? clickCount : 1
        send?(.pointerButton(PointerButton(button: button, isDown: true, clickCount: count)))
        send?(.pointerButton(PointerButton(button: button, isDown: false, clickCount: count)))
    }

    // MARK: - 1 本指の移動

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let now = CACurrentMediaTime()
        switch recognizer.state {
        case .began:
            stopMomentum()
            onInteraction?()
            lastPanTranslation = .zero
            lastPanTime = now
            if mode == .direct {
                // 指を置いた位置からドラッグを始める。
                let start = recognizer.location(in: view)
                let translation = recognizer.translation(in: view)
                moveAbsolute(to: CGPoint(x: start.x - translation.x, y: start.y - translation.y))
                send?(.pointerButton(PointerButton(button: .left, isDown: true)))
                directDragging = true
                moveAbsolute(to: start)
            }
        case .changed:
            if mode == .direct {
                moveAbsolute(to: recognizer.location(in: view))
            } else {
                let translation = recognizer.translation(in: view)
                moveRelative(dx: translation.x - lastPanTranslation.x, dy: translation.y - lastPanTranslation.y,
                             elapsed: now - lastPanTime)
                lastPanTranslation = translation
                lastPanTime = now
            }
        case .ended, .cancelled, .failed:
            if directDragging {
                send?(.pointerButton(PointerButton(button: .left, isDown: false)))
                directDragging = false
            }
        default:
            break
        }
    }

    // MARK: - 長押し

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: view)
        let now = CACurrentMediaTime()
        switch (mode, recognizer.state) {
        case (.trackpad, .began):
            stopMomentum()
            lastLongPressLocation = point
            lastLongPressTime = now
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            send?(.pointerButton(PointerButton(button: .left, isDown: true)))
        case (.trackpad, .changed):
            moveRelative(dx: point.x - lastLongPressLocation.x, dy: point.y - lastLongPressLocation.y,
                         elapsed: now - lastLongPressTime)
            lastLongPressLocation = point
            lastLongPressTime = now
        case (.trackpad, .ended), (.trackpad, .cancelled), (.trackpad, .failed):
            send?(.pointerButton(PointerButton(button: .left, isDown: false)))
        case (.direct, .began):
            guard !directDragging else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            moveAbsolute(to: point)
            click(.right, at: point)
        default:
            break
        }
    }

    // MARK: - スクロール

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        switch recognizer.state {
        case .began:
            stopMomentum()
            onInteraction?()
            lastScrollTranslation = .zero
            scrolling = !pinchActive
            if scrolling { sendScroll(dx: 0, dy: 0, phase: .began) }
            lastScrollTranslation = translation
        case .changed:
            guard scrolling, !pinchActive else { return }
            // 指の動きと同じ向きに中身が動く（Mac の「ナチュラル」なスクロールと同じ）。
            sendScroll(dx: translation.x - lastScrollTranslation.x, dy: translation.y - lastScrollTranslation.y,
                       phase: .changed)
            lastScrollTranslation = translation
        case .ended, .cancelled, .failed:
            guard scrolling else { return }
            scrolling = false
            sendScroll(dx: 0, dy: 0, phase: .ended)
            let velocity = recognizer.velocity(in: view)
            if recognizer.state == .ended, !pinchActive, hypot(velocity.x, velocity.y) > 200 {
                startMomentum(velocityX: velocity.x, velocityY: velocity.y)
            }
        default:
            break
        }
    }

    private func sendScroll(dx: CGFloat, dy: CGFloat, phase: ScrollPhase) {
        send?(.scroll(Scroll(dx: Float(dx * scrollScale), dy: Float(dy * scrollScale), phase: phase)))
    }

    private func startMomentum(velocityX: CGFloat, velocityY: CGFloat) {
        momentum = MomentumScroll(velocityX: Double(velocityX), velocityY: Double(velocityY))
        momentumStarted = false
        lastMomentumTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        guard var momentum else { stopMomentum(); return }
        let now = CACurrentMediaTime()
        let delta = momentum.step(elapsed: now - lastMomentumTime)
        lastMomentumTime = now
        self.momentum = momentum
        if momentum.isFinished {
            stopMomentum()
            return
        }
        sendScroll(dx: CGFloat(delta.dx), dy: CGFloat(delta.dy), phase: momentumStarted ? .momentum : .momentumBegan)
        momentumStarted = true
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        if momentum != nil, momentumStarted {
            sendScroll(dx: 0, dy: 0, phase: .momentumEnded)
        }
        momentum = nil
        momentumStarted = false
    }

    // MARK: - ピンチ（手元の表示の拡大・移動）

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let view, var viewport = getViewport?() else { return }
        let location = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            stopMomentum()
            lastPinchScale = recognizer.scale
            lastPinchLocation = location
            pinchActive = false
        case .changed:
            // 少し指を広げた（狭めた）ところで、スクロールではなく拡大として扱う。
            if !pinchActive, abs(recognizer.scale - 1) > 0.06 {
                pinchActive = true
                if scrolling {
                    scrolling = false
                    sendScroll(dx: 0, dy: 0, phase: .ended)
                }
            }
            guard pinchActive else { return }
            viewport.pan(byViewDX: Double(location.x - lastPinchLocation.x), dy: Double(location.y - lastPinchLocation.y))
            viewport.zoom(by: Double(recognizer.scale / lastPinchScale), aroundViewX: Double(location.x), viewY: Double(location.y))
            lastPinchScale = recognizer.scale
            lastPinchLocation = location
            setViewport?(viewport)
        default:
            pinchActive = false
        }
    }

    // MARK: - 3 本指スワイプ

    @objc private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended, let name = recognizer.name, let raw = UInt8(name),
              let action = RemoteAction(rawValue: raw) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        send?(.action(action))
    }

    // MARK: - iPad のトラックパッド・マウス

    private func attachPointerGestures(to view: UIView) {
        // ポインターを動かしただけ（ボタンを押していない）とき。
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        view.addGestureRecognizer(hover)

        let pointerTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

        let click = UITapGestureRecognizer(target: self, action: #selector(handlePointerClick(_:)))
        click.allowedTouchTypes = pointerTypes
        click.buttonMaskRequired = .primary
        view.addGestureRecognizer(click)

        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(handlePointerSecondaryClick(_:)))
        secondaryClick.allowedTouchTypes = pointerTypes
        secondaryClick.buttonMaskRequired = .secondary
        view.addGestureRecognizer(secondaryClick)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handlePointerDrag(_:)))
        drag.allowedTouchTypes = pointerTypes
        drag.delegate = self
        view.addGestureRecognizer(drag)

        // 2 本指のスクロール（トラックパッド）やホイール。
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handlePointerScroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheel.delegate = self
        view.addGestureRecognizer(wheel)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        moveAbsolute(to: recognizer.location(in: view))
    }

    @objc private func handlePointerClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: view)
        moveAbsolute(to: point)
        click(.left, at: point)
    }

    @objc private func handlePointerSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: view)
        moveAbsolute(to: point)
        click(.right, at: point)
    }

    @objc private func handlePointerDrag(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            let translation = recognizer.translation(in: view)
            moveAbsolute(to: CGPoint(x: point.x - translation.x, y: point.y - translation.y))
            send?(.pointerButton(PointerButton(button: .left, isDown: true)))
            moveAbsolute(to: point)
        case .changed:
            moveAbsolute(to: point)
        case .ended, .cancelled, .failed:
            send?(.pointerButton(PointerButton(button: .left, isDown: false)))
        default:
            break
        }
    }

    @objc private func handlePointerScroll(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        switch recognizer.state {
        case .began:
            pointerScrollTranslation = translation
            sendScroll(dx: 0, dy: 0, phase: .began)
        case .changed:
            sendScroll(dx: translation.x - pointerScrollTranslation.x, dy: translation.y - pointerScrollTranslation.y,
                       phase: .changed)
            pointerScrollTranslation = translation
        case .ended, .cancelled, .failed:
            sendScroll(dx: 0, dy: 0, phase: .ended)
        default:
            break
        }
    }

    // MARK: - 補助

    private func moveAbsolute(to point: CGPoint) {
        guard let viewport = getViewport?() else { return }
        let normalized = viewport.normalizedPoint(viewX: Double(point.x), viewY: Double(point.y))
        send?(.pointerMove(.absolute(x: Float(normalized.x), y: Float(normalized.y))))
    }

    private func moveRelative(dx: CGFloat, dy: CGFloat, elapsed: CFTimeInterval) {
        let moved = acceleration.transform(dx: Double(dx), dy: Double(dy), elapsed: elapsed)
        guard moved.dx != 0 || moved.dy != 0 else { return }
        send?(.pointerMove(.relative(dx: Float(moved.dx), dy: Float(moved.dy))))
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // ピンチと 2 本指スクロールは同時に判定し、どちらかは pinchActive で決める。
        let pair = [gestureRecognizer, other]
        let hasPinch = pair.contains { $0 is UIPinchGestureRecognizer }
        let hasTwoFingerPan = pair.contains { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
        return hasPinch && hasTwoFingerPan
    }
}
