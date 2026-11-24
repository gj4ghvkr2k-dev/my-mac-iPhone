import Foundation

// Noise Protocol Framework（revision 34）の Noise_XX_25519_ChaChaPoly_SHA256 の実装。
// https://noiseprotocol.org/noise.html
//
//   XX:
//     -> e
//     <- e, ee, s, es
//     -> s, se

/// Noise の CipherState。鍵と、使うたびに増える nonce を持つ。
struct NoiseCipherState: Sendable {
    private(set) var key: Data?
    private(set) var nonce: UInt64 = 0

    init(key: Data? = nil) {
        self.key = key
    }

    var hasKey: Bool { key != nil }

    mutating func encrypt(associatedData: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        guard nonce < UInt64.max else { throw RemoteCoreError.nonceExhausted }
        let result = try CryptoPrimitives.seal(
            key: key,
            nonce: Self.nonceBytes(nonce),
            associatedData: associatedData,
            plaintext: plaintext
        )
        nonce += 1
        return result
    }

    mutating func decrypt(associatedData: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce < UInt64.max else { throw RemoteCoreError.nonceExhausted }
        let result = try CryptoPrimitives.open(
            key: key,
            nonce: Self.nonceBytes(nonce),
            associatedData: associatedData,
            ciphertext: ciphertext
        )
        nonce += 1
        return result
    }

    /// ChaChaPoly の nonce：先頭 4 バイトは 0、続く 8 バイトはカウンタのリトルエンディアン。
    static func nonceBytes(_ counter: UInt64) -> Data {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }
}

/// Noise の SymmetricState。
struct NoiseSymmetricState: Sendable {
    private(set) var chainingKey: Data
    private(set) var handshakeHash: Data
    private(set) var cipher = NoiseCipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        if name.count <= 32 {
            handshakeHash = name + Data(count: 32 - name.count)
        } else {
            handshakeHash = CryptoPrimitives.sha256(name)
        }
        chainingKey = handshakeHash
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let (newChainingKey, tempKey) = CryptoPrimitives.noiseHKDF(
            chainingKey: chainingKey,
            inputKeyMaterial: inputKeyMaterial
        )
        chainingKey = newChainingKey
        cipher = NoiseCipherState(key: tempKey)
    }

    mutating func mixHash(_ data: Data) {
        handshakeHash = CryptoPrimitives.sha256(handshakeHash + data)
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(associatedData: handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(associatedData: handshakeHash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (key1, key2) = CryptoPrimitives.noiseHKDF(chainingKey: chainingKey, inputKeyMaterial: Data())
        return (NoiseCipherState(key: key1), NoiseCipherState(key: key2))
    }
}

/// Noise XX のハンドシェイク。
///
/// iPhone（接続する側）が `initiator`、Mac（待ち受ける側）が `responder` になる。
public struct NoiseXXHandshake: Sendable {
    public enum Role: Sendable {
        case initiator
        case responder
    }

    public static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
    static let dhLength = 32

    public let role: Role
    private var symmetric: NoiseSymmetricState
    private let localStaticPrivateKey: Data
    private let localStaticPublicKey: Data
    private var localEphemeralPrivateKey: Data?
    private var presetEphemeralPrivateKey: Data?
    private var remoteEphemeralPublicKey: Data?
    public private(set) var remoteStaticPublicKey: Data?
    /// これまでに送受信したハンドシェイクメッセージの数（0〜3）。
    public private(set) var messageIndex = 0

    /// - Parameters:
    ///   - ephemeralPrivateKey: テスト用。指定しなければ乱数で作る。
    public init(
        role: Role,
        localStatic: StaticIdentity,
        prologue: Data = ProtocolInfo.noisePrologue,
        ephemeralPrivateKey: Data? = nil
    ) {
        self.role = role
        self.localStaticPrivateKey = localStatic.privateKey
        self.localStaticPublicKey = localStatic.publicKey
        self.presetEphemeralPrivateKey = ephemeralPrivateKey
        var symmetric = NoiseSymmetricState(protocolName: Self.protocolName)
        symmetric.mixHash(prologue)
        self.symmetric = symmetric
    }

    public var isComplete: Bool { messageIndex == 3 }

    /// 次に自分がメッセージを書く番かどうか。
    public var isMyTurnToWrite: Bool {
        guard !isComplete else { return false }
        let initiatorWrites = messageIndex % 2 == 0
        return (role == .initiator) == initiatorWrites
    }

    /// 次のハンドシェイクメッセージを作る。
    public mutating func writeMessage(payload: Data = Data()) throws -> Data {
        guard isMyTurnToWrite else { throw RemoteCoreError.handshakeOutOfOrder }
        var message = Data()

        switch messageIndex {
        case 0: // -> e
            message += try writeEphemeral()
        case 1: // <- e, ee, s, es
            message += try writeEphemeral()
            symmetric.mixKey(try dh(localEphemeralPrivateKey, remoteEphemeralPublicKey))
            message += try symmetric.encryptAndHash(localStaticPublicKey)
            symmetric.mixKey(try dh(localStaticPrivateKey, remoteEphemeralPublicKey))
        case 2: // -> s, se
            message += try symmetric.encryptAndHash(localStaticPublicKey)
            symmetric.mixKey(try dh(localStaticPrivateKey, remoteEphemeralPublicKey))
        default:
            throw RemoteCoreError.handshakeOutOfOrder
        }

        message += try symmetric.encryptAndHash(payload)
        messageIndex += 1
        return message
    }

    /// 相手のハンドシェイクメッセージを読み、中に入っていたペイロードを返す。
    public mutating func readMessage(_ message: Data) throws -> Data {
        guard !isComplete, !isMyTurnToWrite else { throw RemoteCoreError.handshakeOutOfOrder }
        var reader = ByteReader(message)
        let encryptedKeyLength = Self.dhLength + CryptoPrimitives.tagLength

        switch messageIndex {
        case 0: // -> e
            try readEphemeral(&reader)
        case 1: // <- e, ee, s, es
            try readEphemeral(&reader)
            symmetric.mixKey(try dh(localEphemeralPrivateKey, remoteEphemeralPublicKey))
            remoteStaticPublicKey = try symmetric.decryptAndHash(try reader.readBytes(encryptedKeyLength))
            symmetric.mixKey(try dh(localEphemeralPrivateKey, remoteStaticPublicKey))
        case 2: // -> s, se
            remoteStaticPublicKey = try symmetric.decryptAndHash(try reader.readBytes(encryptedKeyLength))
            symmetric.mixKey(try dh(localEphemeralPrivateKey, remoteStaticPublicKey))
        default:
            throw RemoteCoreError.handshakeOutOfOrder
        }

        let payload = try symmetric.decryptAndHash(reader.readRemaining())
        messageIndex += 1
        return payload
    }

    /// ハンドシェイクを終え、通信用のセッションを作る。
    public func finish() throws -> NoiseSession {
        guard isComplete, let remoteStaticPublicKey else { throw RemoteCoreError.handshakeNotComplete }
        let (c1, c2) = symmetric.split()
        let videoKey = CryptoPrimitives.hkdf(
            inputKeyMaterial: symmetric.chainingKey,
            salt: symmetric.handshakeHash,
            info: Data("macremote video v1".utf8),
            outputByteCount: CryptoPrimitives.keyLength
        )
        switch role {
        case .initiator:
            return NoiseSession(sender: c1, receiver: c2, remoteStaticPublicKey: remoteStaticPublicKey,
                                handshakeHash: symmetric.handshakeHash, videoKey: videoKey)
        case .responder:
            return NoiseSession(sender: c2, receiver: c1, remoteStaticPublicKey: remoteStaticPublicKey,
                                handshakeHash: symmetric.handshakeHash, videoKey: videoKey)
        }
    }

    // MARK: - 内部

    private mutating func writeEphemeral() throws -> Data {
        let privateKey = presetEphemeralPrivateKey ?? CryptoPrimitives.generatePrivateKey()
        presetEphemeralPrivateKey = nil
        localEphemeralPrivateKey = privateKey
        let publicKey = try CryptoPrimitives.publicKey(forPrivateKey: privateKey)
        symmetric.mixHash(publicKey)
        return publicKey
    }

    private mutating func readEphemeral(_ reader: inout ByteReader) throws {
        let publicKey = try reader.readBytes(Self.dhLength)
        remoteEphemeralPublicKey = publicKey
        symmetric.mixHash(publicKey)
    }

    private func dh(_ privateKey: Data?, _ publicKey: Data?) throws -> Data {
        guard let privateKey, let publicKey else { throw RemoteCoreError.handshakeOutOfOrder }
        do {
            return try CryptoPrimitives.dh(privateKey: privateKey, publicKey: publicKey)
        } catch {
            throw RemoteCoreError.handshakeMessageMalformed
        }
    }
}

/// ハンドシェイク後の暗号化セッション。
public struct NoiseSession: Sendable {
    private var sender: NoiseCipherState
    private var receiver: NoiseCipherState
    /// 相手の長く使う鍵（公開鍵）。登録済みの端末かどうかの確認に使う。
    public let remoteStaticPublicKey: Data
    /// ハンドシェイク全体のハッシュ。この接続に固有の値。
    public let handshakeHash: Data
    /// 映像パケット用の鍵。Mac から iPhone への一方向で使う。
    public let videoKey: Data

    init(sender: NoiseCipherState, receiver: NoiseCipherState, remoteStaticPublicKey: Data,
         handshakeHash: Data, videoKey: Data) {
        self.sender = sender
        self.receiver = receiver
        self.remoteStaticPublicKey = remoteStaticPublicKey
        self.handshakeHash = handshakeHash
        self.videoKey = videoKey
    }

    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        try sender.encrypt(associatedData: Data(), plaintext: plaintext)
    }

    public mutating func decrypt(_ ciphertext: Data) throws -> Data {
        try receiver.decrypt(associatedData: Data(), ciphertext: ciphertext)
    }
}
