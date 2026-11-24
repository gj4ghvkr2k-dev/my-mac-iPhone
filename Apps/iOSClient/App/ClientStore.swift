import Foundation
import Network
import RemoteCore
import UIKit

/// iPhone 側アプリ全体の状態：この端末の鍵、登録済みの Mac、近くで見つかった Mac。
///
/// すべてメインキューで動く。
final class ClientStore: ObservableObject {
    @Published private(set) var hosts: [TrustedPeer] = []
    /// 今見つかっている Mac の ID（HostID）。
    @Published private(set) var onlineHostIDs: Set<String> = []
    @Published private(set) var browserProblem: String?

    let identity: StaticIdentity
    private let store = TrustedPeerStore(fileName: "trusted-hosts.json")
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]

    init() {
        identity = IdentityStore.loadOrCreate(account: "client.identity")
        hosts = store.list.peers
    }

    var deviceName: String { UIDevice.current.name }

    // MARK: - Mac を探す

    func startBrowsing() {
        browser?.cancel()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ProtocolInfo.bonjourServiceType, domain: nil),
                                using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.browserProblem = nil
            case .waiting:
                self?.browserProblem = "近くの Mac を探せません。設定アプリの「プライバシーとセキュリティ」→「ローカルネットワーク」で MacRemote を許可してください"
            case .failed(let error):
                self?.browserProblem = "近くの Mac を探せません（\(error)）"
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(with: results)
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private func update(with results: Set<NWBrowser.Result>) {
        var found: [String: NWEndpoint] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let hostID = txt[ProtocolInfo.TXTKey.hostID],
                  txt[ProtocolInfo.TXTKey.version] == String(ProtocolInfo.version) else { continue }
            found[hostID] = result.endpoint
        }
        endpoints = found
        onlineHostIDs = Set(found.keys)
    }

    func isOnline(_ peer: TrustedPeer) -> Bool {
        onlineHostIDs.contains(peer.id)
    }

    // MARK: - 接続

    /// 登録済みの Mac に接続する。見つかっていなければ nil。
    func makeSession(for peer: TrustedPeer) -> RemoteSession? {
        guard let endpoint = endpoints[peer.id] else { return nil }
        return RemoteSession(endpoint: endpoint, identity: identity, expectation: .trusted(peer), deviceName: deviceName)
    }

    /// QR コードの Mac に接続して登録する。見つかっていなければ nil。
    func makePairingSession(for invitation: PairingInvitation) -> RemoteSession? {
        guard let endpoint = endpoints[invitation.hostID] else { return nil }
        let session = RemoteSession(endpoint: endpoint, identity: identity, expectation: .pairing(invitation),
                                    deviceName: deviceName)
        session.onPaired = { [weak self] peer in self?.add(peer) }
        return session
    }

    // MARK: - 登録済みの一覧

    func add(_ peer: TrustedPeer) {
        var list = store.list
        list.add(peer)
        store.replace(with: list)
        hosts = list.peers
    }

    func remove(_ peer: TrustedPeer) {
        store.remove(publicKey: peer.publicKey)
        hosts = store.list.peers
    }
}
