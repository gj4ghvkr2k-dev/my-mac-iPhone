import Foundation
import Testing
@testable import RemoteCore

@Suite("映像パケット")
struct VideoPacketTests {
    let key = Data(repeating: 0x42, count: 32)

    func frameData(_ size: Int, seed: UInt8) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0) &+ seed })
    }

    @Test("分割して組み立てると元のフレームに戻る", arguments: [0, 1, 1166, 1167, 50_000])
    func roundTrip(size: Int) throws {
        var packetizer = try VideoPacketizer(key: key)
        var reassembler = try VideoReassembler(key: key)
        let data = frameData(size, seed: 3)
        let packets = try packetizer.packetize(data: data, isKeyFrame: true, timestampMicros: 99)
        #expect(packets.allSatisfy { $0.count <= VideoPacketCodec.maxPacketLength })
        #expect(packets.count == max(1, (size + 1165) / 1166))

        var events: [VideoReassembler.Event] = []
        for packet in packets.reversed() { // 順番が入れ替わって届いてもよい
            events += reassembler.ingest(packet)
        }
        #expect(events == [.frame(VideoFrame(frameNumber: 0, isKeyFrame: true, timestampMicros: 99, data: data))])
    }

    @Test("欠けたフレームは捨て、キーフレームまで表示しない")
    func lossWaitsForKeyFrame() throws {
        var packetizer = try VideoPacketizer(key: key)
        var reassembler = try VideoReassembler(key: key)

        let f0 = try packetizer.packetize(data: frameData(3000, seed: 0), isKeyFrame: true, timestampMicros: 0)
        let f1 = try packetizer.packetize(data: frameData(3000, seed: 1), isKeyFrame: false, timestampMicros: 1)
        let f2 = try packetizer.packetize(data: frameData(3000, seed: 2), isKeyFrame: false, timestampMicros: 2)
        let f3 = try packetizer.packetize(data: frameData(3000, seed: 3), isKeyFrame: true, timestampMicros: 3)

        #expect(f0.flatMap { reassembler.ingest($0) }.count == 1)
        // フレーム 1 の 2 番目の分割が届かない
        _ = reassembler.ingest(f1[0])
        _ = reassembler.ingest(f1[2])
        // フレーム 2 は揃うが、1 が欠けたので表示せずキーフレームを要求する
        let events2 = f2.flatMap { reassembler.ingest($0) }
        #expect(events2 == [.requestKeyFrame])
        // 遅れて届いたフレーム 1 の分割は捨てる
        #expect(reassembler.ingest(f1[1]).isEmpty)
        // キーフレームで復帰する
        let events3 = f3.flatMap { reassembler.ingest($0) }
        guard case .frame(let frame) = events3.last else {
            Issue.record("キーフレームが表示されていない: \(events3)")
            return
        }
        #expect(frame.frameNumber == 3 && frame.isKeyFrame)
    }

    @Test("最初のフレームがキーフレームでなければ要求する")
    func startsWithKeyFrame() throws {
        var packetizer = try VideoPacketizer(key: key)
        var reassembler = try VideoReassembler(key: key)
        let packets = try packetizer.packetize(data: frameData(10, seed: 0), isKeyFrame: false, timestampMicros: 0)
        #expect(reassembler.ingest(packets[0]) == [.requestKeyFrame])
    }

    @Test("重複したパケットは無視する")
    func duplicatesIgnored() throws {
        var packetizer = try VideoPacketizer(key: key)
        var reassembler = try VideoReassembler(key: key)
        let packets = try packetizer.packetize(data: frameData(2000, seed: 0), isKeyFrame: true, timestampMicros: 0)
        #expect(reassembler.ingest(packets[0]).isEmpty)
        #expect(reassembler.ingest(packets[0]).isEmpty)
        #expect(reassembler.ingest(packets[1]).count == 1)
        #expect(reassembler.ingest(packets[1]).isEmpty)
    }

    @Test("改ざん・別の鍵・壊れたパケットは捨てる")
    func rejectsBadPackets() throws {
        var packetizer = try VideoPacketizer(key: key)
        var reassembler = try VideoReassembler(key: key)
        var other = try VideoPacketizer(key: Data(repeating: 1, count: 32))

        var tampered = try packetizer.packetize(data: frameData(10, seed: 0), isKeyFrame: true, timestampMicros: 0)[0]
        tampered[5] ^= 0x01 // ヘッダー（分割番号）を書き換える
        #expect(reassembler.ingest(tampered).isEmpty)
        #expect(reassembler.ingest(try other.packetize(data: frameData(10, seed: 0), isKeyFrame: true, timestampMicros: 0)[0]).isEmpty)
        #expect(reassembler.ingest(Data([0x01, 0x02])).isEmpty)
        #expect(reassembler.rejectedPacketCount == 3)
    }

    @Test("組み立て途中のフレームがたまりすぎたら古いものを捨てる")
    func pendingOverflow() throws {
        var packetizer = try VideoPacketizer(key: key)
        var reassembler = try VideoReassembler(key: key, maxPendingFrames: 2)
        var events: [VideoReassembler.Event] = []
        for i in 0..<3 {
            let packets = try packetizer.packetize(data: frameData(2000, seed: UInt8(i)), isKeyFrame: true, timestampMicros: 0)
            events += reassembler.ingest(packets[0]) // 最初の分割だけ届く
        }
        #expect(events == [.requestKeyFrame])
    }
}
