import Foundation

public enum RemoteCoreError: Error, Equatable, Sendable {
    // 暗号化
    case invalidKey
    case decryptionFailed
    case nonceExhausted
    case handshakeOutOfOrder
    case handshakeMessageMalformed
    case handshakeNotComplete

    // 通信の区切り・メッセージ
    case frameTooLarge(Int)
    case truncatedData
    case trailingData
    case unknownMessageType(UInt8)
    case invalidValue(String)

    // 端末登録
    case invalidInvitation(String)
    case pairingTokenInvalid
    case pairingTokenExpired

    // 映像
    case videoPacketMalformed
    case frameNumberExhausted
}
