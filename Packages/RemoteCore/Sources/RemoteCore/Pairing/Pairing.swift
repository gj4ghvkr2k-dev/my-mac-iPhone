import Foundation

/// QR コードに入れる、端末登録の招待。
///
/// `macremote://pair?v=1&n=<Mac名>&k=<公開鍵>&t=<トークン>`
/// 公開鍵とトークンは base64url（パディングなし）。
public struct PairingInvitation: Equatable, Sendable {
    public static let scheme = "macremote"
    public static let host = "pair"
    public static let tokenLength = 16

    public var version: UInt16
    public var hostName: String
    public var hostPublicKey: Data
    public var token: Data

    public init(version: UInt16 = ProtocolInfo.version, hostName: String, hostPublicKey: Data, token: Data) {
        self.version = version
        self.hostName = hostName
        self.hostPublicKey = hostPublicKey
        self.token = token
    }

    /// Bonjour でこの Mac を探すときに使う識別子。
    public var hostID: String { HostID.make(publicKey: hostPublicKey) }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "n", value: hostName),
            URLQueryItem(name: "k", value: Base64URL.encode(hostPublicKey)),
            URLQueryItem(name: "t", value: Base64URL.encode(token)),
        ]
        return components.url!
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme, components.host == Self.host else {
            throw RemoteCoreError.invalidInvitation("scheme")
        }
        func value(_ name: String) throws -> String {
            guard let value = components.queryItems?.first(where: { $0.name == name })?.value else {
                throw RemoteCoreError.invalidInvitation("missing \(name)")
            }
            return value
        }
        guard let version = UInt16(try value("v")) else { throw RemoteCoreError.invalidInvitation("version") }
        guard version == ProtocolInfo.version else { throw RemoteCoreError.invalidInvitation("unsupported version") }
        guard let key = Base64URL.decode(try value("k")), key.count == CryptoPrimitives.keyLength else {
            throw RemoteCoreError.invalidInvitation("key")
        }
        guard let token = Base64URL.decode(try value("t")), token.count == Self.tokenLength else {
            throw RemoteCoreError.invalidInvitation("token")
        }
        self.init(version: version, hostName: try value("n"), hostPublicKey: key, token: token)
    }

    public init(string: String) throws {
        guard let url = URL(string: string) else { throw RemoteCoreError.invalidInvitation("url") }
        try self.init(url: url)
    }
}

/// Mac 側で、発行した招待のトークンを管理する。
///
/// 有効な招待は同時に 1 つだけ。トークンは 1 回使うと無効になる。
public struct PairingAuthority: Sendable {
    public static let defaultLifetime: TimeInterval = 5 * 60

    private var activeToken: Data?
    private var expiresAt: Date?
    public let lifetime: TimeInterval

    public init(lifetime: TimeInterval = PairingAuthority.defaultLifetime) {
        self.lifetime = lifetime
    }

    /// 新しい招待を作る。前の招待は無効になる。
    public mutating func createInvitation(hostName: String, hostIdentity: StaticIdentity, now: Date = Date()) -> PairingInvitation {
        let token = CryptoPrimitives.randomBytes(PairingInvitation.tokenLength)
        activeToken = token
        expiresAt = now.addingTimeInterval(lifetime)
        return PairingInvitation(hostName: hostName, hostPublicKey: hostIdentity.publicKey, token: token)
    }

    /// 招待を取り消す（QR の画面を閉じたときなど）。
    public mutating func cancel() {
        activeToken = nil
        expiresAt = nil
    }

    public var hasActiveInvitation: Bool { activeToken != nil }

    /// iPhone から届いたトークンを確かめる。正しければトークンを使用済みにする。
    public mutating func redeem(token: Data, now: Date = Date()) throws {
        guard let activeToken, let expiresAt else { throw RemoteCoreError.pairingTokenInvalid }
        guard CryptoPrimitives.constantTimeEquals(token, activeToken) else {
            throw RemoteCoreError.pairingTokenInvalid
        }
        guard now < expiresAt else {
            cancel()
            throw RemoteCoreError.pairingTokenExpired
        }
        cancel()
    }
}

/// 登録済みの相手。Mac 側では iPhone／iPad、iPhone 側では Mac を表す。
public struct TrustedPeer: Codable, Equatable, Sendable, Identifiable {
    public var publicKey: Data
    public var name: String
    public var pairedAt: Date

    public init(publicKey: Data, name: String, pairedAt: Date = Date()) {
        self.publicKey = publicKey
        self.name = name
        self.pairedAt = pairedAt
    }

    public var id: String { HostID.make(publicKey: publicKey) }
}

/// 登録済みの相手の一覧。保存（Keychain やファイル）は各アプリが行う。
public struct TrustedPeerList: Codable, Equatable, Sendable {
    public private(set) var peers: [TrustedPeer] = []

    public init(peers: [TrustedPeer] = []) {
        self.peers = peers
    }

    /// 追加する。同じ鍵の相手がすでにいれば、名前と登録日時を更新する。
    public mutating func add(_ peer: TrustedPeer) {
        if let index = peers.firstIndex(where: { $0.publicKey == peer.publicKey }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
    }

    public mutating func remove(publicKey: Data) {
        peers.removeAll { $0.publicKey == publicKey }
    }

    public func peer(withPublicKey publicKey: Data) -> TrustedPeer? {
        peers.first { CryptoPrimitives.constantTimeEquals($0.publicKey, publicKey) }
    }

    public func peer(withHostID hostID: String) -> TrustedPeer? {
        peers.first { $0.id == hostID }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
