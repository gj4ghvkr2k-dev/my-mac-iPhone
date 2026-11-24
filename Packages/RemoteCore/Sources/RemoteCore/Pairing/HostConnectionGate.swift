import Foundation

/// Mac 側で、接続してきた相手ごとに「何を受け付けるか」を決める。
///
/// - 登録済みの相手：すべてのメッセージを受け付ける。
/// - 未登録の相手：`pair` だけを受け付ける。それ以外が届いたら切断する。
public struct HostConnectionGate: Sendable {
    public enum State: Equatable, Sendable {
        case authorized(TrustedPeer)
        case awaitingPairing
        case closed
    }

    public enum Outcome: Equatable, Sendable {
        /// アプリ側で処理するメッセージ。
        case deliver(ControlMessage)
        /// 相手に返すメッセージ。`thenClose` が true なら送ったあとに切断する。
        case reply([ControlMessage], thenClose: Bool)
        /// 端末を新しく登録した。`trustedPeers` に追加済み。返事を送ること。
        case paired(TrustedPeer, reply: ControlMessage)
    }

    public private(set) var state: State
    public let remoteStaticPublicKey: Data
    private let hostName: String

    public init(remoteStaticPublicKey: Data, trustedPeers: TrustedPeerList, hostName: String) {
        self.remoteStaticPublicKey = remoteStaticPublicKey
        self.hostName = hostName
        if let peer = trustedPeers.peer(withPublicKey: remoteStaticPublicKey) {
            state = .authorized(peer)
        } else {
            state = .awaitingPairing
        }
    }

    public mutating func handle(
        _ message: ControlMessage,
        authority: inout PairingAuthority,
        trustedPeers: inout TrustedPeerList,
        now: Date = Date()
    ) -> Outcome {
        switch state {
        case .closed:
            return .reply([], thenClose: true)

        case .authorized(var peer):
            guard case .pair(let request) = message else { return .deliver(message) }
            // 登録済みの端末がもう一度登録しようとした場合は、名前だけ更新して受け付ける。
            peer.name = request.deviceName
            trustedPeers.add(peer)
            state = .authorized(peer)
            return .reply([.pairResult(PairResult(accepted: true, hostName: hostName))], thenClose: false)

        case .awaitingPairing:
            guard case .pair(let request) = message else {
                state = .closed
                return .reply([.disconnect(.notAuthorized)], thenClose: true)
            }
            do {
                try authority.redeem(token: request.token, now: now)
            } catch let error as RemoteCoreError {
                state = .closed
                let failure: PairFailure = error == .pairingTokenExpired ? .expired : .invalidToken
                return .reply([.pairResult(PairResult(accepted: false, hostName: hostName, failure: failure))],
                              thenClose: true)
            } catch {
                state = .closed
                return .reply([.disconnect(.notAuthorized)], thenClose: true)
            }
            let peer = TrustedPeer(publicKey: remoteStaticPublicKey, name: request.deviceName, pairedAt: now)
            trustedPeers.add(peer)
            state = .authorized(peer)
            return .paired(peer, reply: .pairResult(PairResult(accepted: true, hostName: hostName)))
        }
    }
}

extension PairingInvitation {
    /// ハンドシェイクで受け取った Mac の公開鍵が、QR コードの鍵と同じかどうか。
    public func matchesHost(publicKey: Data) -> Bool {
        CryptoPrimitives.constantTimeEquals(hostPublicKey, publicKey)
    }
}
