import Foundation

/// 制御の通信路で、区切り（`Framing`）付きのハンドシェイクを進める。
///
/// 使い方：
/// 1. iPhone（initiator）は `start()` の戻り値を送る。Mac（responder）は何も送らずに待つ。
/// 2. 受け取ったバイト列を `receive(_:)` に渡し、`outgoing` があれば送る。
/// 3. `channel` が返ってきたらハンドシェイク完了。以降はその `SecureChannel` を使う。
public struct SecureHandshake: Sendable {
    public struct Step: Sendable {
        /// 相手に送るバイト列（空なら送るものはない）。
        public var outgoing: Data
        /// ハンドシェイクが終わったら入る。
        public var channel: SecureChannel?
    }

    private var noise: NoiseXXHandshake
    private var decoder = FrameDecoder()
    private var started = false

    public init(role: NoiseXXHandshake.Role, localStatic: StaticIdentity) {
        self.noise = NoiseXXHandshake(role: role, localStatic: localStatic)
    }

    init(noise: NoiseXXHandshake) {
        self.noise = noise
    }

    /// 最初に送るバイト列。initiator だけが中身を返す。
    public mutating func start() throws -> Data {
        guard !started else { throw RemoteCoreError.handshakeOutOfOrder }
        started = true
        guard noise.isMyTurnToWrite else { return Data() }
        return try Framing.frame(noise.writeMessage())
    }

    public mutating func receive(_ bytes: Data) throws -> Step {
        guard started else { throw RemoteCoreError.handshakeOutOfOrder }
        decoder.append(bytes)
        var outgoing = Data()

        while !noise.isComplete, let message = decoder.nextFrame() {
            // ハンドシェイクのペイロードは第1段階では使わない。
            _ = try noise.readMessage(message)
            if noise.isMyTurnToWrite {
                outgoing += try Framing.frame(noise.writeMessage())
            }
        }

        guard noise.isComplete else { return Step(outgoing: outgoing, channel: nil) }

        var channel = SecureChannel(session: try noise.finish())
        // ハンドシェイクの直後に続けて届いていた分は、暗号化されたメッセージとして扱う。
        channel.pendingBytes = decoder.bufferedBytes
        return Step(outgoing: outgoing, channel: channel)
    }
}

/// ハンドシェイク後の制御の通信路。メッセージを暗号化して区切り付きで送受信する。
///
/// 復号に失敗したら、改ざんか不具合なので、呼び出し側は接続を切ること。
public struct SecureChannel: Sendable {
    /// 暗号化前のメッセージの最大長。
    public static let maxPlaintextLength = Framing.maxFrameLength - CryptoPrimitives.tagLength

    private var session: NoiseSession
    private var decoder = FrameDecoder()
    fileprivate var pendingBytes = Data()

    init(session: NoiseSession) {
        self.session = session
    }

    /// 相手の長く使う鍵（公開鍵）。
    public var remoteStaticPublicKey: Data { session.remoteStaticPublicKey }

    /// 映像パケット用の鍵。
    public var videoKey: Data { session.videoKey }

    /// メッセージを暗号化し、そのまま送れるバイト列にする。
    public mutating func seal(_ message: ControlMessage) throws -> Data {
        let plaintext = try message.encoded()
        guard plaintext.count <= Self.maxPlaintextLength else { throw RemoteCoreError.frameTooLarge(plaintext.count) }
        return try Framing.frame(session.encrypt(plaintext))
    }

    /// 受け取ったバイト列から、届ききったメッセージをすべて取り出す。
    public mutating func receive(_ bytes: Data = Data()) throws -> [ControlMessage] {
        if !pendingBytes.isEmpty {
            decoder.append(pendingBytes)
            pendingBytes = Data()
        }
        decoder.append(bytes)
        var messages: [ControlMessage] = []
        while let frame = decoder.nextFrame() {
            messages.append(try ControlMessage(decoding: session.decrypt(frame)))
        }
        return messages
    }
}
