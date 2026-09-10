# appproxy-appservice-test

Azure App Proxy と App Service を連携させ、インターネット非公開の App Service に
App Proxy 経由で安全にアクセスする構成を検証するための azd テンプレート。

## 構成

- App Service には Private Endpoint を設定し、アプリ本体の公開エンドポイントは
	すべて拒否します。
- App Proxy Connector は VNet 内の Private Endpoint を経由して App Service に
	接続します。
- App Service の SCM/Kudu エンドポイントは、ローカルから `azd up` でデプロイ
	できるよう、管理者が入力した IPv4 CIDR からのみアクセスを許可します。
- Connector VM は固定パブリック IP を持ち、同じ管理者 CIDR からの RDP のみを
	許可します。
- App Service では Easy Auth、Application Proxy では Entra 事前認証を使用します。

## デプロイ

```bash
azd auth login
azd up
```

新しい環境では、Connector VM の RDP と App Service の SCM デプロイを許可する
IPv4 CIDR の入力を求められます。1 台の管理端末だけを許可する場合は、端末の
グローバル IPv4 アドレスに `/32` を付けて入力します。

```text
Enter the IPv4 CIDR allowed for Connector VM RDP and App Service deployment
(example: 203.0.113.10/32):
```

既存環境で接続元を変更する場合は、再プロビジョニング前に値を更新します。

```bash
azd env set CONNECTOR_ALLOWED_RDP_CIDR <your-public-ip>/32
```

デプロイ後、Connector VM 上で Microsoft Entra Private Network Connector を
対話的に登録します。詳細は [docs/step3_appproxy.md](docs/step3_appproxy.md) を参照してください。

`SERVICE_WEB_URI` は App Service の既定ホスト名ですが、アプリ本体には公開ネットワーク
からアクセスできません。VNet 内では Private DNS によって Private Endpoint の
プライベート IP に解決されます。

## ファイル

- [app/](app/) : Flask 製の echo スタブアプリ
- [infra/main.bicep](infra/main.bicep) : サブスクリプションスコープのエントリ
- [infra/modules/appservice.bicep](infra/modules/appservice.bicep) : App Service、Private Endpoint、Private DNS
- [infra/modules/connector-vm.bicep](infra/modules/connector-vm.bicep) : Connector VM、VNet、サブネット、NSG
- [docs/requirements.md](docs/requirements.md) : 要件
- [docs/development_steps.md](docs/development_steps.md) : 開発手順
