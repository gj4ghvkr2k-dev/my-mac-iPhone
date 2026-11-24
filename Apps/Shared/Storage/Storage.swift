import Foundation
import RemoteCore
import Security

/// Keychain に小さなデータ（秘密鍵など）を保存する。
enum KeychainStore {
    static let service = "com.mushiotoko.macremote"

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// この端末が長く使う鍵を、Keychain から読み込む（なければ作って保存する）。
enum IdentityStore {
    static func loadOrCreate(account: String = "identity") -> StaticIdentity {
        if let stored = KeychainStore.load(account: account),
           let identity = try? StaticIdentity(privateKey: stored) {
            return identity
        }
        let identity = StaticIdentity()
        KeychainStore.save(identity.privateKey, account: account)
        return identity
    }
}

/// 登録済みの相手の一覧を、Application Support の JSON ファイルに保存する。
///
/// 中身は公開鍵と名前だけで、秘密の情報は入っていない。
final class TrustedPeerStore {
    private let fileURL: URL
    private(set) var list: TrustedPeerList

    init(fileName: String = "trusted-peers.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode(TrustedPeerList.self, from: data) {
            list = decoded
        } else {
            list = TrustedPeerList()
        }
    }

    func replace(with list: TrustedPeerList) {
        self.list = list
        save()
    }

    func remove(publicKey: Data) {
        list.remove(publicKey: publicKey)
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
