import Foundation

/// macOS の仮想キーコード（Carbon の kVK_*）。
public enum MacKeyCode {
    public static let a: UInt16 = 0x00
    public static let returnKey: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let delete: UInt16 = 0x33          // ⌫（Backspace）
    public static let escape: UInt16 = 0x35
    public static let command: UInt16 = 0x37
    public static let shift: UInt16 = 0x38
    public static let capsLock: UInt16 = 0x39
    public static let option: UInt16 = 0x3A
    public static let control: UInt16 = 0x3B
    public static let rightCommand: UInt16 = 0x36
    public static let rightShift: UInt16 = 0x3C
    public static let rightOption: UInt16 = 0x3D
    public static let rightControl: UInt16 = 0x3E
    public static let function: UInt16 = 0x3F
    public static let help: UInt16 = 0x72
    public static let home: UInt16 = 0x73
    public static let pageUp: UInt16 = 0x74
    public static let forwardDelete: UInt16 = 0x75   // ⌦
    public static let end: UInt16 = 0x77
    public static let pageDown: UInt16 = 0x79
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E
    public static let jisYen: UInt16 = 0x5D
    public static let jisUnderscore: UInt16 = 0x5E
    public static let jisEisu: UInt16 = 0x66          // 英数
    public static let jisKana: UInt16 = 0x68          // かな

    /// F1〜F12（添字 0 が F1）。
    public static let functionKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
}

public enum KeyMapping {
    // MARK: 外付けキーボード（HID の Usage ID → macOS のキーコード）

    /// iPad の外付けキーボードの HID Usage ID（`UIKeyboardHIDUsage` の rawValue）を、macOS のキーコードにする。
    public static func macKeyCode(forHIDUsage usage: Int) -> UInt16? {
        hidTable[usage]
    }

    /// 修飾キーのキーコードなら、その修飾キー。
    public static func modifier(forMacKeyCode keyCode: UInt16) -> KeyModifiers? {
        switch keyCode {
        case MacKeyCode.shift, MacKeyCode.rightShift: return .shift
        case MacKeyCode.control, MacKeyCode.rightControl: return .control
        case MacKeyCode.option, MacKeyCode.rightOption: return .option
        case MacKeyCode.command, MacKeyCode.rightCommand: return .command
        case MacKeyCode.function: return .function
        case MacKeyCode.capsLock: return .capsLock
        default: return nil
        }
    }

    private static let hidTable: [Int: UInt16] = {
        var table: [Int: UInt16] = [:]
        // a〜z（HID 0x04〜0x1D）
        let letters: [UInt16] = [
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // a〜m
            0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06, // n〜z
        ]
        for (index, code) in letters.enumerated() { table[0x04 + index] = code }
        // 1〜9、0（HID 0x1E〜0x27）
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (index, code) in digits.enumerated() { table[0x1E + index] = code }
        // F1〜F12（HID 0x3A〜0x45）
        for (index, code) in MacKeyCode.functionKeys.enumerated() { table[0x3A + index] = code }

        let others: [Int: UInt16] = [
            0x28: MacKeyCode.returnKey, 0x29: MacKeyCode.escape, 0x2A: MacKeyCode.delete, 0x2B: MacKeyCode.tab,
            0x2C: MacKeyCode.space, 0x2D: 0x1B /* - */, 0x2E: 0x18 /* = */, 0x2F: 0x21 /* [ */, 0x30: 0x1E /* ] */,
            0x31: 0x2A /* \ */, 0x32: 0x2A /* 非 US の # */, 0x33: 0x29 /* ; */, 0x34: 0x27 /* ' */, 0x35: 0x32 /* ` */,
            0x36: 0x2B /* , */, 0x37: 0x2F /* . */, 0x38: 0x2C /* / */, 0x39: MacKeyCode.capsLock,
            0x49: MacKeyCode.help, 0x4A: MacKeyCode.home, 0x4B: MacKeyCode.pageUp, 0x4C: MacKeyCode.forwardDelete,
            0x4D: MacKeyCode.end, 0x4E: MacKeyCode.pageDown, 0x4F: MacKeyCode.rightArrow, 0x50: MacKeyCode.leftArrow,
            0x51: MacKeyCode.downArrow, 0x52: MacKeyCode.upArrow,
            0x58: 0x4C /* テンキーの Enter */, 0x64: 0x0A /* 非 US の \ */,
            0x87: MacKeyCode.jisUnderscore, 0x89: MacKeyCode.jisYen, 0x90: MacKeyCode.jisKana, 0x91: MacKeyCode.jisEisu,
            0xE0: MacKeyCode.control, 0xE1: MacKeyCode.shift, 0xE2: MacKeyCode.option, 0xE3: MacKeyCode.command,
            0xE4: MacKeyCode.rightControl, 0xE5: MacKeyCode.rightShift, 0xE6: MacKeyCode.rightOption,
            0xE7: MacKeyCode.rightCommand,
        ]
        table.merge(others) { _, new in new }
        return table
    }()

    // MARK: 文字 → キー（US 配列）

    /// 修飾キーと一緒に押す文字（⌘C など）を、US 配列のキーに置き換える。
    /// 対応するキーがない文字（日本語など）は nil。
    public static func macKey(for character: Character) -> (keyCode: UInt16, needsShift: Bool)? {
        if let code = unshifted[character] { return (code, false) }
        if let code = shifted[character] { return (code, true) }
        return nil
    }

    private static let unshifted: [Character: UInt16] = {
        var table: [Character: UInt16] = [:]
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for (index, letter) in letters.enumerated() {
            table[letter] = hidTable[0x04 + index]
        }
        let digits = Array("1234567890")
        for (index, digit) in digits.enumerated() {
            table[digit] = hidTable[0x1E + index]
        }
        let symbols: [Character: UInt16] = [
            "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A, ";": 0x29, "'": 0x27, "`": 0x32,
            ",": 0x2B, ".": 0x2F, "/": 0x2C, " ": MacKeyCode.space,
        ]
        table.merge(symbols) { _, new in new }
        return table
    }()

    private static let shifted: [Character: UInt16] = {
        var table: [Character: UInt16] = [:]
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            if let code = unshifted[letter] { table[Character(letter.uppercased())] = code }
        }
        let pairs: [(Character, Character)] = [
            ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"), ("&", "7"), ("*", "8"),
            ("(", "9"), (")", "0"), ("_", "-"), ("+", "="), ("{", "["), ("}", "]"), ("|", "\\"), (":", ";"),
            ("\"", "'"), ("~", "`"), ("<", ","), (">", "."), ("?", "/"),
        ]
        for (shiftedCharacter, base) in pairs {
            if let code = unshifted[base] { table[shiftedCharacter] = code }
        }
        return table
    }()
}
