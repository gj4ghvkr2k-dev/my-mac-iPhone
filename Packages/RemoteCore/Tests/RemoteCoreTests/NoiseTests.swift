import Foundation
import Testing
@testable import RemoteCore

@Suite("Noise XX")
struct NoiseTests {
    /// cacophony のテストベクター（Noise_XX_25519_ChaChaPoly_SHA256）。
    /// https://github.com/haskell-cryptography/cacophony/blob/master/vectors/cacophony.txt
    enum Vector {
        static let prologue = hex("4a6f686e2047616c74")
        static let initiatorStatic = hex("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1")
        static let initiatorEphemeral = hex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")
        static let responderStatic = hex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893")
        static let responderEphemeral = hex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b")
        static let handshakeHash = hex("c8e5f64e846193be2a834104c2a009868d6c9f3bd3c186299888b488b2f1f58e")
        static let messages: [(payload: Data, ciphertext: Data)] = [
            (hex("4c756477696720766f6e204d69736573"),
             hex("ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573")),
            (hex("4d757272617920526f746862617264"),
             hex("95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad")),
            (hex("462e20412e20486179656b"),
             hex("c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a80ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6ae769a1d95941d49b25030")),
            (hex("4361726c204d656e676572"),
             hex("96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df")),
            (hex("4a65616e2d426170746973746520536179"),
             hex("3e40f15f6f3a46ae446b253bf8b1d9ffb6ed9b174d272328ff91a7e2e5c79c07f5")),
            (hex("457567656e2042f6686d20766f6e2042617765726b"),
             hex("eb3f3515110702e047a6c9da4478b6ead94873c11c0f2d710ddb3f09fce024b3a58502ae3f")),
        ]
    }

    @Test("公開テストベクターと一致する")
    func matchesTestVector() throws {
        var initiator = NoiseXXHandshake(
            role: .initiator,
            localStatic: try StaticIdentity(privateKey: Vector.initiatorStatic),
            prologue: Vector.prologue,
            ephemeralPrivateKey: Vector.initiatorEphemeral
        )
        var responder = NoiseXXHandshake(
            role: .responder,
            localStatic: try StaticIdentity(privateKey: Vector.responderStatic),
            prologue: Vector.prologue,
            ephemeralPrivateKey: Vector.responderEphemeral
        )

        // ハンドシェイク（initiator → responder → initiator）
        for (index, message) in Vector.messages.prefix(3).enumerated() {
            let initiatorWrites = index % 2 == 0
            if initiatorWrites {
                let written = try initiator.writeMessage(payload: message.payload)
                #expect(written == message.ciphertext, "handshake message \(index)")
                #expect(try responder.readMessage(written) == message.payload)
            } else {
                let written = try responder.writeMessage(payload: message.payload)
                #expect(written == message.ciphertext, "handshake message \(index)")
                #expect(try initiator.readMessage(written) == message.payload)
            }
        }
        #expect(initiator.isComplete && responder.isComplete)

        var initiatorSession = try initiator.finish()
        var responderSession = try responder.finish()
        #expect(initiatorSession.handshakeHash == Vector.handshakeHash)
        #expect(responderSession.handshakeHash == Vector.handshakeHash)
        #expect(initiatorSession.remoteStaticPublicKey == (try StaticIdentity(privateKey: Vector.responderStatic)).publicKey)
        #expect(responderSession.remoteStaticPublicKey == (try StaticIdentity(privateKey: Vector.initiatorStatic)).publicKey)
        #expect(initiatorSession.videoKey == responderSession.videoKey)

        // ハンドシェイク後のメッセージ（送る側が交互に入れ替わる）
        for (index, message) in Vector.messages.dropFirst(3).enumerated() {
            let responderWrites = index % 2 == 0
            if responderWrites {
                let written = try responderSession.encrypt(message.payload)
                #expect(written == message.ciphertext, "transport message \(index + 3)")
                #expect(try initiatorSession.decrypt(written) == message.payload)
            } else {
                let written = try initiatorSession.encrypt(message.payload)
                #expect(written == message.ciphertext, "transport message \(index + 3)")
                #expect(try responderSession.decrypt(written) == message.payload)
            }
        }
    }

    @Test("改ざんされたハンドシェイクは失敗する")
    func tamperedHandshakeFails() throws {
        var initiator = NoiseXXHandshake(role: .initiator, localStatic: StaticIdentity())
        var responder = NoiseXXHandshake(role: .responder, localStatic: StaticIdentity())
        _ = try responder.readMessage(try initiator.writeMessage())
        var message = try responder.writeMessage()
        message[message.count - 1] ^= 0x01
        #expect(throws: RemoteCoreError.decryptionFailed) {
            try initiator.readMessage(message)
        }
    }

    @Test("プロローグが違うとハンドシェイクは失敗する")
    func prologueMismatchFails() throws {
        var initiator = NoiseXXHandshake(role: .initiator, localStatic: StaticIdentity(), prologue: Data("macremote/1".utf8))
        var responder = NoiseXXHandshake(role: .responder, localStatic: StaticIdentity(), prologue: Data("macremote/2".utf8))
        _ = try responder.readMessage(try initiator.writeMessage())
        let message = try responder.writeMessage()
        #expect(throws: RemoteCoreError.decryptionFailed) {
            try initiator.readMessage(message)
        }
    }

    @Test("順番を守らない呼び出しはエラーになる")
    func outOfOrderFails() throws {
        var responder = NoiseXXHandshake(role: .responder, localStatic: StaticIdentity())
        #expect(throws: RemoteCoreError.handshakeOutOfOrder) {
            try responder.writeMessage()
        }
        var initiator = NoiseXXHandshake(role: .initiator, localStatic: StaticIdentity())
        #expect(throws: RemoteCoreError.handshakeNotComplete) {
            try initiator.finish()
        }
        _ = try initiator.writeMessage()
        #expect(throws: RemoteCoreError.handshakeOutOfOrder) {
            try initiator.writeMessage()
        }
    }

    @Test("保存した秘密鍵から同じ鍵を復元できる")
    func identityRoundTrip() throws {
        let identity = StaticIdentity()
        let restored = try StaticIdentity(privateKey: identity.privateKey)
        #expect(restored == identity)
        #expect(identity.hostID.count == 16)
        #expect(throws: RemoteCoreError.invalidKey) {
            try StaticIdentity(privateKey: Data(count: 31))
        }
    }
}

func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}
