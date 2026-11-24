# MacRemote（仮称）

iPhone／iPad から Mac をリモート操作するための、自分と家族用のアプリです。
同じ LAN 内、ルーターなしの直接接続（Wi-Fi 直結・USB）、外出先からのインターネット越し、のどれでも使えるようにすることを目指しています。

## ドキュメント
- [要件定義](docs/requirements.md)
- [第1段階 設計書](docs/design/phase1.md)

## 構成（予定）
| ディレクトリ | 内容 |
|---|---|
| `Packages/RemoteCore` | iPhone アプリと Mac アプリで共有するコード（通信・暗号化・端末登録） |
| `Apps/MacHost` | Mac 側のアプリ（メニューバーに常駐） |
| `Apps/iOSClient` | iPhone／iPad 側のアプリ |
| `Apps/Shared` | 両方のアプリで使う Apple 環境専用のコード（Network.framework の包みなど） |
| `Spikes/` | 検証用アプリ（M2：ProbeHost と ProbeClient） |
| `project.yml` | XcodeGen の設定。`xcodegen generate` で `MacRemote.xcodeproj` を作る |

## 状況
第1段階を進めています。

- [x] M1：共通部分（`RemoteCore`）のメッセージの定義、区切り、Noise による暗号化、端末登録、映像パケットの分割・組み立て
- [ ] M2：AirDrop と同じ仕組みの Wi-Fi 直結（AWDL）で、TCP と UDP を張れるかの検証（検証用アプリは作成済み。[手順](docs/m2-probe.md)）
- [ ] M3：Mac 側アプリ（コードは作成済み。実機での確認待ち）
- [ ] M4：iPhone／iPad 側アプリ（コードは作成済み。実機での確認待ち。[動作確認の手順](docs/phase1-trial.md)）
- [ ] M5：実機での結合テスト

## 共通部分のテスト

Mac では Xcode に入っている Swift で、Linux では Swift 6.1 以上でテストを実行できます。

```bash
swift test --package-path Packages/RemoteCore
```

GitHub に push すると、GitHub Actions でも Linux 上のテストが自動で実行されます。
