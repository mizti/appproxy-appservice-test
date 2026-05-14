# appproxy-appservice-test

Azure App Proxy と App Service を連携させ、インターネット非公開の App Service に
App Proxy 経由で安全にアクセスする構成を検証するための azd テンプレート。

## 現在のステップ

Step 1: パブリックな App Service に Python 製のスタブアプリ（リクエストの
メソッド・ヘッダ・ボディをそのままレスポンスする echo アプリ）をデプロイする。

## デプロイ

```bash
azd auth login
azd up
```

デプロイ後、`SERVICE_WEB_URI` で表示される URL にアクセスするとリクエスト内容が
そのまま返却される。

## 構成

- [app/](app/) : Flask 製の echo スタブアプリ
- [infra/main.bicep](infra/main.bicep) : サブスクリプションスコープのエントリ
- [infra/modules/appservice.bicep](infra/modules/appservice.bicep) : App Service Plan + App Service (Linux / Python 3.11)
- [docs/requirements.md](docs/requirements.md) : 要件
- [docs/development_steps.md](docs/development_steps.md) : 開発手順
