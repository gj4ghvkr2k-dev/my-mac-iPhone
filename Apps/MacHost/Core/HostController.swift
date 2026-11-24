import AppKit
import Foundation
import Network
import RemoteCore

/// Mac 側アプリの中心。待ち受け、端末登録、接続の管理、映像の送信、操作の再現をまとめる。
///
/// すべてメインキューで動く。
final class HostController: ObservableObject {
    // MARK: 画面に出す状態

    @Published private(set) var statusText = "準備中"
    @Published private(set) var isListening = false
    @Published private(set) var activeClientName: String?
    @Published private(set) var activePath: String?
    @Published private(set) var streamStats = "-"
    @Published private(set) var trustedPeers: [TrustedPeer] = []
    @Published private(set) var invitation: PairingInvitation?
    @Published private(set) var invitationExpiresAt: Date?
    @Published private(set) var pairingMessage: String?
    @Published private(set) var hasScreenRecording = Permissions.screenRecording
    @Published private(set) var hasAccessibility = Permissions.accessibility
    @Published private(set) var logLines: [String] = []

    let hostName: String
    let identity: StaticIdentity

    // MARK: 内部の状態

    private let trustedStore = TrustedPeerStore()
    private var pairing = PairingAuthority()
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var pending: [ObjectIdentifier: ClientConnection] = [:]
    private var active: ClientConnection?
    private var unverifiedDatagrams: [ObjectIdentifier: DatagramConnection] = [:]
    private let injector = InputInjector(display: DisplayGeometry(originX: 0, originY: 0, width: 1, height: 1))
    private var streamer: VideoStreamer?
    private var displays: [HostDisplay] = []
    private var selectedDisplay: HostDisplay?
    private var streamConfig = StreamConfig()
    private var codec: VideoCodec = .hevc
    private var timers: [DispatchSourceTimer] = []
    private var pairingTimer: DispatchSourceTimer?
    private var lastCursor: CursorState?
    private var warnedAboutAccessibility = false

    init() {
        identity = IdentityStore.loadOrCreate(account: "host.identity")
        hostName = Host.current().localizedName ?? "Mac"
        trustedPeers = trustedStore.list.peers
        // アプリの起動直後に待ち受けを始める。
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    // MARK: - 起動

    func start() {
        guard tcpListener == nil else { return }
        startListeners()
        addTimer(every: .seconds(2)) { [weak self] in self?.refreshPermissions() }
        addTimer(every: .milliseconds(33)) { [weak self] in self?.sendCursorIfMoved() }
    }

    private func startListeners() {
        do {
            let udp = try NWListener(using: NetworkSetup.udpParameters(), on: .any)
            udp.newConnectionHandler = { [weak self] connection in self?.acceptDatagram(connection) }
            udp.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.listenerFailed("UDP", error) }
            }
            udp.start(queue: .main)
            udpListener = udp

            let tcp = try NWListener(using: NetworkSetup.tcpParameters())
            tcp.service = NWListener.Service(
                name: hostName, type: ProtocolInfo.bonjourServiceType, domain: nil,
                txtRecord: NWTXTRecord([
                    ProtocolInfo.TXTKey.version: String(ProtocolInfo.version),
                    ProtocolInfo.TXTKey.hostID: identity.hostID,
                ])
            )
            tcp.newConnectionHandler = { [weak self] connection in self?.acceptControl(connection) }
            tcp.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isListening = true
                    self.statusText = "接続を待っています"
                    self.log("待ち受けを開始しました（ID: \(self.identity.hostID)）")
                case .failed(let error):
                    self.listenerFailed("TCP", error)
                default:
                    break
                }
            }
            tcp.start(queue: .main)
            tcpListener = tcp
        } catch {
            listenerFailed("開始", error)
        }
    }

    private func listenerFailed(_ what: String, _ error: Error) {
        log("待ち受け（\(what)）に失敗しました：\(error)。3 秒後にやり直します")
        isListening = false
        statusText = "待ち受けに失敗しました"
        tcpListener?.cancel()
        udpListener?.cancel()
        tcpListener = nil
        udpListener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startListeners() }
    }

    // MARK: - 端末登録

    func startPairing() {
        let invitation = pairing.createInvitation(hostName: hostName, hostIdentity: identity)
        self.invitation = invitation
        invitationExpiresAt = Date().addingTimeInterval(pairing.lifetime)
        pairingMessage = nil

        pairingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + pairing.lifetime)
        timer.setEventHandler { [weak self] in
            self?.cancelPairing()
            self?.pairingMessage = "QR コードの有効期限が切れました"
        }
        timer.resume()
        pairingTimer = timer
        log("端末登録の QR コードを表示しました")
    }

    func cancelPairing() {
        pairing.cancel()
        pairingTimer?.cancel()
        pairingTimer = nil
        invitation = nil
        invitationExpiresAt = nil
    }

    func removeTrustedPeer(_ peer: TrustedPeer) {
        trustedStore.remove(publicKey: peer.publicKey)
        trustedPeers = trustedStore.list.peers
        log("登録を削除しました：\(peer.name)")
        if let active, active.control.remoteStaticPublicKey == peer.publicKey {
            active.control.close(sending: .disconnect(.notAuthorized))
        }
    }

    func disconnectActiveClient() {
        active?.control.close(sending: .disconnect(.normal))
    }

    // MARK: - 制御の通信路

    private func acceptControl(_ connection: NWConnection) {
        let control = SecureControlConnection(connection: connection, role: .responder, identity: identity)
        let client = ClientConnection(control: control)
        let key = ObjectIdentifier(client)
        pending[key] = client

        control.onReady = { [weak self, weak client] remoteKey in
            guard let self, let client else { return }
            self.handshakeCompleted(client, remoteKey: remoteKey)
        }
        control.onMessage = { [weak self, weak client] message in
            guard let self, let client else { return }
            self.received(message, from: client)
        }
        control.onClose = { [weak self, weak client] reason in
            guard let self, let client else { return }
            self.closed(client, reason: reason)
        }
        control.start()

        // ハンドシェイクと Hello が 10 秒で終わらなければ切る。
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak client] in
            guard let self, let client, self.pending[ObjectIdentifier(client)] != nil, client.hello == nil else { return }
            self.log("接続の手続きが時間内に終わらなかったので切断しました")
            client.control.close()
        }
    }

    private func handshakeCompleted(_ client: ClientConnection, remoteKey: Data) {
        let gate = HostConnectionGate(remoteStaticPublicKey: remoteKey, trustedPeers: trustedStore.list, hostName: hostName)
        client.gate = gate
        switch gate.state {
        case .authorized(let peer):
            log("登録済みの端末がつながりました：\(peer.name)")
        case .awaitingPairing:
            if pairing.hasActiveInvitation {
                log("未登録の端末がつながりました（登録を待っています）")
            } else {
                // QR コードを表示していないときは、未登録の端末をすぐに切る。
                log("未登録の端末からの接続を拒否しました")
                client.control.close(sending: .disconnect(.notAuthorized))
            }
        case .closed:
            client.control.close()
        }
    }

    private func received(_ message: ControlMessage, from client: ClientConnection) {
        guard var gate = client.gate else { return }
        var list = trustedStore.list
        let outcome = gate.handle(message, authority: &pairing, trustedPeers: &list)
        client.gate = gate

        switch outcome {
        case .deliver(let message):
            if client === active {
                handleActive(message, from: client)
            } else if case .hello(let hello) = message {
                activate(client, hello: hello)
            }
        case .reply(let replies, let thenClose):
            if list != trustedStore.list {
                trustedStore.replace(with: list)
                trustedPeers = list.peers
            }
            replies.forEach { client.control.send($0) }
            if thenClose { client.control.close() }
        case .paired(let peer, let reply):
            trustedStore.replace(with: list)
            trustedPeers = list.peers
            client.control.send(reply)
            cancelPairing()
            pairingMessage = "「\(peer.name)」を登録しました"
            log("端末を登録しました：\(peer.name)")
            NSSound(named: "Glass")?.play()
        }
    }

    private func closed(_ client: ClientConnection, reason: String?) {
        pending[ObjectIdentifier(client)] = nil
        if client === active {
            deactivate()
            log("切断されました\(reason.map { "：\($0)" } ?? "")")
        }
    }

    // MARK: - 接続中の端末

    private func activate(_ client: ClientConnection, hello: Hello) {
        guard hello.protocolVersion == ProtocolInfo.version else {
            client.control.close(sending: .disconnect(.protocolMismatch))
            return
        }
        guard let videoKey = client.control.videoKey else { return }

        if let old = active, old !== client {
            log("別の端末がつながったので、前の接続を切ります")
            old.control.close(sending: .disconnect(.replacedByAnotherDevice))
            deactivate()
        }

        client.hello = hello
        client.registration = UDPRegistrationVerifier(videoKey: videoKey)
        active = client

        codec = hello.supportedCodecs.contains(.hevc) ? .hevc : .h264
        displays = DisplayDirectory.current()
        selectedDisplay = displays.first
        if let selectedDisplay { injector.display = selectedDisplay.geometry }

        do {
            let streamer = try VideoStreamer(videoKey: videoKey)
            streamer.onStats = { [weak self] text in self?.streamStats = text }
            streamer.onError = { [weak self] message in self?.log(message) }
            self.streamer = streamer
        } catch {
            log("映像の送信を準備できません：\(error)")
        }

        activeClientName = client.peerName ?? hello.deviceName
        activePath = client.control.currentPath?.interfaceDescription
        statusText = "接続中"
        lastCursor = nil

        client.control.send(.helloAck(HelloAck(
            hostName: hostName,
            videoPort: udpListener?.port?.rawValue ?? 0,
            codec: codec,
            displays: displays.map(\.info),
            activeDisplayID: selectedDisplay?.id ?? 0
        )))
        log("接続しました：\(activeClientName ?? "?")（経路 \(activePath ?? "不明")、\(codec.rawValue)）")

        if !hasScreenRecording {
            log("「画面収録」が許可されていないため、映像を送れません")
        }
    }

    private func deactivate() {
        streamer?.stop()
        streamer = nil
        injector.releaseAll()
        active?.datagram?.cancel()
        active = nil
        activeClientName = nil
        activePath = nil
        streamStats = "-"
        statusText = isListening ? "接続を待っています" : statusText
    }

    private func handleActive(_ message: ControlMessage, from client: ClientConnection) {
        switch message {
        case .streamConfig(let config):
            streamConfig = config
            startStreaming()
        case .selectDisplay(let id):
            displays = DisplayDirectory.current()
            guard let display = displays.first(where: { $0.id == id }) else { return }
            selectedDisplay = display
            injector.display = display.geometry
            startStreaming()
        case .requestKeyFrame:
            streamer?.requestKeyFrame()
        case .ping(let value):
            client.control.send(.pong(value))
        case .disconnect:
            client.control.close()
        case .hello:
            break
        case .pointerMove(let move):
            guard canInject() else { return }
            injector.move(move)
        case .pointerButton(let button):
            guard canInject() else { return }
            injector.button(button)
        case .scroll(let scroll):
            guard canInject() else { return }
            injector.scroll(scroll)
        case .key(let key):
            guard canInject() else { return }
            injector.key(key)
        case .text(let text):
            guard canInject() else { return }
            injector.type(text)
        case .action(let action):
            guard canInject() else { return }
            injector.perform(action)
        default:
            break
        }
    }

    private func startStreaming() {
        guard let streamer, let selectedDisplay else { return }
        streamer.apply(VideoStreamer.Configuration(display: selectedDisplay, codec: codec, stream: streamConfig))
    }

    private func canInject() -> Bool {
        if hasAccessibility { return true }
        if !warnedAboutAccessibility {
            warnedAboutAccessibility = true
            log("「アクセシビリティ」が許可されていないため、操作を再現できません")
        }
        return false
    }

    // MARK: - 映像の通信路（UDP）

    private func acceptDatagram(_ connection: NWConnection) {
        let datagram = DatagramConnection(connection: connection)
        let key = ObjectIdentifier(datagram)
        unverifiedDatagrams[key] = datagram
        datagram.onDatagram = { [weak self, weak datagram] packet in
            guard let self, let datagram else { return }
            self.receivedDatagram(packet, on: datagram)
        }
        datagram.start()

        // 5 秒以内に正しい登録が届かなければ捨てる。
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let datagram = self.unverifiedDatagrams.removeValue(forKey: key) else { return }
            datagram.cancel()
        }
    }

    private func receivedDatagram(_ packet: Data, on datagram: DatagramConnection) {
        guard packet.first == UDPRegistration.packetType,
              let client = active, var verifier = client.registration else { return }
        let accepted = verifier.accept(packet)
        client.registration = verifier
        guard accepted else { return }

        unverifiedDatagrams[ObjectIdentifier(datagram)] = nil
        guard client.datagram !== datagram else { return }

        client.datagram?.cancel()
        client.datagram = datagram
        streamer?.setSender { [weak datagram] packets in datagram?.send(packets) }
        log("映像の送り先：\(datagram.connection.endpoint)")
    }

    // MARK: - カーソル

    private func sendCursorIfMoved() {
        guard let active, let display = selectedDisplay else { return }
        let location = injector.cursorLocation()
        let visible = display.geometry.contains(x: location.x, y: location.y)
        let normalized = display.geometry.normalized(x: location.x, y: location.y)
        let state = CursorState(x: normalized.x, y: normalized.y, isVisible: visible)
        if let last = lastCursor, last.isVisible == state.isVisible,
           abs(last.x - state.x) < 0.0005, abs(last.y - state.y) < 0.0005 {
            return
        }
        lastCursor = state
        active.control.send(.cursorState(state))
    }

    // MARK: - 補助

    private func refreshPermissions() {
        let screen = Permissions.screenRecording
        let accessibility = Permissions.accessibility
        if screen != hasScreenRecording { hasScreenRecording = screen }
        if accessibility != hasAccessibility {
            hasAccessibility = accessibility
            warnedAboutAccessibility = false
        }
    }

    private func addTimer(every interval: DispatchTimeInterval, _ handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }

    func log(_ message: String) {
        let time = Self.timeFormatter.string(from: Date())
        logLines.append("\(time) \(message)")
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// 接続してきた端末 1 台分。
private final class ClientConnection {
    let control: SecureControlConnection
    var gate: HostConnectionGate?
    var hello: Hello?
    var registration: UDPRegistrationVerifier?
    var datagram: DatagramConnection?

    init(control: SecureControlConnection) {
        self.control = control
    }

    var peerName: String? {
        if case .authorized(let peer)? = gate?.state { return peer.name }
        return nil
    }
}
