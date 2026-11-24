import Foundation
import Testing
@testable import RemoteCore

@Suite("映像データの形式と画面の計算")
struct VideoBitstreamTests {
    // 種類の番号が分かるように、NAL ユニットの先頭バイトだけを本物に合わせたもの。
    let hevcVPS = Data([0x40, 0x01, 0x0C])
    let hevcSPS = Data([0x42, 0x01, 0x01])
    let hevcPPS = Data([0x44, 0x01, 0xC1])
    let hevcIDR = Data([0x26, 0x01, 0xAF, 0x00])
    let h264SPS = Data([0x67, 0x64, 0x00])
    let h264PPS = Data([0x68, 0xEE])
    let h264IDR = Data([0x65, 0x88, 0x84])

    @Test("長さ付きで並べて、分け直せる")
    func joinSplit() throws {
        let units = [hevcVPS, hevcSPS, hevcPPS, hevcIDR]
        let joined = VideoBitstream.join(units)
        #expect(joined.count == units.reduce(0) { $0 + $1.count + 4 })
        #expect(try VideoBitstream.split(joined) == units)
    }

    @Test("長さが 1・2 バイトの並びも分けられる")
    func splitOtherLengthSizes() throws {
        #expect(try VideoBitstream.split(Data([0x02, 0x65, 0x88, 0x01, 0x68]), lengthSize: 1) == [Data([0x65, 0x88]), Data([0x68])])
        #expect(try VideoBitstream.split(Data([0x00, 0x01, 0x67]), lengthSize: 2) == [Data([0x67])])
        #expect(throws: RemoteCoreError.self) { try VideoBitstream.split(Data([0x01]), lengthSize: 3) }
    }

    @Test("壊れた並びはエラーになる")
    func splitMalformed() {
        #expect(throws: RemoteCoreError.truncatedData) { try VideoBitstream.split(Data([0, 0, 0, 5, 1, 2])) }
        #expect(throws: RemoteCoreError.self) { try VideoBitstream.split(Data([0, 0, 0, 0])) }
    }

    @Test("パラメータセットを見分けて、決まった順に並べる")
    func parameterSets() {
        #expect(VideoBitstream.isParameterSet(hevcSPS, codec: .hevc))
        #expect(!VideoBitstream.isParameterSet(hevcIDR, codec: .hevc))
        #expect(VideoBitstream.isParameterSet(h264PPS, codec: .h264))
        #expect(!VideoBitstream.isParameterSet(h264IDR, codec: .h264))

        #expect(VideoBitstream.parameterSets(in: [hevcIDR, hevcPPS, hevcVPS, hevcSPS], codec: .hevc) == [hevcVPS, hevcSPS, hevcPPS])
        #expect(VideoBitstream.parameterSets(in: [h264PPS, h264SPS, h264IDR], codec: .h264) == [h264SPS, h264PPS])
        #expect(VideoBitstream.parameterSets(in: [hevcSPS, hevcPPS], codec: .hevc) == nil)
    }

    @Test("正規化した位置とグローバル座標の変換")
    func displayGeometry() {
        // メインモニターの右に置いた 2 台目（1920×1080 ポイント）
        let display = DisplayGeometry(originX: 1512, originY: -100, width: 1920, height: 1080)
        let center = display.globalPoint(normalizedX: 0.5, normalizedY: 0.5)
        #expect(center.x == 1512 + 960 && center.y == -100 + 540)

        // 端と範囲外は、モニターの中に収める
        let corner = display.globalPoint(normalizedX: 1, normalizedY: 1)
        #expect(corner.x == 1512 + 1919 && corner.y == -100 + 1079)
        let outside = display.globalPoint(normalizedX: -2, normalizedY: 5)
        #expect(outside.x == 1512 && outside.y == -100 + 1079)

        let back = display.normalized(x: center.x, y: center.y)
        #expect(back.x == 0.5 && back.y == 0.5)
        #expect(display.contains(x: 1512, y: -100))
        #expect(!display.contains(x: 1511, y: 0))
    }

    @Test("映像の大きさは縦横比を保って縮め、偶数にそろえる")
    func scaledSize() {
        #expect(VideoSizing.scaledSize(width: 3024, height: 1964, maxLongEdge: 2560) == (2560, 1662))
        #expect(VideoSizing.scaledSize(width: 1920, height: 1080, maxLongEdge: 2560) == (1920, 1080)) // 拡大しない
        #expect(VideoSizing.scaledSize(width: 1081, height: 1921, maxLongEdge: 4000) == (1080, 1920)) // 偶数に
        #expect(VideoSizing.scaledSize(width: 0, height: 100, maxLongEdge: 100) == (0, 0))
    }
}
