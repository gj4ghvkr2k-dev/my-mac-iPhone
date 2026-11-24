import CoreVideo
import Foundation
import RemoteCore

/// 画面の取り込み → 圧縮 → パケット化 → 送信、をつなぐ。
///
/// 圧縮とパケット化は専用のキュー（`queue`）で行い、メインキューを止めない。
/// 公開しているメソッドはメインキューから呼ぶこと。
final class VideoStreamer {
    struct Configuration: Equatable {
        var display: HostDisplay
        var codec: VideoCodec
        var stream: StreamConfig
    }

    /// 送信の状況（例：「60 fps、9.8 Mbps」）。メインキューで呼ばれる。
    var onStats: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let capturer = ScreenCapturer()
    private let queue = DispatchQueue(label: "macremote.video", qos: .userInteractive)
    private(set) var configuration: Configuration?

    // ここから下は `queue` の上だけで触る。
    private var encoder: VideoEncoder?
    private var packetizer: VideoPacketizer
    private var sender: (([Data]) -> Void)?
    private var forceKeyFrame = true
    private var latestPixelBuffer: CVPixelBuffer?
    private var lastEncodeMicros: UInt64 = 0
    /// 圧縮処理に渡した時刻。前のフレームより必ず後にする（取り込みと再送が前後することがあるため）。
    private var lastPresentationMicros: UInt64 = 0
    private var refreshTimer: DispatchSourceTimer?
    private var rate = RateCounter()

    init(videoKey: Data) throws {
        packetizer = try VideoPacketizer(key: videoKey)
        capturer.onFrame = { [weak self] pixelBuffer, captureMicros in
            self?.queue.async { self?.encode(pixelBuffer, captureMicros: captureMicros) }
        }
        capturer.onStop = { [weak self] error in
            self?.onError?("画面の取り込みが止まりました：\(error?.localizedDescription ?? "不明な理由")")
        }
    }

    /// 映像の送り先を決める（iPhone の UDP の宛先が分かったとき）。
    func setSender(_ sender: (([Data]) -> Void)?) {
        queue.async {
            self.sender = sender
            self.forceKeyFrame = true
            self.encodeLatest()
        }
    }

    func requestKeyFrame() {
        queue.async {
            self.forceKeyFrame = true
            self.encodeLatest()
        }
    }

    /// 取り込みを始める。設定が変わったときも呼ぶ（ビットレートだけの変更なら作り直さない）。
    func apply(_ newConfiguration: Configuration) {
        let old = configuration
        configuration = newConfiguration
        if let old, old.display == newConfiguration.display, old.codec == newConfiguration.codec,
           old.stream.maxLongEdge == newConfiguration.stream.maxLongEdge,
           old.stream.framesPerSecond == newConfiguration.stream.framesPerSecond {
            let kbps = newConfiguration.stream.bitrateKbps
            queue.async { self.encoder?.setBitrate(kbps: kbps) }
            return
        }
        restart(newConfiguration)
    }

    func stop() {
        configuration = nil
        Task { @MainActor in await self.capturer.stop() }
        queue.async {
            self.refreshTimer?.cancel()
            self.refreshTimer = nil
            self.encoder?.invalidate()
            self.encoder = nil
            self.latestPixelBuffer = nil
        }
    }

    // MARK: - 内部

    private func restart(_ configuration: Configuration) {
        let display = configuration.display
        let stream = configuration.stream
        let size = VideoSizing.scaledSize(width: display.pixelWidth, height: display.pixelHeight,
                                          maxLongEdge: stream.maxLongEdge)
        let fps = max(1, min(120, stream.framesPerSecond))

        queue.async {
            self.encoder?.invalidate()
            self.latestPixelBuffer = nil
            do {
                let encoder = try VideoEncoder(codec: configuration.codec, width: size.width, height: size.height,
                                               framesPerSecond: fps, bitrateKbps: stream.bitrateKbps)
                encoder.onEncodedFrame = { [weak self] frame in
                    self?.queue.async { self?.send(frame) }
                }
                encoder.onError = { [weak self] message in
                    DispatchQueue.main.async { self?.onError?(message) }
                }
                self.encoder = encoder
                self.forceKeyFrame = true
                self.startRefreshTimer()
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.onError?(message) }
            }
        }

        let settings = ScreenCapturer.Settings(displayID: display.id, width: size.width, height: size.height,
                                               framesPerSecond: fps)
        Task { @MainActor in
            do {
                try await self.capturer.start(settings)
            } catch {
                self.onError?("画面を取り込めません：\(error.localizedDescription)")
            }
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, captureMicros: UInt64) {
        guard let encoder else { return }
        latestPixelBuffer = pixelBuffer
        let presentation = max(captureMicros, lastPresentationMicros + 1)
        lastPresentationMicros = presentation
        lastEncodeMicros = monotonicMicros()
        let key = forceKeyFrame
        forceKeyFrame = false
        encoder.encode(pixelBuffer, captureMicros: presentation, forceKeyFrame: key)
    }

    /// 画面に変化がなくても、最後のフレームをもう一度圧縮して送る（キーフレームの要求に応えるため）。
    private func encodeLatest() {
        guard let latestPixelBuffer else { return }
        encode(latestPixelBuffer, captureMicros: monotonicMicros())
    }

    /// 画面に変化がない間も、0.5 秒に 1 回はフレームを送る。
    /// 最後のフレームが欠けたとき、iPhone 側が次のフレームで欠けに気づけるようにするため（中身はほぼ空なので小さい）。
    private func startRefreshTimer() {
        refreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = monotonicMicros()
            if now > self.lastEncodeMicros, now - self.lastEncodeMicros > 500_000 {
                self.encodeLatest()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func send(_ frame: VideoEncoder.EncodedFrame) {
        guard let sender else { return }
        do {
            let packets = try packetizer.packetize(data: frame.data, isKeyFrame: frame.isKeyFrame,
                                                   timestampMicros: frame.captureMicros)
            sender(packets)
            if rate.add(bytes: packets.reduce(0) { $0 + $1.count }) {
                let text = String(format: "%.0f fps、%.1f Mbps", rate.perSecond, rate.megabitsPerSecond)
                DispatchQueue.main.async { self.onStats?(text) }
            }
        } catch {
            let message = "映像パケットを作れません：\(error)"
            DispatchQueue.main.async { self.onError?(message) }
        }
    }
}
