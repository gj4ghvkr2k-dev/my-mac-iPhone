import Foundation
import Network
import RemoteCore

/// 検証用：Mac 側の待ち受け。
///
/// - Bonjour（`_macremote._tcp`）で公開し、Wi-Fi 直結（AWDL）でも見つかるようにする。
/// - TCP で Noise ハンドシェイクをし、ping に pong を返す。
/// - UDP で往復確認パケットに返事をし、擬似的な映像を送る。
///
/// 検証用なので、端末登録の確認はしない（どの端末でもつながる）。
/// 処理はすべてメインキューで行う。
final class ProbeHostService: ObservableObject {
    @Published private(set) var status = "停止中"
    @Published private(set) var tcpPort = "-"
    @Published private(set) var udpPort = "-"
    @Published private(set) var clientDescription = "なし"
    @Published private(set) var streamDescription = "停止中"
    @Published private(set) var logLines: [String] = []

    let identity: StaticIdentity
    let hostName: String

    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var client: ClientSession?
    private var udpPeer: DatagramConnection?

    private var streamTimer: DispatchSourceTimer?
    private var packetizer: VideoPacketizer?
    private var streamConfig = StreamConfig()
    private var framesSinceKeyFrame = 0
    private var keyFrameRequested = true
    private var sendRate = RateCounter()

    init() {
        identity = Self.loadOrCreateIdentity()
        hostName = Host.current().localizedName ?? "Mac"
    }

    // MARK: - 待ち受け

    func start() {
        guard tcpListener == nil else { return }
        do {
            try startUDPListener()
            try startTCPListener()
            status = "待ち受け中（ID: \(identity.hostID)）"
        } catch {
            status = "待ち受けを開始できません：\(error)"
            log("待ち受けの開始に失敗：\(error)")
        }
    }

    private func startTCPListener() throws {
        let listener = try NWListener(using: NetworkSetup.tcpParameters())
        let txt = NWTXTRecord([
            ProtocolInfo.TXTKey.version: String(ProtocolInfo.version),
            ProtocolInfo.TXTKey.hostID: identity.hostID,
        ])
        listener.service = NWListener.Service(name: hostName, type: ProtocolInfo.bonjourServiceType,
                                              domain: nil, txtRecord: txt)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.tcpPort = self.tcpListener?.port.map { String($0.rawValue) } ?? "-"
                self.log("TCP の待ち受けを開始：ポート \(self.tcpPort)")
            case .failed(let error):
                self.log("TCP の待ち受けが失敗：\(error)")
                self.status = "TCP の待ち受けが失敗しました"
            default:
                break
            }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if case .add(let endpoint) = change {
                self?.log("Bonjour に登録：\(endpoint)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .main)
        tcpListener = listener
    }

    private func startUDPListener() throws {
        let listener = try NWListener(using: NetworkSetup.udpParameters(), on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.udpPort = self.udpListener?.port.map { String($0.rawValue) } ?? "-"
                self.log("UDP の待ち受けを開始：ポート \(self.udpPort)")
            case .failed(let error):
                self.log("UDP の待ち受けが失敗：\(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptUDP(connection)
        }
        listener.start(queue: .main)
        udpListener = listener
    }

    // MARK: - TCP（制御）

    private func accept(_ connection: NWConnection) {
        if let old = client {
            log("新しい接続が来たので、前の接続を切ります")
            old.send(.disconnect(.replacedByAnotherDevice))
            old.close()
        }
        stopStream()

        let session = ClientSession(connection: connection, identity: identity)
        session.onLog = { [weak self] message in self?.log(message) }
        session.onReady = { [weak self, weak session] in
            guard let self, let session else { return }
            self.clientDescription = "接続中：\(session.remoteDescription)"
            self.log("ハンドシェイク完了：\(session.remoteDescription)")
        }
        session.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.handle(message, from: session)
        }
        session.onClose = { [weak self, weak session] in
            guard let self, let session, self.client === session else { return }
            self.client = nil
            self.clientDescription = "なし"
            self.stopStream()
            self.log("接続が切れました")
        }
        client = session
        session.start()
    }

    private func handle(_ message: ControlMessage, from session: ClientSession) {
        switch message {
        case .hello(let hello):
            log("Hello：\(hello.deviceName)（\(hello.screenWidth)×\(hello.screenHeight)）")
            let port = udpListener?.port?.rawValue ?? 0
            session.send(.helloAck(HelloAck(hostName: hostName, videoPort: port, codec: .hevc,
                                            displays: [], activeDisplayID: 0)))
        case .ping(let value):
            session.send(.pong(value))
        case .streamConfig(let config):
            startStream(config: config, videoKey: session.videoKey)
        case .requestKeyFrame:
            keyFrameRequested = true
        case .disconnect:
            session.close()
        default:
            log("（検証用アプリでは使わないメッセージ：\(message)）")
        }
    }

    // MARK: - UDP（映像）

    private func acceptUDP(_ connection: NWConnection) {
        udpPeer?.cancel()
        let peer = DatagramConnection(connection: connection)
        peer.onStateChange = { [weak self] state in
            if case .ready = state {
                self?.log("UDP の相手：\(connection.endpoint)（\(connection.currentPath?.interfaceDescription ?? "不明")）")
            }
        }
        peer.onDatagram = { [weak peer] datagram in
            if let pong = ProbeDatagram.pong(forPing: datagram) {
                peer?.send(pong)
            }
        }
        udpPeer = peer
        peer.start()
    }

    /// 擬似的な映像を送る。中身に意味はなく、大きさと間隔だけを本物に合わせている。
    private func startStream(config: StreamConfig, videoKey: Data) {
        stopStream()
        guard let packetizer = try? VideoPacketizer(key: videoKey) else { return }
        self.packetizer = packetizer
        streamConfig = config
        framesSinceKeyFrame = 0
        keyFrameRequested = true

        let fps = max(1, min(120, config.framesPerSecond))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sendFrame() }
        timer.resume()
        streamTimer = timer
        log("擬似映像の送信を開始：\(config.bitrateKbps) kbps、\(fps) fps")
    }

    private func stopStream() {
        streamTimer?.cancel()
        streamTimer = nil
        packetizer = nil
        streamDescription = "停止中"
    }

    private func sendFrame() {
        guard var packetizer, let udpPeer else { return }
        let fps = max(1, streamConfig.framesPerSecond)
        let averageFrameBytes = max(100, streamConfig.bitrateKbps * 1000 / 8 / fps)

        // キーフレームは 2 秒ごと、または要求されたときに送る。大きさは普段の 4 倍。
        let isKeyFrame = keyFrameRequested || framesSinceKeyFrame >= fps * 2
        let size = isKeyFrame ? averageFrameBytes * 4 : averageFrameBytes
        keyFrameRequested = false
        framesSinceKeyFrame = isKeyFrame ? 0 : framesSinceKeyFrame + 1

        do {
            let packets = try packetizer.packetize(data: Data(repeating: 0xA5, count: size),
                                                   isKeyFrame: isKeyFrame,
                                                   timestampMicros: monotonicMicros())
            self.packetizer = packetizer
            udpPeer.send(packets)
            if sendRate.add(bytes: packets.reduce(0) { $0 + $1.count }) {
                streamDescription = String(format: "送信中：%.0f fps、%.1f Mbps",
                                           sendRate.perSecond, sendRate.megabitsPerSecond)
            }
        } catch {
            log("映像パケットの作成に失敗：\(error)")
            stopStream()
        }
    }

    // MARK: - 補助

    private func log(_ message: String) {
        let time = Self.timeFormatter.string(from: Date())
        logLines.append("\(time) \(message)")
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 検証用なので UserDefaults に保存する（本番の MacHost では Keychain に保存する）。
    private static func loadOrCreateIdentity() -> StaticIdentity {
        let key = "probe.identity"
        if let stored = UserDefaults.standard.data(forKey: key),
           let identity = try? StaticIdentity(privateKey: stored) {
            return identity
        }
        let identity = StaticIdentity()
        UserDefaults.standard.set(identity.privateKey, forKey: key)
        return identity
    }
}

/// 接続してきた 1 台分の制御の通信路。
final class ClientSession {
    private let stream: StreamConnection
    private var handshake: SecureHandshake
    private var channel: SecureChannel?

    var onReady: (() -> Void)?
    var onMessage: ((ControlMessage) -> Void)?
    var onClose: (() -> Void)?
    var onLog: ((String) -> Void)?

    init(connection: NWConnection, identity: StaticIdentity) {
        stream = StreamConnection(connection: connection)
        handshake = SecureHandshake(role: .responder, localStatic: identity)
    }

    var videoKey: Data { channel?.videoKey ?? Data() }

    var remoteDescription: String {
        let endpoint = stream.connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? "\(stream.connection.endpoint)"
        let interface = stream.connection.currentPath?.interfaceDescription ?? "不明"
        let key = channel.map { HostID.make(publicKey: $0.remoteStaticPublicKey) } ?? "-"
        return "\(endpoint)、経路 \(interface)、鍵 \(key)"
    }

    func start() {
        stream.onData = { [weak self] data in self?.receive(data) }
        stream.onClose = { [weak self] error in
            if let error { self?.onLog?("TCP エラー：\(error)") }
            self?.onClose?()
        }
        stream.start()
        do {
            _ = try handshake.start() // 待ち受け側は最初に送るものはない
        } catch {
            fail("ハンドシェイクを開始できません：\(error)")
        }
    }

    func send(_ message: ControlMessage) {
        guard var channel else { return }
        do {
            stream.send(try channel.seal(message))
            self.channel = channel
        } catch {
            fail("メッセージを暗号化できません：\(error)")
        }
    }

    func close() {
        stream.cancel()
    }

    private func receive(_ data: Data) {
        do {
            if var channel {
                let messages = try channel.receive(data)
                self.channel = channel
                messages.forEach { onMessage?($0) }
                return
            }
            let step = try handshake.receive(data)
            stream.send(step.outgoing)
            if var newChannel = step.channel {
                let messages = try newChannel.receive()
                channel = newChannel
                onReady?()
                messages.forEach { onMessage?($0) }
            }
        } catch {
            fail("受信データを処理できません：\(error)")
        }
    }

    private func fail(_ message: String) {
        onLog?(message)
        stream.cancel()
    }
}
