import Foundation

/// 端末が長く使う鍵（X25519 の固定鍵）。
///
/// 初回起動時に作り、`privateKey` を Keychain に保存する。
public struct StaticIdentity: Sendable, Equatable {
    public let privateKey: Data
    public let publicKey: Data

    /// 新しい鍵を作る。
    public init() {
        let privateKey = CryptoPrimitives.generatePrivateKey()
        self.privateKey = privateKey
        // 作ったばかりの鍵から公開鍵を計算できないことはない。
        self.publicKey = try! CryptoPrimitives.publicKey(forPrivateKey: privateKey)
    }

    /// 保存しておいた秘密鍵から復元する。
    public init(privateKey: Data) throws {
        guard privateKey.count == CryptoPrimitives.keyLength else { throw RemoteCoreError.invalidKey }
        do {
            self.publicKey = try CryptoPrimitives.publicKey(forPrivateKey: privateKey)
        } catch {
            throw RemoteCoreError.invalidKey
        }
        self.privateKey = privateKey
    }

    /// Bonjour の TXT レコードに載せる、Mac の識別子。
    public var hostID: String { HostID.make(publicKey: publicKey) }
}

public enum HostID {
    /// 公開鍵の SHA-256 の先頭 8 バイトを 16 進表記にしたもの（16 文字）。
    public static func make(publicKey: Data) -> String {
        CryptoPrimitives.sha256(publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
