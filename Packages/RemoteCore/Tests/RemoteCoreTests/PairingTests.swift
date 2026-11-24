import Foundation
import Testing
@testable import RemoteCore

@Suite("端末登録")
struct PairingTests {
    let hostIdentity = StaticIdentity()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("招待を URL にして読み戻せる")
    func invitationURLRoundTrip() throws {
        var authority = PairingAuthority()
        let invitation = authority.createInvitation(hostName: "家族の Mac mini & 書斎", hostIdentity: hostIdentity, now: start)
        let url = invitation.url
        #expect(url.scheme == "macremote")
        let parsed = try PairingInvitation(string: url.absoluteString)
        #expect(parsed == invitation)
        #expect(parsed.hostID == hostIdentity.hostID)
        #expect(parsed.matchesHost(publicKey: hostIdentity.publicKey))
        #expect(!parsed.matchesHost(publicKey: StaticIdentity().publicKey))
    }

    @Test("おかしな招待 URL は読み込めない", arguments: [
        "https://pair?v=1",
        "macremote://other?v=1",
        "macremote://pair?v=2&n=a&k=AAAA&t=AAAA",
        "macremote://pair?v=1&n=a&k=AAAA&t=AAAAAAAAAAAAAAAAAAAAAA",
        "macremote://pair?v=1&n=a&t=AAAAAAAAAAAAAAAAAAAAAA",
    ])
    func invalidInvitations(string: String) {
        #expect(throws: RemoteCoreError.self) {
            try PairingInvitation(string: string)
        }
    }

    @Test("トークンは 1 回だけ使える")
    func tokenIsSingleUse() throws {
        var authority = PairingAuthority()
        let invitation = authority.createInvitation(hostName: "Mac", hostIdentity: hostIdentity, now: start)
        try authority.redeem(token: invitation.token, now: start.addingTimeInterval(10))
        #expect(throws: RemoteCoreError.pairingTokenInvalid) {
            try authority.redeem(token: invitation.token, now: start.addingTimeInterval(11))
        }
    }

    @Test("期限切れ・違うトークン・作り直す前のトークンは使えない")
    func tokenRejections() throws {
        var authority = PairingAuthority()
        let old = authority.createInvitation(hostName: "Mac", hostIdentity: hostIdentity, now: start)
        let current = authority.createInvitation(hostName: "Mac", hostIdentity: hostIdentity, now: start)
        #expect(throws: RemoteCoreError.pairingTokenInvalid) {
            try authority.redeem(token: old.token, now: start)
        }
        #expect(throws: RemoteCoreError.pairingTokenExpired) {
            try authority.redeem(token: current.token, now: start.addingTimeInterval(PairingAuthority.defaultLifetime))
        }
        // 期限切れになった招待は取り消される
        #expect(!authority.hasActiveInvitation)
    }

    @Test("未登録の端末：正しいトークンで登録され、以降のメッセージが通る")
    func gatePairsNewDevice() throws {
        var authority = PairingAuthority()
        var trusted = TrustedPeerList()
        let invitation = authority.createInvitation(hostName: "Mac", hostIdentity: hostIdentity, now: start)
        let clientKey = StaticIdentity().publicKey

        var gate = HostConnectionGate(remoteStaticPublicKey: clientKey, trustedPeers: trusted, hostName: "Mac")
        #expect(gate.state == .awaitingPairing)

        let outcome = gate.handle(.pair(PairRequest(token: invitation.token, deviceName: "花子の iPhone")),
                                  authority: &authority, trustedPeers: &trusted, now: start)
        let peer = TrustedPeer(publicKey: clientKey, name: "花子の iPhone", pairedAt: start)
        #expect(outcome == .paired(peer, reply: .pairResult(PairResult(accepted: true, hostName: "Mac"))))
        #expect(trusted.peer(withPublicKey: clientKey) == peer)
        #expect(gate.handle(.ping(5), authority: &authority, trustedPeers: &trusted) == .deliver(.ping(5)))

        // 次の接続からは最初から登録済み
        let nextGate = HostConnectionGate(remoteStaticPublicKey: clientKey, trustedPeers: trusted, hostName: "Mac")
        #expect(nextGate.state == .authorized(peer))
    }

    @Test("未登録の端末：登録前のメッセージや違うトークンでは切断される")
    func gateRejectsUnknownDevice() {
        var authority = PairingAuthority()
        var trusted = TrustedPeerList()
        _ = authority.createInvitation(hostName: "Mac", hostIdentity: hostIdentity, now: start)

        var gate1 = HostConnectionGate(remoteStaticPublicKey: StaticIdentity().publicKey, trustedPeers: trusted, hostName: "Mac")
        #expect(gate1.handle(.hello(Hello(deviceName: "x", screenWidth: 1, screenHeight: 1, supportedCodecs: [])),
                             authority: &authority, trustedPeers: &trusted)
                == .reply([.disconnect(.notAuthorized)], thenClose: true))
        #expect(gate1.state == .closed)

        var gate2 = HostConnectionGate(remoteStaticPublicKey: StaticIdentity().publicKey, trustedPeers: trusted, hostName: "Mac")
        #expect(gate2.handle(.pair(PairRequest(token: Data(count: 16), deviceName: "x")),
                             authority: &authority, trustedPeers: &trusted, now: start)
                == .reply([.pairResult(PairResult(accepted: false, hostName: "Mac", failure: .invalidToken))], thenClose: true))
        #expect(trusted.peers.isEmpty)
    }

    @Test("登録済みの一覧：追加・更新・削除")
    func trustedPeerList() throws {
        let key = StaticIdentity().publicKey
        var list = TrustedPeerList()
        list.add(TrustedPeer(publicKey: key, name: "古い名前", pairedAt: start))
        list.add(TrustedPeer(publicKey: key, name: "新しい名前", pairedAt: start))
        #expect(list.peers.count == 1)
        #expect(list.peer(withHostID: HostID.make(publicKey: key))?.name == "新しい名前")

        // 保存して読み戻せる
        let decoded = try JSONDecoder().decode(TrustedPeerList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)

        list.remove(publicKey: key)
        #expect(list.peer(withPublicKey: key) == nil)
    }

    @Test("base64url")
    func base64url() {
        for length in 0..<40 {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 37 + 250) })
            let encoded = Base64URL.encode(data)
            #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
            #expect(Base64URL.decode(encoded) == data)
        }
        #expect(Base64URL.decode("A") == nil)
    }
}
