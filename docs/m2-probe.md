# M2 検証の手順（Wi-Fi 直結と LAN での通信）

## 目的

検証用アプリを、Mac 用（ProbeHost）と iPhone／iPad 用（ProbeClient）の2つ作りました。
実機で動かして、本番のアプリを作る前に次のことを確かめます。

1. Wi-Fi 直結（AWDL）でも、Mac が見つかって TCP で接続できるか
2. 同じ経路で、映像用の UDP を張れるか（設計書 3.2 の「最初に検証すること」）
3. TCP と UDP の往復の遅延
4. 擬似的な映像（2〜40 Mbps）を流したとき、フレームが欠けずに 60fps で届くか

検証用アプリは、共通部分 `RemoteCore` の Noise ハンドシェイクと映像パケットの処理を、そのまま使っています。
そのため、Apple の CryptoKit で正しく動くかの確認にもなります。

> 検証用アプリは端末登録の確認をしません。同じネットワーク上の端末なら、どれでもつながります。
> 検証が終わったら、Mac 側のアプリは終了してください。

## 準備（初回だけ）

1. Mac に Xcode 16 以降を入れます。
2. XcodeGen を入れます（Homebrew を使います）。

   ```bash
   brew install xcodegen
   ```

3. リポジトリを取得します。

   ```bash
   git clone https://github.com/gj4ghvkr2k-dev/my-mac-iPhone.git
   ```

   ```bash
   cd my-mac-iPhone
   ```

4. 署名の設定ファイルを作ります。

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   - `Config/Local.xcconfig` を開き、`DEVELOPMENT_TEAM` を自分の Team ID に書き換えます。
   - Team ID は、Xcode の Settings → Accounts で、Apple ID を選ぶと表示されます。無料の Apple ID の場合は「Personal Team」の ID です。

5. Xcode のプロジェクトを作り、開きます。

   ```bash
   xcodegen generate
   ```

   ```bash
   open MacRemote.xcodeproj
   ```

6. iPhone の準備をします。
   - iPhone を Mac にケーブルでつなぎます。
   - 設定 → プライバシーとセキュリティ → デベロッパモード をオンにします。iPhone の再起動が必要です。

## 実行

1. **Mac 側**
   - Xcode の上部で、スキームを `ProbeHost`、実行先を「My Mac」にして実行（⌘R）します。
   - ウィンドウに「待ち受け中」と、TCP／UDP のポート番号が出れば準備完了です。
   - 「受信接続を許可しますか？」と聞かれたら「許可」を選びます。

2. **iPhone 側**
   - スキームを `ProbeClient`、実行先を自分の iPhone にして実行します。
   - 「ローカルネットワーク上のデバイスの検出と接続」を求められたら「許可」を選びます。
   - 初回は、iPhone の 設定 → 一般 → VPN とデバイス管理 で、開発元を信頼する必要がある場合があります。

3. iPhone の「見つかった Mac」に表示された Mac をタップすると、計測が始まります。

## 試してほしい2つの場面

それぞれ、ビットレートを 5 Mbps、10 Mbps、20 Mbps に切り替えて、各 30 秒ほど流してください。
終わるたびに「結果をコピー」を押し、その文章をチャットに貼り付けてください。

### A. 同じ Wi-Fi（LAN）
- Mac と iPhone を、いつもの同じ Wi-Fi につないだまま計測します。

### B. Wi-Fi 直結（ルーターなし）
Wi-Fi の電波はオンのまま、Wi-Fi ネットワークへの接続だけを切ります。
- **iPhone**：コントロールセンターの Wi-Fi ボタンをタップします。設定アプリで Wi-Fi をオフにはしないでください。電波ごと止まって、直結もできなくなります。
- **Mac**：メニューバーの Wi-Fi アイコンから、つながっているネットワークの接続を解除します。Wi-Fi 自体はオンのままにします。
- 計測画面の「TCP の経路」と「UDP の経路」に `awdl0（Wi-Fi直結）` と出ていれば、直結で通信できています。

## 結果の見方（目安）

| 項目 | 合格の目安 |
|---|---|
| TCP と UDP の経路 | B では、どちらも `awdl0（Wi-Fi直結）` になっている |
| UDP の往復（中央値） | LAN で 10ms 以下、Wi-Fi 直結で 15ms 以下 |
| UDP の往復（95%） | 30ms 以下 |
| 擬似映像（10 Mbps） | 58 fps 以上で、キーフレームの要求がほとんど出ない |
| 不正パケット | 0（0 以外なら暗号化の不具合） |

うまくいかなかった場合は、画面の下の方のログをコピーして貼り付けてください。
特に次の2つは、映像を TCP で送る方式に切り替えるかを決める材料になります。
- UDP の経路が「不明」のまま
- UDP の往復の回数が増えない
