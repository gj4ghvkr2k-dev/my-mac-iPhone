import RemoteCore
import UIKit

/// 画面のキーボードからの入力を Mac に送る。
///
/// - 日本語などの変換は iPhone 側で行い、確定した文字列を `.text` として送る（変換中の文字は Mac に送らない）。
/// - 修飾キー（⌘ ⌥ ⌃ ⇧）を有効にしているときは、文字を US 配列のキーとして送る（⌘C など）。
/// - 修飾キーは 1 回押すと次の 1 文字だけ、2 回押すと解除するまで有効。
final class KeyboardBridge: NSObject, UITextFieldDelegate {
    enum ModifierState {
        case off
        case once
        case locked
    }

    var send: ((ControlMessage) -> Void)?
    /// キーボードの表示・非表示が変わった。
    var onVisibilityChange: ((Bool) -> Void)?

    let textField = KeyCaptureTextField()
    private var modifierStates: [KeyModifiers: ModifierState] = [:]
    private var modifierButtons: [KeyModifiers: UIButton] = [:]
    private var showsFunctionKeys = false
    private var functionRow: UIStackView?
    /// 変換中の文字を見せるラベル（テキストフィールド自体は見えないようにしているため）。
    private let compositionLabel = UILabel()

    override init() {
        super.init()
        textField.delegate = self
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.smartInsertDeleteType = .no
        textField.returnKeyType = .default
        textField.tintColor = .clear
        textField.textColor = .clear
        textField.backgroundColor = .clear
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        textField.onDeleteBackward = { [weak self] in self?.sendKey(MacKeyCode.delete) }
        textField.inputAccessoryView = makeAccessoryBar()
    }

    var isVisible: Bool { textField.isFirstResponder }

    func toggle() {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
        } else {
            textField.becomeFirstResponder()
        }
    }

    // MARK: UITextFieldDelegate

    func textFieldDidBeginEditing(_ textField: UITextField) {
        onVisibilityChange?(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onVisibilityChange?(false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendKey(MacKeyCode.returnKey)
        return false
    }

    @objc private func textChanged() {
        // 変換中（下線つきの文字がある間）は送らず、バーに表示だけする。
        if textField.markedTextRange != nil {
            compositionLabel.text = textField.text
            compositionLabel.isHidden = false
            return
        }
        compositionLabel.text = nil
        compositionLabel.isHidden = true
        guard let text = textField.text, !text.isEmpty else { return }
        textField.text = ""
        sendText(text)
    }

    // MARK: - 送信

    private func sendText(_ text: String) {
        let modifiers = activeModifiers
        guard !modifiers.isEmpty else {
            send?(.text(text))
            return
        }
        for character in text {
            if let key = KeyMapping.macKey(for: Character(character.lowercased())) {
                var flags = modifiers
                if character.isUppercase { flags.insert(.shift) }
                send?(.key(KeyEvent(keyCode: key.keyCode, isDown: true, modifiers: flags)))
                send?(.key(KeyEvent(keyCode: key.keyCode, isDown: false, modifiers: flags)))
            } else {
                send?(.text(String(character)))
            }
        }
        consumeOneShotModifiers()
    }

    func sendKey(_ keyCode: UInt16, extraModifiers: KeyModifiers = []) {
        let flags = activeModifiers.union(extraModifiers)
        send?(.key(KeyEvent(keyCode: keyCode, isDown: true, modifiers: flags)))
        send?(.key(KeyEvent(keyCode: keyCode, isDown: false, modifiers: flags)))
        consumeOneShotModifiers()
    }

    private var activeModifiers: KeyModifiers {
        var result: KeyModifiers = []
        for (modifier, state) in modifierStates where state != .off {
            result.insert(modifier)
        }
        return result
    }

    private func consumeOneShotModifiers() {
        for (modifier, state) in modifierStates where state == .once {
            modifierStates[modifier] = .off
        }
        refreshModifierButtons()
    }

    // MARK: - 特殊キーのバー

    private func makeAccessoryBar() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        bar.allowsSelfSizing = true

        let mainRow = UIStackView()
        mainRow.spacing = 6
        let modifierKeys: [(String, KeyModifiers)] = [("⌘", .command), ("⌥", .option), ("⌃", .control), ("⇧", .shift)]
        for (title, modifier) in modifierKeys {
            let button = makeKey(title) { [weak self] in self?.toggleModifier(modifier) }
            modifierButtons[modifier] = button
            mainRow.addArrangedSubview(button)
        }
        mainRow.addArrangedSubview(makeKey("esc") { [weak self] in self?.sendKey(MacKeyCode.escape) })
        mainRow.addArrangedSubview(makeKey("tab") { [weak self] in self?.sendKey(MacKeyCode.tab) })
        mainRow.addArrangedSubview(makeKey("⌦") { [weak self] in self?.sendKey(MacKeyCode.forwardDelete) })
        let arrowKeys: [(String, UInt16)] = [("arrow.left", MacKeyCode.leftArrow), ("arrow.up", MacKeyCode.upArrow),
                                             ("arrow.down", MacKeyCode.downArrow), ("arrow.right", MacKeyCode.rightArrow)]
        for (symbol, code) in arrowKeys {
            mainRow.addArrangedSubview(makeKey(systemImage: symbol) { [weak self] in self?.sendKey(code) })
        }
        mainRow.addArrangedSubview(makeKey("fn") { [weak self] in self?.toggleFunctionRow() })
        mainRow.addArrangedSubview(makeKey(systemImage: "magnifyingglass") { [weak self] in
            self?.send?(.action(.spotlight))
        })
        mainRow.addArrangedSubview(makeKey("英数") { [weak self] in self?.sendKey(MacKeyCode.jisEisu) })
        mainRow.addArrangedSubview(makeKey("かな") { [weak self] in self?.sendKey(MacKeyCode.jisKana) })
        mainRow.addArrangedSubview(makeKey(systemImage: "keyboard.chevron.compact.down") { [weak self] in
            self?.textField.resignFirstResponder()
        })

        let functionRow = UIStackView()
        functionRow.spacing = 6
        for (index, code) in MacKeyCode.functionKeys.enumerated() {
            functionRow.addArrangedSubview(makeKey("F\(index + 1)") { [weak self] in self?.sendKey(code) })
        }
        functionRow.isHidden = true
        self.functionRow = functionRow

        compositionLabel.font = .preferredFont(forTextStyle: .body)
        compositionLabel.textAlignment = .center
        compositionLabel.isHidden = true
        compositionLabel.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let rows = UIStackView(arrangedSubviews: [compositionLabel, scrollable(functionRow), scrollable(mainRow)])
        rows.axis = .vertical
        rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rows.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            rows.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
        ])
        return bar
    }

    private func scrollable(_ row: UIStackView) -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 40),
        ])
        // 隠した行は高さを取らない。
        scroll.isHidden = row.isHidden
        return scroll
    }

    private func makeKey(_ title: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        if let systemImage { configuration.image = UIImage(systemName: systemImage) }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return button
    }

    private func toggleModifier(_ modifier: KeyModifiers) {
        switch modifierStates[modifier] ?? .off {
        case .off: modifierStates[modifier] = .once
        case .once: modifierStates[modifier] = .locked
        case .locked: modifierStates[modifier] = .off
        }
        refreshModifierButtons()
    }

    private func refreshModifierButtons() {
        for (modifier, button) in modifierButtons {
            var configuration = button.configuration ?? .gray()
            switch modifierStates[modifier] ?? .off {
            case .off:
                configuration.baseBackgroundColor = nil
                configuration.baseForegroundColor = .label
            case .once:
                configuration.baseBackgroundColor = .systemBlue.withAlphaComponent(0.35)
                configuration.baseForegroundColor = .label
            case .locked:
                configuration.baseBackgroundColor = .systemBlue
                configuration.baseForegroundColor = .white
            }
            button.configuration = configuration
        }
    }

    private func toggleFunctionRow() {
        showsFunctionKeys.toggle()
        functionRow?.superview?.isHidden = !showsFunctionKeys
        functionRow?.isHidden = !showsFunctionKeys
        textField.inputAccessoryView?.invalidateIntrinsicContentSize()
        textField.reloadInputViews()
    }
}

/// 中身が空のときの ⌫ も拾えるテキストフィールド。
final class KeyCaptureTextField: UITextField {
    var onDeleteBackward: (() -> Void)?

    override func deleteBackward() {
        if (text ?? "").isEmpty && markedTextRange == nil {
            onDeleteBackward?()
        }
        super.deleteBackward()
    }

    // 選択やコピーのメニューを出さない。
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}
