import Foundation
import Network
import RemoteCore

/// 暗号化された制御の通信路（TCP ＋ Noise）。Mac と iPhone の両方で使う。
///
/// - iPhone（`.initiator`）は `start()` のあと、自分からハンドシェイクを始める。
/// - Mac（`.responder`）は、相手からの最初のメッセージを待つ。
///
/// コールバックはすべてメインキューで呼ばれる。
final class SecureControlConnection {
    let connection: NWConnection
    private let stream: StreamConnection
    private var handshake: SecureHandshake?
    private var channel: SecureChannel?
    private var closed = false

    /// ハンドシェイクが終わった。引数は相手の公開鍵。
    var onReady: ((Data) -> Void)?
    var onMessage: ((ControlMessage) -> Void)?
    /// 切断された。引数は理由の説明（正常な切断なら nil）。
    var onClose: ((String?) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    init(connection: NWConnection, role: NoiseXXHandshake.Role, identity: StaticIdentity) {
        self.connection = connection
        self.stream = StreamConnection(connection: connection)
        self.handshake = SecureHandshake(role: role, localStatic: identity)
    }

    var isReady: Bool { channel != nil }
    var remoteStaticPublicKey: Data? { channel?.remoteStaticPublicKey }
    var videoKey: Data? { channel?.videoKey }

    /// 今使っている経路（例：awdl0、en0）。
    var currentPath: NWPath? { connection.currentPath }

    func start() {
        stream.onStateChange = { [weak self] state in self?.onStateChange?(state) }
        stream.onData = { [weak self] data in self?.receive(data) }
        stream.onClose = { [weak self] error in
            self?.finish(error.map { "\($0)" })
        }
        stream.start()
        do {
            guard var handshake else { return }
            let first = try handshake.start()
            self.handshake = handshake
            stream.send(first)
        } catch {
            fail("ハンドシェイクを開始できません：\(error)")
        }
    }

    func send(_ message: ControlMessage) {
        guard !closed, var channel else { return }
        do {
            stream.send(try channel.seal(message))
            self.channel = channel
        } catch {
            fail("メッセージを暗号化できません：\(error)")
        }
    }

    /// 最後のメッセージを送ってから切断する。
    func close(sending message: ControlMessage? = nil) {
        guard !closed else { return }
        if let message { send(message) }
        // 送信が終わるのを少し待ってから閉じる。呼び出し側がこのオブジェクトを手放しても閉じられるよう、強く持つ。
        let stream = self.stream
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            stream.cancel()
        }
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        do {
            if var channel {
                let messages = try channel.receive(data)
                self.channel = channel
                messages.forEach { onMessage?($0) }
                return
            }
            guard var handshake else { return }
            let step = try handshake.receive(data)
            self.handshake = handshake
            stream.send(step.outgoing)
            if var newChannel = step.channel {
                let pending = try newChannel.receive()
                channel = newChannel
                self.handshake = nil
                onReady?(newChannel.remoteStaticPublicKey)
                pending.forEach { onMessage?($0) }
            }
        } catch {
            fail("受信データを処理できません：\(error)")
        }
    }

    private func fail(_ reason: String) {
        stream.cancel()
        finish(reason)
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        onClose?(reason)
    }
}
