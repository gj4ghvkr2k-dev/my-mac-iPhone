import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Noise と映像の暗号化で使う基本的な暗号処理。
///
/// 鍵は `Data` のまま持ち回り、CryptoKit の型は必要なときにだけ作る。
/// Apple 環境と Linux 環境で `Sendable` への準拠が異なっても影響を受けないようにするため。
enum CryptoPrimitives {
    static let keyLength = 32
    static let tagLength = 16

    // MARK: X25519

    static func generatePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    static func publicKey(forPrivateKey privateKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }

    static func dh(privateKey: Data, publicKey: Data) throws -> Data {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
        return secret.withUnsafeBytes { Data($0) }
    }

    // MARK: SHA-256 / HMAC / HKDF

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise 仕様の HKDF（出力 2 つ）。
    static func noiseHKDF(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let tempKey = hmac(key: chainingKey, data: inputKeyMaterial)
        let output1 = hmac(key: tempKey, data: Data([0x01]))
        let output2 = hmac(key: tempKey, data: output1 + Data([0x02]))
        return (output1, output2)
    }

    /// RFC 5869 の HKDF。Noise の外で鍵を派生させるときに使う。
    static func hkdf(inputKeyMaterial: Data, salt: Data, info: Data, outputByteCount: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: ChaCha20-Poly1305

    /// 暗号化して `暗号文 ‖ 認証タグ` を返す。
    static func seal(key: Data, nonce: Data, associatedData: Data, plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try ChaChaPoly.Nonce(data: nonce),
            authenticating: associatedData
        )
        return box.ciphertext + box.tag
    }

    /// `暗号文 ‖ 認証タグ` を検証して復号する。
    static func open(key: Data, nonce: Data, associatedData: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= tagLength else { throw RemoteCoreError.decryptionFailed }
        let body = Data(ciphertext.prefix(ciphertext.count - tagLength))
        let tag = Data(ciphertext.suffix(tagLength))
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: nonce),
                ciphertext: body,
                tag: tag
            )
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: associatedData)
        } catch {
            throw RemoteCoreError.decryptionFailed
        }
    }

    // MARK: その他

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// 比較にかかる時間が内容によって変わらない比較。
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            difference |= a ^ b
        }
        return difference == 0
    }
}
