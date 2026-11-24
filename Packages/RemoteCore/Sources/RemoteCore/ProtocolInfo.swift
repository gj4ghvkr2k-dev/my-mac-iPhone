import Foundation

/// 通信の取り決めに関する定数。
public enum ProtocolInfo {
    /// 通信の取り決め（プロトコル）のバージョン。互換性のない変更をしたら上げる。
    public static let version: UInt16 = 1

    /// Bonjour で公開するサービスの種類。
    public static let bonjourServiceType = "_macremote._tcp"

    /// Noise ハンドシェイクのプロローグ。両端で一致しないとハンドシェイクが失敗する。
    public static let noisePrologue = Data("macremote/\(version)".utf8)

    /// Bonjour の TXT レコードのキー。
    public enum TXTKey {
        public static let version = "v"
        public static let hostID = "id"
    }
}
