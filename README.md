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

## 状況
第1段階の設計中です。
