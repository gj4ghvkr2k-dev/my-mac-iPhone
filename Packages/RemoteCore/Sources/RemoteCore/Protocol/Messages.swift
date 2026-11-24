import Foundation

// MARK: - メッセージ本文の型

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case hevc
    case h264
}

/// iPhone → Mac。接続して最初に送る。
public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: UInt16
    public var deviceName: String
    /// iPhone の画面の大きさ（ピクセル）。
    public var screenWidth: Int
    public var screenHeight: Int
    public var supportedCodecs: [VideoCodec]

    public init(protocolVersion: UInt16 = ProtocolInfo.version, deviceName: String,
                screenWidth: Int, screenHeight: Int, supportedCodecs: [VideoCodec]) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.supportedCodecs = supportedCodecs
    }
}

public struct DisplayInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var widthPixels: Int
    public var heightPixels: Int
    public var scale: Double
    public var isMain: Bool

    public init(id: UInt32, name: String, widthPixels: Int, heightPixels: Int, scale: Double, isMain: Bool) {
        self.id = id
        self.name = name
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.scale = scale
        self.isMain = isMain
    }
}

/// Mac → iPhone。`Hello` への返事。
public struct HelloAck: Codable, Equatable, Sendable {
    public var protocolVersion: UInt16
    public var hostName: String
    /// 映像を送る UDP の待ち受けポート。
    public var videoPort: UInt16
    public var codec: VideoCodec
    public var displays: [DisplayInfo]
    public var activeDisplayID: UInt32

    public init(protocolVersion: UInt16 = ProtocolInfo.version, hostName: String, videoPort: UInt16,
                codec: VideoCodec, displays: [DisplayInfo], activeDisplayID: UInt32) {
        self.protocolVersion = protocolVersion
        self.hostName = hostName
        self.videoPort = videoPort
        self.codec = codec
        self.displays = displays
        self.activeDisplayID = activeDisplayID
    }
}

/// iPhone → Mac。QR コードで受け取ったトークンを示して、端末を登録してもらう。
public struct PairRequest: Codable, Equatable, Sendable {
    public var token: Data
    public var deviceName: String

    public init(token: Data, deviceName: String) {
        self.token = token
        self.deviceName = deviceName
    }
}

public enum PairFailure: String, Codable, Sendable {
    case invalidToken
    case expired
    case hostKeyMismatch
}

/// Mac → iPhone。端末登録の結果。
public struct PairResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var hostName: String
    public var failure: PairFailure?

    public init(accepted: Bool, hostName: String, failure: PairFailure? = nil) {
        self.accepted = accepted
        self.hostName = hostName
        self.failure = failure
    }
}

/// iPhone → Mac。映像の送り方の希望。
public struct StreamConfig: Codable, Equatable, Sendable {
    /// 長い辺の最大ピクセル数。
    public var maxLongEdge: Int
    public var framesPerSecond: Int
    public var bitrateKbps: Int

    public init(maxLongEdge: Int = 2560, framesPerSecond: Int = 60, bitrateKbps: Int = 12_000) {
        self.maxLongEdge = maxLongEdge
        self.framesPerSecond = framesPerSecond
        self.bitrateKbps = bitrateKbps
    }
}

public enum DisconnectReason: UInt8, Sendable {
    case normal = 0
    /// 別の端末が接続したため、この接続を切った。
    case replacedByAnotherDevice = 1
    case notAuthorized = 2
    case protocolMismatch = 3
    case hostShuttingDown = 4
}

/// マウスポインターの移動。
public enum PointerMove: Equatable, Sendable {
    /// 選んでいるモニター上の位置。左上が (0, 0)、右下が (1, 1)。
    case absolute(x: Float, y: Float)
    /// 今の位置からの移動量（Mac の画面上のポイント単位）。加速度は iPhone 側で計算済み。
    case relative(dx: Float, dy: Float)
}

public enum MouseButton: UInt8, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

public struct PointerButton: Equatable, Sendable {
    public var button: MouseButton
    public var isDown: Bool
    /// 何回目のクリックか。ダブルクリックなら 2。
    public var clickCount: UInt8

    public init(button: MouseButton, isDown: Bool, clickCount: UInt8 = 1) {
        self.button = button
        self.isDown = isDown
        self.clickCount = clickCount
    }
}

public enum ScrollPhase: UInt8, Sendable {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 3
    case momentumBegan = 4
    case momentum = 5
    case momentumEnded = 6
}

public struct Scroll: Equatable, Sendable {
    /// ピクセル単位のスクロール量。向きは macOS の CGEvent のスクロールと同じ
    /// （dy が正なら上へ、dx が正なら左へスクロールする）。iPhone 側で向きを合わせてから送る。
    public var dx: Float
    public var dy: Float
    public var phase: ScrollPhase

    public init(dx: Float, dy: Float, phase: ScrollPhase) {
        self.dx = dx
        self.dy = dy
        self.phase = phase
    }
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)
    public static let capsLock = KeyModifiers(rawValue: 1 << 5)
}

public struct KeyEvent: Equatable, Sendable {
    /// macOS の仮想キーコード（kVK_*）。
    public var keyCode: UInt16
    public var isDown: Bool
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, isDown: Bool, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.modifiers = modifiers
    }
}

/// 決まった操作。
public enum RemoteAction: UInt8, Sendable, CaseIterable {
    case missionControl = 0
    case previousDesktop = 1
    case nextDesktop = 2
    case spotlight = 3
    case showDesktop = 4
}

/// Mac → iPhone。カーソルの位置（拡大表示中にカーソルを追いかけるため）。
public struct CursorState: Equatable, Sendable {
    /// 選んでいるモニター上の位置。左上が (0, 0)、右下が (1, 1)。
    public var x: Float
    public var y: Float
    public var isVisible: Bool

    public init(x: Float, y: Float, isVisible: Bool) {
        self.x = x
        self.y = y
        self.isVisible = isVisible
    }
}

// MARK: - メッセージ

/// 制御の通信路でやり取りするメッセージ。
///
/// 1 バイト目が種類、残りが本文。
/// 接続時に一度だけ送るものは JSON、頻繁に送る入力は固定長のバイナリにしている。
public enum ControlMessage: Equatable, Sendable {
    case hello(Hello)
    case helloAck(HelloAck)
    case pair(PairRequest)
    case pairResult(PairResult)
    case disconnect(DisconnectReason)
    case selectDisplay(displayID: UInt32)
    case streamConfig(StreamConfig)
    case requestKeyFrame
    case pointerMove(PointerMove)
    case pointerButton(PointerButton)
    case scroll(Scroll)
    case key(KeyEvent)
    case text(String)
    case action(RemoteAction)
    case cursorState(CursorState)
    case ping(UInt64)
    case pong(UInt64)

    enum TypeCode: UInt8 {
        case hello = 0x01
        case helloAck = 0x02
        case pair = 0x03
        case pairResult = 0x04
        case disconnect = 0x05
        case selectDisplay = 0x10
        case streamConfig = 0x11
        case requestKeyFrame = 0x12
        case pointerMove = 0x20
        case pointerButton = 0x21
        case scroll = 0x22
        case key = 0x23
        case text = 0x24
        case action = 0x25
        case cursorState = 0x30
        case ping = 0x40
        case pong = 0x41
    }

    private static let pointerAbsolute: UInt8 = 0
    private static let pointerRelative: UInt8 = 1

    // MARK: 書き出し

    public func encoded() throws -> Data {
        var w = ByteWriter()
        switch self {
        case .hello(let body):
            w.write(TypeCode.hello.rawValue)
            w.write(try Self.json(body))
        case .helloAck(let body):
            w.write(TypeCode.helloAck.rawValue)
            w.write(try Self.json(body))
        case .pair(let body):
            w.write(TypeCode.pair.rawValue)
            w.write(try Self.json(body))
        case .pairResult(let body):
            w.write(TypeCode.pairResult.rawValue)
            w.write(try Self.json(body))
        case .disconnect(let reason):
            w.write(TypeCode.disconnect.rawValue)
            w.write(reason.rawValue)
        case .selectDisplay(let displayID):
            w.write(TypeCode.selectDisplay.rawValue)
            w.write(displayID)
        case .streamConfig(let body):
            w.write(TypeCode.streamConfig.rawValue)
            w.write(try Self.json(body))
        case .requestKeyFrame:
            w.write(TypeCode.requestKeyFrame.rawValue)
        case .pointerMove(.absolute(let x, let y)):
            w.write(TypeCode.pointerMove.rawValue)
            w.write(Self.pointerAbsolute)
            w.write(x)
            w.write(y)
        case .pointerMove(.relative(let dx, let dy)):
            w.write(TypeCode.pointerMove.rawValue)
            w.write(Self.pointerRelative)
            w.write(dx)
            w.write(dy)
        case .pointerButton(let body):
            w.write(TypeCode.pointerButton.rawValue)
            w.write(body.button.rawValue)
            w.write(body.isDown)
            w.write(body.clickCount)
        case .scroll(let body):
            w.write(TypeCode.scroll.rawValue)
            w.write(body.dx)
            w.write(body.dy)
            w.write(body.phase.rawValue)
        case .key(let body):
            w.write(TypeCode.key.rawValue)
            w.write(body.keyCode)
            w.write(body.isDown)
            w.write(body.modifiers.rawValue)
        case .text(let string):
            w.write(TypeCode.text.rawValue)
            w.write(Data(string.utf8))
        case .action(let action):
            w.write(TypeCode.action.rawValue)
            w.write(action.rawValue)
        case .cursorState(let body):
            w.write(TypeCode.cursorState.rawValue)
            w.write(body.x)
            w.write(body.y)
            w.write(body.isVisible)
        case .ping(let value):
            w.write(TypeCode.ping.rawValue)
            w.write(value)
        case .pong(let value):
            w.write(TypeCode.pong.rawValue)
            w.write(value)
        }
        return w.data
    }

    // MARK: 読み込み

    public init(decoding data: Data) throws {
        var r = ByteReader(data)
        let rawType = try r.readUInt8()
        guard let type = TypeCode(rawValue: rawType) else { throw RemoteCoreError.unknownMessageType(rawType) }

        switch type {
        case .hello:
            self = .hello(try Self.decodeJSON(r.readRemaining()))
        case .helloAck:
            self = .helloAck(try Self.decodeJSON(r.readRemaining()))
        case .pair:
            self = .pair(try Self.decodeJSON(r.readRemaining()))
        case .pairResult:
            self = .pairResult(try Self.decodeJSON(r.readRemaining()))
        case .disconnect:
            self = .disconnect(try Self.decodeEnum(r.readUInt8()))
        case .selectDisplay:
            self = .selectDisplay(displayID: try r.readUInt32())
        case .streamConfig:
            self = .streamConfig(try Self.decodeJSON(r.readRemaining()))
        case .requestKeyFrame:
            self = .requestKeyFrame
        case .pointerMove:
            let kind = try r.readUInt8()
            let a = try r.readFloat()
            let b = try r.readFloat()
            try Self.requireFinite(a, b)
            switch kind {
            case Self.pointerAbsolute: self = .pointerMove(.absolute(x: a, y: b))
            case Self.pointerRelative: self = .pointerMove(.relative(dx: a, dy: b))
            default: throw RemoteCoreError.invalidValue("pointer kind \(kind)")
            }
        case .pointerButton:
            self = .pointerButton(PointerButton(
                button: try Self.decodeEnum(r.readUInt8()),
                isDown: try r.readBool(),
                clickCount: try r.readUInt8()
            ))
        case .scroll:
            let dx = try r.readFloat()
            let dy = try r.readFloat()
            try Self.requireFinite(dx, dy)
            self = .scroll(Scroll(dx: dx, dy: dy, phase: try Self.decodeEnum(r.readUInt8())))
        case .key:
            self = .key(KeyEvent(
                keyCode: try r.readUInt16(),
                isDown: try r.readBool(),
                modifiers: KeyModifiers(rawValue: try r.readUInt32())
            ))
        case .text:
            guard let string = String(data: r.readRemaining(), encoding: .utf8) else {
                throw RemoteCoreError.invalidValue("text is not UTF-8")
            }
            self = .text(string)
        case .action:
            self = .action(try Self.decodeEnum(r.readUInt8()))
        case .cursorState:
            let x = try r.readFloat()
            let y = try r.readFloat()
            try Self.requireFinite(x, y)
            self = .cursorState(CursorState(x: x, y: y, isVisible: try r.readBool()))
        case .ping:
            self = .ping(try r.readUInt64())
        case .pong:
            self = .pong(try r.readUInt64())
        }
        try r.expectEnd()
    }

    // MARK: 補助

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decodeJSON<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteCoreError.invalidValue("JSON \(T.self)")
        }
    }

    private static func decodeEnum<T: RawRepresentable>(_ raw: T.RawValue) throws -> T {
        guard let value = T(rawValue: raw) else { throw RemoteCoreError.invalidValue("\(T.self) \(raw)") }
        return value
    }

    private static func requireFinite(_ values: Float...) throws {
        guard values.allSatisfy(\.isFinite) else { throw RemoteCoreError.invalidValue("non-finite float") }
    }
}
