import Foundation
import Network
import RemoteCore
import UIKit

/// 映像の画質の設定。
enum StreamQuality: String, CaseIterable, Identifiable {
    case low
    case standard
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "低（回線が遅いとき）"
        case .standard: return "標準"
        case .high: return "高"
        }
    }

    var config: StreamConfig {
        switch self {
        case .low: return StreamConfig(maxLongEdge: 1600, framesPerSecond: 30, bitrateKbps: 3_000)
        case .standard: return StreamConfig(maxLongEdge: 2560, framesPerSecond: 60, bitrateKbps: 10_000)
        case .high: return StreamConfig(maxLongEdge: 3200, framesPerSecond: 60, bitrateKbps: 20_000)
        }
    }
}

/// Mac との 1 回分の接続。制御の通信路（TCP）と映像の通信路（UDP）をまとめる。
///
/// すべてメインキューで動く。
final class RemoteSession: ObservableObject {
    /// 接続先の Mac をどう確かめるか。
    enum Expectation {
        /// 登録済み：公開鍵が一致すること。
        case trusted(TrustedPeer)
        /// 登録中：QR コードの鍵と一致すること。一致したらトークンを送って登録してもらう。
        case pairing(PairingInvitation)
    }

    enum State: Equatable {
        case connecting
        case pairing
        case connected
        case disconnected(String)
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var hostName: String
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var activeDisplayID: UInt32 = 0
    @Published private(set) var codec: VideoCodec = .hevc
    @Published private(set) var pathDescription = "-"
    @Published private(set) var roundTripMillis: Double?
    @Published private(set) var framesPerSecond: Double = 0
    @Published var quality: StreamQuality = .standard {
        didSet { if quality != oldValue { sendStreamConfig() } }
    }

    /// 端末登録が終わった（保存は呼び出し側で行う）。
    var onPaired: ((TrustedPeer) -> Void)?
    /// 映像の通信路の準備ができ、Mac が映像の形式を決めた。
    var onVideoReady: ((VideoCodec) -> Void)?
    var onFrame: ((VideoFrame) -> Void)?
    var onCursor: ((CursorState) -> Void)?

    private let endpoint: NWEndpoint
    private let identity: StaticIdentity
    private let expectation: Expectation
    private let deviceName: String
    private var control: SecureControlConnection?
    private var datagram: DatagramConnection?
    private var reassembler: VideoReassembler?
    private var registrationCounter: UInt64 = 0
    private var timers: [DispatchSourceTimer] = []
    private var lastKeyFrameRequest: UInt64 = 0
    private var frameRate = RateCounter()
    private var remoteKey: Data?

    init(endpoint: NWEndpoint, identity: StaticIdentity, expectation: Expectation, deviceName: String) {
        self.endpoint = endpoint
        self.identity = identity
        self.expectation = expectation
        self.deviceName = deviceName
        switch expectation {
        case .trusted(let peer): hostName = peer.name
        case .pairing(let invitation): hostName = invitation.hostName
        }
    }

    deinit {
        timers.forEach { $0.cancel() }
    }

    // MARK: - 接続・切断

    func start() {
        guard control == nil else { return }
        state = .connecting
        let connection = NWConnection(to: endpoint, using: NetworkSetup.tcpParameters())
        let control = SecureControlConnection(connection: connection, role: .initiator, identity: identity)
        control.onStateChange = { [weak self] state in
            if case .ready = state {
                self?.pathDescription = connection.currentPath?.interfaceDescription ?? "不明"
            }
        }
        control.onReady = { [weak self] remoteKey in self?.handshakeCompleted(remoteKey: remoteKey) }
        control.onMessage = { [weak self] message in self?.handle(message) }
        control.onClose = { [weak self] reason in
            guard let self else { return }
            if case .disconnected = self.state { return }
            self.finish(reason.map { "接続が切れました（\($0)）" } ?? "接続が切れました")
        }
        self.control = control
        control.start()

        // 15 秒たっても接続できなければ諦める。
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.state == .connecting || self.state == .pairing else { return }
            self.stop(reason: "Mac に接続できませんでした。同じ Wi-Fi にいるか、Mac で MacRemote が起動しているか確認してください")
        }
    }

    func stop(reason: String = "切断しました") {
        control?.close(sending: .disconnect(.normal))
        finish(reason)
    }

    private func finish(_ reason: String) {
        timers.forEach { $0.cancel() }
        timers = []
        datagram?.cancel()
        datagram = nil
        reassembler = nil
        control = nil
        state = .disconnected(reason)
    }

    // MARK: - 送信（操作など）

    func send(_ message: ControlMessage) {
        guard state == .connected || message.isAllowedBeforeConnected else { return }
        control?.send(message)
    }

    func selectDisplay(_ id: UInt32) {
        activeDisplayID = id
        send(.selectDisplay(displayID: id))
    }

    func requestKeyFrame() {
        let now = monotonicMicros()
        guard now - lastKeyFrameRequest > 250_000 else { return }
        lastKeyFrameRequest = now
        send(.requestKeyFrame)
    }

    /// 今選んでいるモニターの情報。
    var activeDisplay: DisplayInfo? {
        displays.first { $0.id == activeDisplayID } ?? displays.first
    }

    // MARK: - 受信

    private func handshakeCompleted(remoteKey: Data) {
        self.remoteKey = remoteKey
        switch expectation {
        case .trusted(let peer):
            guard peer.publicKey == remoteKey else {
                stop(reason: "Mac の鍵が登録したときと違うため、接続を中止しました。もう一度 QR コードで登録してください")
                return
            }
            sendHello()
        case .pairing(let invitation):
            guard invitation.matchesHost(publicKey: remoteKey) else {
                stop(reason: "QR コードの Mac と違う相手につながったため、中止しました")
                return
            }
            state = .pairing
            control?.send(.pair(PairRequest(token: invitation.token, deviceName: deviceName)))
        }
    }

    private func sendHello() {
        let bounds = UIScreen.main.nativeBounds
        control?.send(.hello(Hello(
            deviceName: deviceName,
            screenWidth: Int(max(bounds.width, bounds.height)),
            screenHeight: Int(min(bounds.width, bounds.height)),
            supportedCodecs: [.hevc, .h264]
        )))
    }

    private func handle(_ message: ControlMessage) {
        switch message {
        case .pairResult(let result):
            guard result.accepted, let remoteKey else {
                let reason: String
                switch result.failure {
                case .expired?: reason = "QR コードの有効期限が切れています。Mac で新しい QR コードを表示してください"
                default: reason = "登録できませんでした。Mac で新しい QR コードを表示して、もう一度読み取ってください"
                }
                stop(reason: reason)
                return
            }
            hostName = result.hostName
            onPaired?(TrustedPeer(publicKey: remoteKey, name: result.hostName))
            sendHello()

        case .helloAck(let ack):
            hostName = ack.hostName
            displays = ack.displays
            activeDisplayID = ack.activeDisplayID
            codec = ack.codec
            state = .connected
            onVideoReady?(ack.codec)
            startVideo(port: ack.videoPort)
            startPings()
            sendStreamConfig()

        case .pong(let sent):
            let now = monotonicMicros()
            if now >= sent { roundTripMillis = Double(now - sent) / 1000 }

        case .cursorState(let cursor):
            onCursor?(cursor)

        case .disconnect(let reason):
            let text: String
            switch reason {
            case .replacedByAnotherDevice: text = "別の端末が Mac に接続したため、切断されました"
            case .notAuthorized: text = "この端末は Mac に登録されていません。Mac で QR コードを表示して、登録し直してください"
            case .protocolMismatch: text = "Mac のアプリと、この端末のアプリのバージョンが合いません"
            case .hostShuttingDown: text = "Mac のアプリが終了しました"
            case .normal: text = "Mac から切断されました"
            }
            stop(reason: text)

        default:
            break
        }
    }

    private func sendStreamConfig() {
        send(.streamConfig(quality.config))
    }

    // MARK: - 映像（UDP）

    private func startVideo(port: UInt16) {
        guard let connection = control?.connection,
              let path = connection.currentPath,
              case let .hostPort(host, _)? = path.remoteEndpoint,
              let udpPort = NWEndpoint.Port(rawValue: port),
              let videoKey = control?.videoKey else {
            stop(reason: "映像の通信路を準備できませんでした")
            return
        }
        reassembler = try? VideoReassembler(key: videoKey)

        // 制御の通信路と同じ経路（Wi-Fi 直結なら awdl0）に限定する。
        let parameters = NetworkSetup.udpParameters(requiredInterface: path.availableInterfaces.first)
        let datagram = DatagramConnection(connection: NWConnection(host: host, port: udpPort, using: parameters))
        datagram.onDatagram = { [weak self] packet in self?.receive(packet) }
        self.datagram = datagram
        datagram.start()

        // 映像の送り先を Mac に知らせる。経路の変化に備えて 1 秒ごとに送り直す。
        sendRegistration(videoKey: videoKey)
        addTimer(every: .seconds(1)) { [weak self] in self?.sendRegistration(videoKey: videoKey) }
    }

    private func sendRegistration(videoKey: Data) {
        registrationCounter += 1
        datagram?.send(UDPRegistration.make(counter: registrationCounter, videoKey: videoKey))
    }

    private func receive(_ packet: Data) {
        guard var reassembler else { return }
        let events = reassembler.ingest(packet)
        self.reassembler = reassembler
        for event in events {
            switch event {
            case .frame(let frame):
                onFrame?(frame)
                if frameRate.add(bytes: frame.data.count) {
                    framesPerSecond = frameRate.perSecond
                }
            case .requestKeyFrame:
                requestKeyFrame()
            }
        }
    }

    // MARK: - 補助

    private func startPings() {
        addTimer(every: .seconds(1)) { [weak self] in
            self?.send(.ping(monotonicMicros()))
            // 映像が止まっていたら、表示を 0 fps にする。
            if let self, self.frameRate.flushIfNeeded() { self.framesPerSecond = self.frameRate.perSecond }
        }
    }

    private func addTimer(every interval: DispatchTimeInterval, _ handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }
}

private extension ControlMessage {
    /// 接続が完了する前（端末登録中など）に送ってよいメッセージ。
    var isAllowedBeforeConnected: Bool {
        switch self {
        case .disconnect: return true
        default: return false
        }
    }
}
