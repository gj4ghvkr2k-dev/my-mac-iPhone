import Combine
import RemoteCore
import UIKit

/// Mac の画面を表示して操作する画面。
final class RemoteViewController: UIViewController {
    private let session: RemoteSession
    private let onClose: () -> Void

    private let videoView = VideoRenderView()
    private let inputSurface = UIView()
    private let toolbar = UIStackView()
    private let toolbarContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let statsLabel = UILabel()
    private let statusView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let statusLabel = UILabel()
    private let statusSpinner = UIActivityIndicatorView(style: .large)
    private let statusButton = UIButton(configuration: .filled())
    private var modeButton: UIButton?
    private var displayButton: UIButton?
    private var qualityButton: UIButton?

    private let gestures: GestureController
    private let keyboard = KeyboardBridge()
    private var renderer: VideoFrameRenderer?
    private var viewport = Viewport(viewWidth: 1, viewHeight: 1, contentWidth: 16, contentHeight: 10)
    private var cancellables: Set<AnyCancellable> = []

    init(session: RemoteSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        self.gestures = GestureController(mode: Self.savedMode)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - 画面の準備

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        view.addSubview(videoView)

        inputSurface.frame = view.bounds
        inputSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        inputSurface.backgroundColor = .clear
        view.addSubview(inputSurface)

        // キーボード入力を受けるテキストフィールド（見えないように小さく置く）。
        keyboard.textField.frame = CGRect(x: -10, y: -10, width: 1, height: 1)
        view.addSubview(keyboard.textField)
        keyboard.send = { [weak self] message in self?.session.send(message) }
        keyboard.onVisibilityChange = { [weak self] visible in
            // 画面のキーボードを閉じたら、外付けキーボードのキーをまた直接受け取る。
            if !visible { self?.becomeFirstResponder() }
        }

        gestures.send = { [weak self] message in self?.session.send(message) }
        gestures.getViewport = { [weak self] in self?.viewport ?? Viewport(viewWidth: 1, viewHeight: 1, contentWidth: 1, contentHeight: 1) }
        gestures.setViewport = { [weak self] viewport in
            self?.viewport = viewport
            self?.layoutVideo()
        }
        gestures.attach(to: inputSurface)

        setUpToolbar()
        setUpStatusView()
        bindSession()

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        session.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        // 外付けキーボードのキーを直接受け取れるようにする。
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        viewport.viewWidth = Double(view.bounds.width)
        viewport.viewHeight = Double(view.bounds.height)
        layoutVideo()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var canBecomeFirstResponder: Bool { true }

    private func layoutVideo() {
        let rect = viewport.contentRect
        videoView.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    // MARK: - 接続の状態

    private func bindSession() {
        session.onVideoReady = { [weak self] codec in
            guard let self else { return }
            let renderer = VideoFrameRenderer(codec: codec, view: self.videoView)
            renderer.onNeedsKeyFrame = { [weak self] in self?.session.requestKeyFrame() }
            renderer.onVideoSize = { [weak self] width, height in
                guard let self else { return }
                self.viewport.contentWidth = Double(width)
                self.viewport.contentHeight = Double(height)
                self.layoutVideo()
            }
            self.renderer = renderer
            if let display = self.session.activeDisplay {
                self.viewport.contentWidth = Double(display.widthPixels)
                self.viewport.contentHeight = Double(display.heightPixels)
                self.layoutVideo()
            }
        }
        session.onFrame = { [weak self] frame in self?.renderer?.render(frame) }
        session.onCursor = { [weak self] cursor in
            guard let self, cursor.isVisible, self.gestures.mode == .trackpad else { return }
            let before = self.viewport
            self.viewport.follow(normalizedX: Double(cursor.x), normalizedY: Double(cursor.y))
            if self.viewport != before { self.layoutVideo() }
        }

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.update(for: state) }
            .store(in: &cancellables)

        Publishers.CombineLatest(session.$framesPerSecond, session.$roundTripMillis)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fps, rtt in
                let latency = rtt.map { String(format: "%.0f ms", $0) } ?? "- ms"
                self?.statsLabel.text = String(format: "%.0f fps・", fps) + latency
            }
            .store(in: &cancellables)

        session.$displays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMenus() }
            .store(in: &cancellables)
    }

    private func update(for state: RemoteSession.State) {
        switch state {
        case .connecting:
            showStatus("\(session.hostName) に接続しています…", spinner: true, button: "キャンセル")
        case .pairing:
            showStatus("\(session.hostName) に登録しています…", spinner: true, button: "キャンセル")
        case .connected:
            statusView.isHidden = true
            toolbarContainer.isHidden = false
            refreshMenus()
        case .disconnected(let reason):
            renderer?.reset()
            showStatus(reason, spinner: false, button: "閉じる")
        }
    }

    private func showStatus(_ text: String, spinner: Bool, button: String) {
        statusLabel.text = text
        spinner ? statusSpinner.startAnimating() : statusSpinner.stopAnimating()
        statusButton.configuration?.title = button
        statusView.isHidden = false
        toolbarContainer.isHidden = true
    }

    private func setUpStatusView() {
        statusView.layer.cornerRadius = 20
        statusView.clipsToBounds = true
        statusView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusView)

        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusSpinner.color = .white
        statusButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusSpinner, statusLabel, statusButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusView.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            statusView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            statusView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: statusView.contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: statusView.contentView.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: statusView.contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: statusView.contentView.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - ツールバー

    private func setUpToolbar() {
        toolbarContainer.layer.cornerRadius = 18
        toolbarContainer.clipsToBounds = true
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.isHidden = true
        view.addSubview(toolbarContainer)

        toolbar.axis = .horizontal
        toolbar.spacing = 2
        toolbar.alignment = .center
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.contentView.addSubview(toolbar)

        toolbar.addArrangedSubview(toolButton("xmark", label: "切断") { [weak self] in self?.close() })
        toolbar.addArrangedSubview(toolButton("keyboard", label: "キーボード") { [weak self] in self?.keyboard.toggle() })

        let modeButton = toolButton(modeSymbol, label: "操作モード") { [weak self] in self?.toggleMode() }
        self.modeButton = modeButton
        toolbar.addArrangedSubview(modeButton)

        toolbar.addArrangedSubview(toolButton("arrow.down.right.and.arrow.up.left", label: "等倍に戻す") { [weak self] in
            self?.viewport.reset()
            self?.layoutVideo()
        })

        let displayButton = toolButton("display.2", label: "モニター") {}
        displayButton.showsMenuAsPrimaryAction = true
        self.displayButton = displayButton
        toolbar.addArrangedSubview(displayButton)

        let qualityButton = toolButton("slider.horizontal.3", label: "画質") {}
        qualityButton.showsMenuAsPrimaryAction = true
        self.qualityButton = qualityButton
        toolbar.addArrangedSubview(qualityButton)

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statsLabel.textColor = .white
        statsLabel.text = "- fps"
        toolbar.addArrangedSubview(statsLabel)

        NSLayoutConstraint.activate([
            toolbarContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            toolbarContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: toolbarContainer.contentView.topAnchor, constant: 2),
            toolbar.bottomAnchor.constraint(equalTo: toolbarContainer.contentView.bottomAnchor, constant: -2),
            toolbar.leadingAnchor.constraint(equalTo: toolbarContainer.contentView.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: toolbarContainer.contentView.trailingAnchor, constant: -12),
        ])
        refreshMenus()
    }

    private func toolButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImage)
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        return button
    }

    private var modeSymbol: String {
        gestures.mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left"
    }

    private func toggleMode() {
        gestures.mode = gestures.mode == .trackpad ? .direct : .trackpad
        Self.savedMode = gestures.mode
        modeButton?.configuration?.image = UIImage(systemName: modeSymbol)
        showToast(gestures.mode == .trackpad ? "トラックパッドモード" : "直接タッチモード")
    }

    private func refreshMenus() {
        let displayActions = session.displays.map { display in
            UIAction(title: display.name,
                     subtitle: "\(display.widthPixels)×\(display.heightPixels)",
                     state: display.id == session.activeDisplayID ? .on : .off) { [weak self] _ in
                self?.session.selectDisplay(display.id)
                self?.viewport.reset()
                self?.refreshMenus()
            }
        }
        displayButton?.menu = UIMenu(title: "表示するモニター", children: displayActions)
        displayButton?.isHidden = session.displays.count < 2

        let qualityActions = StreamQuality.allCases.map { quality in
            UIAction(title: quality.title, state: quality == session.quality ? .on : .off) { [weak self] _ in
                self?.session.quality = quality
                self?.refreshMenus()
            }
        }
        qualityButton?.menu = UIMenu(title: "画質", children: qualityActions)
    }

    private func showToast(_ text: String) {
        let label = PaddedLabel()
        label.text = text
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.2, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    // MARK: - 外付けキーボード（iPad）

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, isDown: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, isDown: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, isDown: false) { super.pressesCancelled(presses, with: event) }
    }

    /// 外付けキーボードのキーを、そのまま Mac のキーとして送る。日本語の変換は Mac 側で行う。
    private func handlePresses(_ presses: Set<UIPress>, isDown: Bool) -> Bool {
        guard session.state == .connected else { return false }
        var handled = false
        for press in presses {
            guard let key = press.key,
                  let keyCode = KeyMapping.macKeyCode(forHIDUsage: key.keyCode.rawValue) else { continue }
            handled = true
            // 修飾キーだけを押したときは送らず、ほかのキーと一緒に送る。
            if KeyMapping.modifier(forMacKeyCode: keyCode) != nil { continue }
            session.send(.key(KeyEvent(keyCode: keyCode, isDown: isDown, modifiers: Self.modifiers(key.modifierFlags))))
        }
        return handled
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alphaShift) { result.insert(.capsLock) }
        return result
    }

    // MARK: - 終了

    @objc private func appDidEnterBackground() {
        // バックグラウンドでは通信が止まるので、切断しておく。
        if case .disconnected = session.state { return }
        session.stop(reason: "アプリがバックグラウンドに移ったため、切断しました")
    }

    private func close() {
        if case .disconnected = session.state {} else {
            session.stop()
        }
        onClose()
    }

    private static var savedMode: InputMode {
        get {
            UserDefaults.standard.string(forKey: "inputMode").flatMap(InputMode.init(rawValue:)) ?? .deviceDefault
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "inputMode")
        }
    }
}

/// 余白つきのラベル（通知の表示用）。
private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 14, dy: 8))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 28, height: size.height + 16)
    }
}
