import Foundation
import Network

/// Network.framework の設定をまとめたもの。Mac と iPhone の両方で使う。
enum NetworkSetup {
    /// 制御の通信路（TCP）。遅延を減らすため Nagle を切り、切断を早く検出するため keepalive を有効にする。
    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // AirDrop と同じ仕組みの Wi-Fi 直結（AWDL）も使う。
        parameters.includePeerToPeer = true
        return parameters
    }

    /// 映像の通信路（UDP）。
    static func udpParameters(requiredInterface: NWInterface? = nil) -> NWParameters {
        let parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        parameters.includePeerToPeer = true
        if let requiredInterface {
            parameters.requiredInterface = requiredInterface
        }
        return parameters
    }
}

/// TCP の接続を包み、届いたバイト列をそのまま渡す。
///
/// コールバックはすべて `queue` の上で呼ばれる。
final class StreamConnection {
    let connection: NWConnection
    private let queue: DispatchQueue

    var onStateChange: ((NWConnection.State) -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((NWError?) -> Void)?

    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue = .main) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onStateChange?(state)
            switch state {
            case .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onData?(data)
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receiveNext()
            }
        }
    }

    private func finish(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
    }
}

/// UDP の接続を包み、届いたデータグラムを 1 つずつ渡す。
final class DatagramConnection {
    let connection: NWConnection
    private let queue: DispatchQueue

    var onStateChange: ((NWConnection.State) -> Void)?
    var onDatagram: ((Data) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue = .main) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ datagram: Data) {
        connection.send(content: datagram, completion: .idempotent)
    }

    /// 複数のデータグラムをまとめて送る（1 フレーム分のパケットなど）。
    func send(_ datagrams: [Data]) {
        connection.batch {
            for datagram in datagrams {
                connection.send(content: datagram, completion: .idempotent)
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onDatagram?(data)
            }
            if error == nil {
                self.receiveNext()
            }
        }
    }
}

extension NWPath {
    /// 使っている通信経路の説明（例：「awdl0（Wi-Fi直結）」）。
    var interfaceDescription: String {
        guard let interface = availableInterfaces.first else { return "不明" }
        return interface.displayDescription
    }
}

extension NWInterface {
    var displayDescription: String {
        if name.hasPrefix("awdl") || name.hasPrefix("llw") {
            return "\(name)（Wi-Fi直結）"
        }
        switch type {
        case .wifi: return "\(name)（Wi-Fi）"
        case .wiredEthernet: return "\(name)（有線LAN）"
        case .cellular: return "\(name)（モバイル通信）"
        case .loopback: return "\(name)（ループバック）"
        case .other: return "\(name)（その他）"
        @unknown default: return name
        }
    }
}

/// 経過時間の計測用（マイクロ秒）。端末の起動からの時間なので、別の端末とは比べられない。
func monotonicMicros() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1_000
}
