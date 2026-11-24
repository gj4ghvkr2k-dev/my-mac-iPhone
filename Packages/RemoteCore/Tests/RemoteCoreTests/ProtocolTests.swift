import Foundation
import Testing
@testable import RemoteCore

@Suite("メッセージと区切り")
struct ProtocolTests {
    static let allMessages: [ControlMessage] = [
        .hello(Hello(deviceName: "太郎の iPhone", screenWidth: 1179, screenHeight: 2556, supportedCodecs: [.hevc, .h264])),
        .helloAck(HelloAck(hostName: "MacBook Pro", videoPort: 50123, codec: .hevc,
                           displays: [DisplayInfo(id: 1, name: "内蔵", widthPixels: 3024, heightPixels: 1964, scale: 2, isMain: true)],
                           activeDisplayID: 1)),
        .pair(PairRequest(token: Data(repeating: 7, count: 16), deviceName: "iPad")),
        .pairResult(PairResult(accepted: false, hostName: "Mac", failure: .expired)),
        .disconnect(.replacedByAnotherDevice),
        .selectDisplay(displayID: 0xDEAD_BEEF),
        .streamConfig(StreamConfig(maxLongEdge: 1920, framesPerSecond: 30, bitrateKbps: 4000)),
        .requestKeyFrame,
        .pointerMove(.absolute(x: 0.25, y: 0.75)),
        .pointerMove(.relative(dx: -3.5, dy: 12)),
        .pointerButton(PointerButton(button: .right, isDown: true, clickCount: 2)),
        .scroll(Scroll(dx: 0, dy: -42.5, phase: .momentum)),
        .key(KeyEvent(keyCode: 0x31, isDown: true, modifiers: [.command, .shift])),
        .text("こんにちは、世界 🌏"),
        .action(.missionControl),
        .cursorState(CursorState(x: 0.5, y: 0.1, isVisible: true)),
        .ping(1_234_567_890_123),
        .pong(.max),
    ]

    @Test("すべてのメッセージを書き出して読み戻せる", arguments: allMessages)
    func roundTrip(message: ControlMessage) throws {
        #expect(try ControlMessage(decoding: message.encoded()) == message)
    }

    @Test("入力イベントは固定長のバイナリ")
    func inputEventsAreCompact() throws {
        #expect(try ControlMessage.pointerMove(.relative(dx: 1, dy: 2)).encoded().count == 10)
        #expect(try ControlMessage.key(KeyEvent(keyCode: 1, isDown: true)).encoded().count == 8)
        #expect(try ControlMessage.scroll(Scroll(dx: 1, dy: 2, phase: .began)).encoded().count == 10)
    }

    @Test("壊れたメッセージは読み込みでエラーになる")
    func malformedMessages() {
        #expect(throws: RemoteCoreError.unknownMessageType(0xFF)) { try ControlMessage(decoding: Data([0xFF])) }
        #expect(throws: RemoteCoreError.truncatedData) { try ControlMessage(decoding: Data([0x20, 0x00, 0x01])) }
        #expect(throws: RemoteCoreError.trailingData) { try ControlMessage(decoding: Data([0x12, 0x00])) }
        #expect(throws: RemoteCoreError.self) { try ControlMessage(decoding: Data([0x05, 0x63])) }
        #expect(throws: RemoteCoreError.self) { try ControlMessage(decoding: Data([0x01]) + Data("{".utf8)) }
        #expect(throws: RemoteCoreError.truncatedData) { try ControlMessage(decoding: Data()) }
        // NaN の座標は受け付けない
        var w = ByteWriter()
        w.write(UInt8(0x20)); w.write(UInt8(0)); w.write(Float.nan); w.write(Float(0))
        #expect(throws: RemoteCoreError.self) { try ControlMessage(decoding: w.data) }
    }

    @Test("区切りは分割・結合されて届いても正しく取り出せる")
    func framingAcrossChunks() throws {
        let payloads = [Data("a".utf8), Data(), Data(repeating: 9, count: 1000), Data("最後".utf8)]
        let stream = try payloads.map(Framing.frame).reduce(Data(), +)

        for chunkSize in [1, 2, 3, 7, 500, stream.count] {
            var decoder = FrameDecoder()
            var received: [Data] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decoder.append(stream.subdata(in: offset..<end))
                while let frame = decoder.nextFrame() { received.append(frame) }
                offset = end
            }
            #expect(received == payloads, "chunk size \(chunkSize)")
            #expect(decoder.bufferedBytes.isEmpty)
        }
    }

    @Test("最大長を超える本体は区切れない")
    func frameTooLarge() throws {
        _ = try Framing.frame(Data(count: Framing.maxFrameLength))
        #expect(throws: RemoteCoreError.frameTooLarge(Framing.maxFrameLength + 1)) {
            try Framing.frame(Data(count: Framing.maxFrameLength + 1))
        }
    }
}

extension ControlMessage: CustomTestStringConvertible {
    public var testDescription: String {
        String(describing: self).prefix(60).description
    }
}
