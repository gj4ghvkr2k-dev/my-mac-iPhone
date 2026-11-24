import Foundation
import Network
import RemoteCore
import UIKit

/// Bonjour で見つかった Mac。
struct DiscoveredHost: Identifiable, Equatable {
    let id: String
    let name: String
    let hostID: String?
    let interfaces: String
    let endpoint: NWEndpoint
}

/// 検証用：iPhone 側。Mac を探して接続し、遅延と映像の届き方を計測する。
///
/// 処理はすべてメインキューで行う。
final class ProbeClientModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var browserStatus = "探しています…"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var tcpPath = "-"
    @Published private(set) var udpPath = "-"
    @Published private(set) var tcpLatency = LatencyStats()
    @Published private(set) var udpLatency = LatencyStats()
    @Published private(set) var videoSummary = "未受信"
    @Published private(set) var logLines: [String] = []
    @Published var bitrateKbps = 10_000

    private let identity: StaticIdentity
    private var browser: NWBrowser?
    private var stream: StreamConnection?
    private var handshake: SecureHandshake?
    private var channel: SecureChannel?
    private var udp: DatagramConnection?
    private var reassembler: VideoReassembler?
    private var timers: [DispatchSourceTimer] = []

    private var udpSequence: UInt32 = 0
    private var receiveRate = RateCounter()
    private var framesReceived = 0
    private var keyFrameRequests = 0
    private var lastKeyFrameRequest: UInt64 = 0

    init() {
        identity = Self.loadOrCreateIdentity()
    }

    // MARK: - Mac を探す

    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ProtocolInfo.bonjourServiceType, domain: nil),
                                using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.browserStatus = "探しています…"
            case .failed(let error):
                self?.browserStatus = "探せません：\(error)"
            case .waiting(let error):
                self?.browserStatus = "待機中：\(error)（ローカルネットワークの許可を確認してください）"
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.hosts = results.compactMap(ProbeClientModel.makeHost).sorted { $0.name < $1.name }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private static func makeHost(_ result: NWBrowser.Result) -> DiscoveredHost? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        var hostID: String?
        if case let .bonjour(txt) = result.metadata {
            hostID = txt[ProtocolInfo.TXTKey.hostID]
        }
        let interfaces = result.interfaces.map(\.displayDescription).joined(separator: "、")
        return DiscoveredHost(id: "\(result.endpoint)", name: name, hostID: hostID,
                              interfaces: interfaces.isEmpty ? "不明" : interfaces,
                              endpoint: result.endpoint)
    }

    // MARK: - 接続

    func connect(to host: DiscoveredHost) {
        disconnect()
        phase = .connecting(host.name)
        log("\(host.name) に接続します（経路の候補：\(host.interfaces)）")

        let connection = NWConnection(to: host.endpoint, using: NetworkSetup.tcpParameters())
        let stream = StreamConnection(connection: connection)
        var handshake = SecureHandshake(role: .initiator, localStatic: identity)
        stream.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.tcpPath = connection.currentPath?.interfaceDescription ?? "不明"
                let remote = connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? "不明"
                self.log("TCP 接続：\(remote)、経路 \(self.tcpPath)")
            case .waiting(let error):
                self.log("TCP 待機中：\(error)")
            default:
                break
            }
        }
        stream.onData = { [weak self] data in self?.receive(data) }
        stream.onClose = { [weak self, weak stream] error in
            guard let self, let stream, self.stream === stream else { return }
            self.log("TCP が切れました\(error.map { "：\($0)" } ?? "")")
            self.phase = .failed("切断されました")
            self.tearDown()
        }
        self.stream = stream
        stream.start()

        do {
            stream.send(try handshake.start())
            self.handshake = handshake
        } catch {
            fail("ハンドシェイクを開始できません：\(error)")
        }
    }

    func disconnect() {
        if channel != nil {
            send(.disconnect(.normal))
        }
        stream?.cancel()
        tearDown()
        phase = .idle
    }

    private func tearDown() {
        timers.forEach { $0.cancel() }
        timers = []
        udp?.cancel()
        udp = nil
        stream = nil
        handshake = nil
        channel = nil
        reassembler = nil
    }

    /// 擬似映像の送信を（ビットレートを変えて）やり直してもらう。
    func restartStream() {
        guard channel != nil else { return }
        resetStats()
        send(.streamConfig(StreamConfig(maxLongEdge: 2560, framesPerSecond: 60, bitrateKbps: bitrateKbps)))
        log("擬似映像を要求：\(bitrateKbps) kbps")
    }

    // MARK: - 受信

    private func receive(_ data: Data) {
        do {
            if var channel {
                let messages = try channel.receive(data)
                self.channel = channel
                messages.forEach(handle)
                return
            }
            guard var handshake else { return }
            let step = try handshake.receive(data)
            self.handshake = handshake
            stream?.send(step.outgoing)
            if var newChannel = step.channel {
                let messages = try newChannel.receive()
                channel = newChannel
                self.handshake = nil
                log("ハンドシェイク完了（Mac の鍵 \(HostID.make(publicKey: newChannel.remoteStaticPublicKey))）")
                sendHello()
                messages.forEach(handle)
            }
        } catch {
            fail("受信データを処理できません：\(error)")
        }
    }

    private func sendHello() {
        let bounds = UIScreen.main.nativeBounds
        send(.hello(Hello(deviceName: UIDevice.current.name,
                          screenWidth: Int(bounds.width), screenHeight: Int(bounds.height),
                          supportedCodecs: [.hevc, .h264])))
    }

    private func handle(_ message: ControlMessage) {
        switch message {
        case .helloAck(let ack):
            phase = .connected(ack.hostName)
            log("HelloAck：\(ack.hostName)、映像の UDP ポート \(ack.videoPort)")
            startUDP(port: ack.videoPort, videoKey: channel?.videoKey ?? Data())
            startTCPPings()
            restartStream()
        case .pong(let sent):
            let now = monotonicMicros()
            if now >= sent { tcpLatency.add(micros: now - sent) }
        case .disconnect(let reason):
            log("Mac から切断されました：\(reason)")
        default:
            break
        }
    }

    // MARK: - UDP

    private func startUDP(port: UInt16, videoKey: Data) {
        guard let connection = stream?.connection,
              let path = connection.currentPath,
              case let .hostPort(host, _)? = path.remoteEndpoint,
              let udpPort = NWEndpoint.Port(rawValue: port) else {
            log("UDP の宛先が分かりません")
            return
        }
        reassembler = try? VideoReassembler(key: videoKey)

        // TCP と同じ経路（Wi-Fi 直結なら awdl0）に限定して張る。
        let parameters = NetworkSetup.udpParameters(requiredInterface: path.availableInterfaces.first)
        let udpConnection = NWConnection(host: host, port: udpPort, using: parameters)
        let udp = DatagramConnection(connection: udpConnection)
        udp.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.udpPath = udpConnection.currentPath?.interfaceDescription ?? "不明"
                self.log("UDP 準備完了：\(host):\(port)、経路 \(self.udpPath)")
            case .waiting(let error), .failed(let error):
                self.log("UDP の問題：\(error)")
            default:
                break
            }
        }
        udp.onDatagram = { [weak self] datagram in self?.receiveDatagram(datagram) }
        self.udp = udp
        udp.start()

        // UDP の ping は、Mac 側に iPhone の UDP の宛先を知らせる役目もある。
        addTimer(every: .milliseconds(200)) { [weak self] in self?.sendUDPPing() }
        sendUDPPing()
    }

    private func sendUDPPing() {
        udpSequence &+= 1
        udp?.send(ProbeDatagram.ping(sequence: udpSequence, timestampMicros: monotonicMicros()))
    }

    private func receiveDatagram(_ datagram: Data) {
        if let sent = ProbeDatagram.timestamp(ofPong: datagram) {
            let now = monotonicMicros()
            if now >= sent { udpLatency.add(micros: now - sent) }
            return
        }
        guard var reassembler else { return }
        let events = reassembler.ingest(datagram)
        self.reassembler = reassembler

        for event in events {
            switch event {
            case .frame(let frame):
                framesReceived += 1
                if receiveRate.add(bytes: frame.data.count) {
                    updateVideoSummary()
                }
            case .requestKeyFrame:
                // 要求は 250ms に 1 回まで。
                let now = monotonicMicros()
                if now - lastKeyFrameRequest > 250_000 {
                    lastKeyFrameRequest = now
                    keyFrameRequests += 1
                    send(.requestKeyFrame)
                }
            }
        }
    }

    private func updateVideoSummary() {
        videoSummary = String(
            format: "%.0f fps、%.1f Mbps、受信 %ld フレーム、キーフレーム要求 %ld 回、不正パケット %ld",
            receiveRate.perSecond, receiveRate.megabitsPerSecond, framesReceived, keyFrameRequests,
            reassembler?.rejectedPacketCount ?? 0
        )
    }

    // MARK: - TCP の ping

    private func startTCPPings() {
        addTimer(every: .milliseconds(200)) { [weak self] in
            self?.send(.ping(monotonicMicros()))
        }
    }

    // MARK: - 補助

    private func send(_ message: ControlMessage) {
        guard var channel, let stream else { return }
        do {
            stream.send(try channel.seal(message))
            self.channel = channel
        } catch {
            fail("メッセージを暗号化できません：\(error)")
        }
    }

    private func addTimer(every interval: DispatchTimeInterval, _ handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }

    private func resetStats() {
        tcpLatency.reset()
        udpLatency.reset()
        framesReceived = 0
        keyFrameRequests = 0
        receiveRate = RateCounter()
        videoSummary = "受信待ち"
    }

    private func fail(_ message: String) {
        log(message)
        phase = .failed(message)
        stream?.cancel()
        tearDown()
    }

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

    /// 結果をまとめた文章。コピーして共有するため。
    var reportText: String {
        """
        MacRemote 検証結果
        端末：\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)
        状態：\(phaseDescription)
        TCP 経路：\(tcpPath)
        UDP 経路：\(udpPath)
        TCP 往復：\(tcpLatency.summary)
        UDP 往復：\(udpLatency.summary)
        擬似映像（\(bitrateKbps) kbps 要求）：\(videoSummary)
        --- ログ ---
        \(logLines.suffix(30).joined(separator: "\n"))
        """
    }

    var phaseDescription: String {
        switch phase {
        case .idle: return "未接続"
        case .connecting(let name): return "\(name) に接続中"
        case .connected(let name): return "\(name) に接続済み"
        case .failed(let message): return "失敗：\(message)"
        }
    }

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
