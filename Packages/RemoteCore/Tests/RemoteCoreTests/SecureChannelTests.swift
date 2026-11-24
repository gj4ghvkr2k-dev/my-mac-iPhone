import Foundation
import Testing
@testable import RemoteCore

@Suite("暗号化された制御の通信路")
struct SecureChannelTests {
    /// iPhone と Mac のハンドシェイクを、メモリ上でつないで行う。
    static func connect(
        client: StaticIdentity = StaticIdentity(),
        host: StaticIdentity = StaticIdentity()
    ) throws -> (client: SecureChannel, host: SecureChannel) {
        var clientHandshake = SecureHandshake(role: .initiator, localStatic: client)
        var hostHandshake = SecureHandshake(role: .responder, localStatic: host)

        let first = try clientHandshake.start()
        #expect(try hostHandshake.start().isEmpty)

        let hostStep1 = try hostHandshake.receive(first)
        #expect(hostStep1.channel == nil)
        let clientStep = try clientHandshake.receive(hostStep1.outgoing)
        let clientChannel = try #require(clientStep.channel)
        let hostStep2 = try hostHandshake.receive(clientStep.outgoing)
        #expect(hostStep2.outgoing.isEmpty)
        let hostChannel = try #require(hostStep2.channel)

        #expect(clientChannel.remoteStaticPublicKey == host.publicKey)
        #expect(hostChannel.remoteStaticPublicKey == client.publicKey)
        #expect(clientChannel.videoKey == hostChannel.videoKey)
        return (clientChannel, hostChannel)
    }

    @Test("ハンドシェイクのあと、両方向でメッセージをやり取りできる")
    func exchangeMessages() throws {
        var (client, host) = try Self.connect()

        let toHost: [ControlMessage] = [.ping(1), .text("テスト"), .requestKeyFrame]
        let bytes = try toHost.map { try client.seal($0) }.reduce(Data(), +)
        #expect(try host.receive(bytes) == toHost)

        let reply = try host.seal(.pong(1))
        #expect(try client.receive(reply.prefix(3)).isEmpty)
        #expect(try client.receive(reply.dropFirst(3)) == [.pong(1)])
    }

    @Test("ハンドシェイクの最後のメッセージと同時に届いたメッセージも読める")
    func messagesPipelinedWithHandshake() throws {
        var clientHandshake = SecureHandshake(role: .initiator, localStatic: StaticIdentity())
        var hostHandshake = SecureHandshake(role: .responder, localStatic: StaticIdentity())
        _ = try hostHandshake.start()
        let hostStep1 = try hostHandshake.receive(try clientHandshake.start())
        let clientStep = try clientHandshake.receive(hostStep1.outgoing)
        var client = try #require(clientStep.channel)

        // 最後のハンドシェイクメッセージの直後に、暗号化メッセージを続けて送る。
        let combined = clientStep.outgoing + (try client.seal(.hello(Hello(
            deviceName: "iPhone", screenWidth: 1, screenHeight: 1, supportedCodecs: [.hevc]))))
        let hostStep2 = try hostHandshake.receive(combined)
        var host = try #require(hostStep2.channel)
        let received = try host.receive()
        #expect(received.count == 1)
        guard case .hello = received.first else {
            Issue.record("hello が届いていない")
            return
        }
    }

    @Test("改ざんされたメッセージは復号でエラーになる")
    func tamperedMessageFails() throws {
        var (client, host) = try Self.connect()
        var bytes = try client.seal(.text("secret"))
        bytes[bytes.count - 1] ^= 0x80
        #expect(throws: RemoteCoreError.decryptionFailed) {
            try host.receive(bytes)
        }
    }

    @Test("同じメッセージをもう一度送り込まれても受け付けない（リプレイ）")
    func replayFails() throws {
        var (client, host) = try Self.connect()
        let bytes = try client.seal(.action(.spotlight))
        #expect(try host.receive(bytes) == [.action(.spotlight)])
        #expect(throws: RemoteCoreError.decryptionFailed) {
            try host.receive(bytes)
        }
    }
}
