# 第1段階 設計書

対象：LAN 内と Wi-Fi 直結（AWDL）で、Mac の画面を iPhone／iPad から表示・操作し、QR コードで端末を登録するところまで。

## 1. 全体構成

```
┌──────────── iPhone / iPad ────────────┐            ┌─────────────── Mac ───────────────┐
│ iOSClient（SwiftUI）                  │            │ MacHost（メニューバーに常駐）       │
│  ├ QR 読み取り・端末一覧              │            │  ├ 端末登録（QR 表示）・端末一覧    │
│  ├ 映像の復元 → 画面に表示            │  制御 TCP  │  ├ 画面の取り込み（ScreenCaptureKit）│
│  │   VTDecompressionSession           │◀──────────▶│  ├ 映像の圧縮（VideoToolbox）       │
│  │   AVSampleBufferDisplayLayer       │  映像 UDP  │  └ 入力の再現（CGEvent）            │
│  └ ジェスチャー・キーボード → 入力送信│◀───────────│                                     │
│                                       │            │                                     │
│  RemoteCore（両方で共有するコード）   │            │  RemoteCore                         │
└───────────────────────────────────────┘            └─────────────────────────────────────┘
```

- **RemoteCore**（Swift Package）は、通信の取り決め、暗号化、端末登録の処理をまとめます。
  - Apple の UI 関連フレームワークには依存させません。
  - Linux でもユニットテストを動かせるようにします。
- **MacHost** は macOS アプリです。メニューバーだけに表示し（`LSUIElement`）、App Sandbox は使いません。
  - Sandbox を使わないのは、CGEvent で入力を送るためです。
  - そのため Mac App Store では配れず、自分でビルドするか、Developer ID で署名・公証して配ります。
- **iOSClient** は iPhone と iPad の両方で動く、1本のアプリにします。

## 2. リポジトリ構成

```
my-mac-iphone/
├ project.yml              XcodeGen の設定。xcodegen で .xcodeproj を作る
├ Packages/RemoteCore/     共有コード（Swift Package）
│  ├ Sources/RemoteCore/
│  │  ├ Protocol/          メッセージの定義と、送受信のための区切り（フレーミング）
│  │  ├ Crypto/            Noise ハンドシェイク、暗号化
│  │  ├ Pairing/           端末登録（QR の内容と検証）、未登録の端末の締め出し
│  │  ├ Video/             映像パケットの分割・暗号化・組み立て
│  │  └ Transport/         Network.framework の薄い包み（Apple 環境のみ。M3 で追加）
│  └ Tests/RemoteCoreTests/
├ Apps/MacHost/            macOS アプリ
├ Apps/iOSClient/          iOS／iPadOS アプリ
└ docs/
```

`.xcodeproj` はリポジトリに入れず、`project.yml` から生成します。Xcode のプロジェクトファイルは手で編集すると壊れやすく、コミットのたびに差分も大きくなるためです。

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

## 3. 通信

### 3.1 相手の見つけ方

- Mac は `NWListener` で待ち受け、Bonjour のサービス `_macremote._tcp` として公開します。
  - `includePeerToPeer = true` を指定し、AWDL（Wi-Fi 直結）でも見つかるようにします。
- Bonjour の TXT レコードには次の2つを入れます。
  - `v=1`：通信の取り決め（プロトコル）のバージョン
  - `id=<Mac の公開鍵の SHA-256 の先頭8バイトを16進表記したもの>`
- iPhone は `NWBrowser` で探し、登録済みの `id` と一致する Mac だけを一覧に出します。

### 3.2 通信路

| 通信路 | 方式 | 流すもの |
|---|---|---|
| 制御 | TCP（Nagle を無効化し、TCP keepalive を有効にする） | ハンドシェイク、入力、設定、キーフレーム要求、ping |
| 映像 | UDP | 圧縮した映像（HEVC／H.264 の NAL ユニット）。Mac から iPhone への一方向 |

- 映像の UDP 待ち受けポートは、制御の通信路で `Hello` を交わすときに Mac から伝えます。
- 宛先は、制御の通信路の `remoteEndpoint` に入っているホストアドレスを使います。AWDL の場合は、インターフェースが指定された IPv6 リンクローカルアドレスです。
  - **最初に検証すること（spike）**：AWDL 上で UDP を正しく張れるか確認します。張れなかった場合は、映像を制御 TCP と同じ通信路に流す方式に切り替えます。

### 3.3 送受信の区切り（フレーミング）

制御の通信路では、メッセージを次の形で並べて送ります。

```
| 長さ: UInt16 BE | 暗号化したデータ（種類: UInt8 ＋ 本文 ＋ 認証タグ 16 バイト） |
```

- 接続時に一度だけ送るメッセージ（`Hello` など）の本文は、`Codable` の JSON にします。
- 入力イベントのように高い頻度で送るものは、固定長のバイナリにします。例えば `PointerMove` は 10 バイトです。
- 区切った本体の最大長は、Noise の仕様に合わせて 65535 バイトです。暗号化前のメッセージは、認証タグの分を引いた 65519 バイトまでです。
  - 第2段階のファイル転送などで大きなデータを送るときは、この大きさ以下に分けて送ります。
- Noise のハンドシェイクメッセージも、同じ区切りで送ります。

### 3.4 映像の宛先の登録

Mac は、UDP の登録パケットを送ってきた宛先（IP とポート）に映像を送ります（`UDPRegistration`）。

```
| 種類 0x20 | カウンタ UInt64 BE | 映像用の鍵による HMAC-SHA256 の先頭 16 バイト |
```

- iPhone は、`HelloAck` を受け取ったらすぐに送り、その後も 1 秒ごとに送り直します。経路が変わったときや、ルーターの変換表が消えたときの備えです。
- Mac は、鍵が正しく、カウンタが前回より大きいものだけを受け付けます。盗み見たパケットを別の宛先から送り直して、映像の送り先を奪うことはできません。
- 5 秒以内に正しい登録が届かない UDP の相手は、捨てます。

### 3.5 映像パケット

1つのフレームを、1パケット 1200 バイト以下に分けて送ります。

```
| 種類 1B | フレーム番号 UInt32 | 分割番号 UInt16 | 分割数 UInt16 | フラグ 1B（キーフレームか） | 時刻 UInt64(µs) | データ… | 認証タグ 16B |
```

- フレームのデータは「長さ（UInt32 BE）＋ NAL ユニット」の並びです（`VideoBitstream`）。キーフレームの先頭には、パラメータセット（HEVC は VPS・SPS・PPS、H.264 は SPS・PPS）を必ず入れます。
- 画面に変化がない間も、Mac は 0.5 秒に 1 回、最後の画面をもう一度圧縮して送ります。最後のフレームが欠けたとき、iPhone が次のフレームで欠けに気づけるようにするためです。中身はほぼ空なので、データは小さくて済みます。
- 欠けた分割があるフレームは捨てます。そのあとは、次のキーフレームが届くまで表示を止めます。
- フレームが欠けたことに気づいたら、iPhone は制御の通信路で `RequestKeyFrame` を送ります。
- 再送はしません。遅れて届いたデータは使わないためです。

## 4. 暗号化と端末登録

### 4.1 暗号化の方式

**Noise_XX_25519_ChaChaPoly_SHA256** を、アプリ側で実装します。

- 中身は CryptoKit（Linux では swift-crypto）の X25519、ChaChaPoly、SHA-256 を組み合わせるだけなので、実装は 300 行程度です。
- TLS ではなく Noise を選ぶ理由は3つあります。
  - 自己署名の証明書を発行・管理しなくて済みます。
  - LAN、Wi-Fi 直結、USB、中継サーバーのどの通信路でも、同じ仕組みで暗号化できます。
  - 毎回、使い捨ての鍵で通信を暗号化します（前方秘匿性）。
- それぞれの端末は、長く使う鍵（X25519 の固定鍵）を初回起動時に作り、Keychain に保存します。
- 映像の UDP パケットは、映像専用の鍵を使って ChaChaPoly で暗号化します。
  - 映像専用の鍵は、ハンドシェイクの最後の chaining key から HKDF で作ります（salt はハンドシェイクのハッシュ、info は `"macremote video v1"`）。
  - nonce には、フレーム番号と分割番号から作った値を使います。1回の接続の中で、この組み合わせが重複することはありません。
  - パケットのヘッダーは暗号化しませんが、認証の対象に含めるので書き換えはできません。
  - 一度受け取ったパケットや、すでに通り過ぎたフレームのパケットが届いたら（リプレイ）、捨てます。

### 4.2 端末登録の流れ

```
Mac                                              iPhone
 │ メニュー「iPhone を追加」                       │
 │ 1回限りのトークン（16 バイト、有効 5 分）を作る  │
 │ QR を表示：                                     │
 │ macremote://pair?v=1&n=<Mac名>&k=<公開鍵>&t=<トークン>
 │                                                 │ QR を読む（VisionKit DataScanner）
 │                                                 │ Bonjour で id が一致する Mac を探す
 │◀────────── Noise XX ハンドシェイク ────────────▶│
 │                                                 │ Mac の公開鍵が QR と同じか確かめる
 │◀──── Pair { token, deviceName } ────────────────│
 │ トークンを確かめ、iPhone の公開鍵と名前を保存   │
 │──── PairResult { ok } ─────────────────────────▶│ Mac の公開鍵と名前を保存
 │ 通知「◯◯の iPhone を登録しました」               │
```

**2回目以降の接続**
- 毎回 Noise XX でハンドシェイクします。
- iPhone 側は、相手の公開鍵が登録した Mac の鍵と同じか確かめます。
- Mac 側は、相手の公開鍵が登録済みの端末一覧にあるか確かめます。
- どちらかで一致しなければ、その場で接続を切ります。

**登録の取り消し**
- Mac の端末一覧から削除すると、その端末は以降つながらなくなります。

### 4.3 メッセージ一覧（第1段階）

| 方向 | メッセージ | 内容 |
|---|---|---|
| iPhone → Mac | `Hello` | プロトコルのバージョン、画面サイズ、対応している映像の形式（HEVC／H.264） |
| Mac → iPhone | `HelloAck` | 映像の UDP ポート、モニター一覧（id、解像度、倍率） |
| iPhone → Mac | `Pair` / Mac → iPhone `PairResult` | 端末登録 |
| iPhone → Mac | `SelectDisplay` | 表示するモニターを切り替える |
| iPhone → Mac | `StreamConfig` | 目標のビットレート、fps、最大解像度 |
| iPhone → Mac | `RequestKeyFrame` | キーフレームを要求する |
| iPhone → Mac | `PointerMove` | 絶対座標（0〜1 に正規化した値）または相対移動量 |
| iPhone → Mac | `PointerButton` | 左・右・中ボタンの押下／解放 |
| iPhone → Mac | `Scroll` | dx、dy（ピクセル単位）と慣性スクロールの段階 |
| iPhone → Mac | `Key` | macOS の仮想キーコードの押下／解放と修飾キー |
| iPhone → Mac | `Text` | 確定した文字列（Unicode のまま送る） |
| iPhone → Mac | `Action` | Mission Control、デスクトップの切り替えなど、決まった操作 |
| Mac → iPhone | `CursorState` | カーソルの位置と、選んでいるモニター上にあるか。動いたときだけ、最大 30 回／秒送る（拡大表示中に、カーソルを追いかけて表示するため） |
| 双方向 | `Ping` / `Pong` | 往復の遅延を測る。どちらかが 3 秒応答しなければ切断とみなす |

## 5. Mac 側（MacHost）

### 5.1 画面の取り込み
- ScreenCaptureKit の `SCStream` を使います。
- 設定は次のとおりです。
  - `minimumFrameInterval = 1/60`
  - `pixelFormat = 420v`（NV12。そのまま圧縮処理に渡せる形式）
  - `showsCursor = true`。手元でカーソルを描く方式は第4段階で検討します。
- 解像度は、iPhone から指定された最大解像度に縮めます。初期値は長い辺 2560px です。
- 画面に変化がないときは、ScreenCaptureKit が新しいフレームを渡してこないため、映像も送りません。

### 5.2 映像の圧縮
- `VTCompressionSession` を使います。HEVC を優先し、使えないときは H.264 にします。
- 設定は次のとおりです。
  - `RealTime = true`
  - `AllowFrameReordering = false`（B フレームを使わない）
  - 低遅延のビットレート制御（`EnableLowLatencyRateControl`）
- キーフレームは、要求されたとき、または 10 秒ごとに入れます。
- ビットレートは、iPhone から届く `StreamConfig` と、往復の遅延の変化を見て調整します。

### 5.3 入力の再現
- `CGEvent` を `.cghidEventTap` に送ります。
- 座標は、正規化された値から、選んでいるモニターのグローバル座標に変換します。
- スクロールは `scrollWheelEvent2Source`（ピクセル単位）で送ります。
- 文字の入力は `keyboardSetUnicodeString` で、文字列をそのまま入力します。
- Mission Control とデスクトップの切り替えは、⌃↑ と ⌃←→ のキー入力で再現します。macOS の初期設定のショートカットを前提にしています。

### 5.4 接続の受け付け
- ハンドシェイクのあと、`HostConnectionGate` で相手を確かめます。
  - 未登録の端末は、QR コードを表示している間だけ受け付けます。表示していなければ、すぐに切ります。
  - ハンドシェイクと `Hello` が 10 秒以内に終わらない接続は切ります。
- 登録済みの端末が `Hello` を送ってきた時点で、その端末を「接続中」にします。別の端末がつながっていた場合は、そちらに `disconnect(replacedByAnotherDevice)` を送って切ります。
- 切断されたら、押したままのマウスボタンやキーをすべて離します。

### 5.5 必要な許可と初回の案内
- 「画面収録」：`CGPreflightScreenCaptureAccess` で確認し、`CGRequestScreenCaptureAccess` で依頼します。
- 「アクセシビリティ」：`AXIsProcessTrustedWithOptions` で確認します。
- 許可が足りないときは、メニューバーから設定方法を案内する画面を開きます。システム設定の該当ページへ直接移動するボタンも付けます。

## 6. iOS 側（iOSClient）

### 6.1 画面構成
1. **端末一覧**：登録済みの Mac を、オンラインかどうか付きで並べます。「＋」ボタンで QR の読み取りを始めます。
2. **リモート画面**：
   - Mac の映像を全画面で表示します。
   - 画面の端に、折りたためるツールバーを置きます。中身は次のとおりです。
     - キーボードを開く
     - 操作モードの切り替え
     - モニターの切り替え
     - 画質
     - 切断

### 6.2 映像の表示
- `VTDecompressionSession` で映像を元に戻し、`AVSampleBufferDisplayLayer` で表示します。
- 届いたフレームはすぐに表示し（`DisplayImmediately`）、表示待ちの行列は作りません。
- ピンチでの拡大縮小とパン（表示位置の移動）は、表示している画面を手元で変形させるだけです。Mac には何も送りません。

### 6.3 ジェスチャーの判定
- `UIGestureRecognizer` を組み合わせ、要件の表のとおりに割り当てます。
- トラックパッドモードでは、指の速さに応じてカーソルの速さを変えます（加速度カーブ）。この計算は iPhone 側で行い、結果の移動量を送ります。
- 直接タッチモードでは、触った点を正規化した絶対座標として送ります。

### 6.4 キーボード
- 日本語の入力は、iPhone の標準の仕組み（`UITextInput`）で受け取ります。
  - 変換中の文字（未確定の文字）は、iPhone 側にだけ表示します。
  - 確定したら `Text` として送ります。
- 特殊キーのバーは `inputAccessoryView` に置きます。
- 修飾キーは、1回押すと次の1キーだけ有効、2回押すと解除するまで有効、にします。
- iPad の外付けキーボードは `pressesBegan`／`pressesEnded` で受け取り、HID のキーコードを macOS の仮想キーコードに変換して送ります。

### 6.5 必要な Info.plist の設定
- `NSLocalNetworkUsageDescription`
- `NSBonjourServices = ["_macremote._tcp"]`
- `NSCameraUsageDescription`（QR を読むため）

## 7. 開発の手順（マイルストーン）

| # | 内容 | どこで確認するか |
|---|---|---|
| M1 | RemoteCore：メッセージの定義、フレーミング、Noise、端末登録の処理とユニットテスト | Linux（この作業環境）と Mac |
| M2 | 検証（spike）：AWDL 上で TCP と UDP を張れるか、往復の遅延を測る | 実機（Mac と iPhone） |
| M3 | MacHost：メニューバー、許可の案内、待ち受け、QR 表示、画面の取り込みと圧縮、入力の再現 | Mac |
| M4 | iOSClient：端末一覧、QR の読み取り、接続、映像の表示、ジェスチャー、キーボード | 実機 |
| M5 | 結合テスト：遅延を測り（目標 50ms 以下）、安定して動くか確認する | 実機 |

## 8. 識別子

| 対象 | 値 |
|---|---|
| Mac アプリのバンドル ID | `com.mushiotoko.macremote.host` |
| iOS アプリのバンドル ID | `com.mushiotoko.macremote.client` |
| Bonjour のサービス | `_macremote._tcp` |
| QR コードの URL | `macremote://pair?...` |

## 9. 未決事項
- 正式なアプリ名。決まるまで、仮称の `macremote` を使います。
- Apple Developer の Team ID。Xcode で署名するときに設定します。
