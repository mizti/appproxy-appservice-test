# Step 3 — App Proxy のデプロイ

このドキュメントは Step 3 で azd によってデプロイされた App Proxy 関連の構成と、
azd 後に **1 度だけ手動で必要な操作 (Connector 登録)** をまとめたものです。

## azd up で自動化される内容

`azd up` 実行時に以下が一括で構成されます。

1. **Connector VM** (Windows Server 2022 datacenter-azure-edition, TrustedLaunch)
   - VNet `10.10.0.0/16` / Subnet `connectors 10.10.1.0/24`
  - NSG: TCP 3389 を、環境作成時に入力した
    `CONNECTOR_ALLOWED_RDP_CIDR` からのみ許可
   - Standard Public IP (output: `CONNECTOR_PUBLIC_IP`)
   - VM サイズ: `CONNECTOR_VM_SIZE` (デフォルト `Standard_B2ms`)
   - 管理者: `CONNECTOR_ADMIN_USERNAME` / `CONNECTOR_ADMIN_PASSWORD` (azd env)
2. **App Service Private Endpoint**
  - 専用 Subnet `private-endpoints 10.10.2.0/24` に配置
  - Private DNS Zone `privatelink.azurewebsites.net` を VNet にリンク
  - App Service の公開メインサイトはすべて拒否
  - SCM/Kudu は `CONNECTOR_ALLOWED_RDP_CIDR` からのみ許可
3. **Custom Script Extension** — `scripts/install-connector.ps1` をインライン
   (Base64) で実行。次を行います:
   - `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\DisableLoopbackCheck = 1`
   - `AADAppProxyConnectorInstaller.exe` を `/q ACCEPTEULA=1
     REGISTERCONNECTOR="false"` で **登録なしサイレントインストール**
4. **Entra App Proxy 用 Application** (`appproxy-stub-${AZURE_ENV_NAME}`)
   - `preprovision.sh` が Microsoft Graph で作成し、対応する Service Principal
     に `WindowsAzureActiveDirectoryIntegratedApp`,
     `WindowsAzureActiveDirectoryOnPremApp` タグを付与
5. **サインインしているユーザを Application に割り当て**
   `appRoleAssignedTo` で `appRoleId=00000000-0000-0000-0000-000000000000`
   (Default Access) を割り当て

## 手動で必要な 1 ステップ — Connector 登録

App Proxy のテナント全体プロビジョニングは **最初の Connector が登録された瞬間**
に発生します。これは Microsoft Graph で自動化できないため、**1 度だけ** 以下を行います。

```text
1) RDP で Connector VM へ接続
     Host : <CONNECTOR_PUBLIC_IP>
     User : <CONNECTOR_ADMIN_USERNAME>
     Pass : azd env get-values | grep CONNECTOR_ADMIN_PASSWORD

2) 管理者 PowerShell で:

     cd 'C:\Program Files\Microsoft Entra private network connector'
     .\RegisterConnector.ps1 `
         -modulePath 'C:\Program Files\Microsoft Entra private network connector\Modules\' `
         -moduleName 'MicrosoftEntraPrivateNetworkConnectorPSModule' `
         -AuthenticationMode 'Interactive'

   サインインダイアログが開くので、テナントの Application Administrator
   （または Global Administrator）でサインインする。MFA も Interactive モード
   ならそのまま完了できる。

   注意: 旧 App Proxy Connector で使われていた `-AuthenticationMode 'usercredentials'`
   + `-Usercredentials (Get-Credential)` は新しい Entra Private Network Connector
   では受け付けられない（有効値は `Interactive` / `Token` / `Credentials` の3つ、
   かつ `Credentials` は MFA 非対応）。`Interactive` を使うこと。

   注意（IE Enhanced Security Configuration）: Windows Server 2022 のデフォルト
   では IE ESC が有効で、Interactive ログインのブラウザに「このコンテンツは
   ブロックされています」等の警告が出ることがある。その場合、警告ダイアログで
   表示された URL（例: `https://login.microsoftonline.com`、
   `https://login.live.com`、`https://aadcdn.msftauth.net` など）を
   Internet Explorer の *インターネット オプション → セキュリティ → 信頼済み
   サイト → サイト* に追加して再度実行する。または Server Manager →
   Local Server から *IE Enhanced Security Configuration* を Administrators
   側だけ Off にしてもよい（検証用 VM なので可）。
```

登録に成功すると `Microsoft Entra Private Network Connector` Windows サービスが
起動し、Entra ポータルの
*Applications → Enterprise applications → Application proxy → Connectors* に
表示されます。

## 仕上げ — `azd hooks run postprovision` を再実行

Connector 登録の直後にもう一度 `postprovision` を流してください。
これで App Proxy が以下を完了します。

- `applications/<id>/onPremisesPublishing` を PATCH
  - `internalUrl` = `${SERVICE_WEB_URI}/`
  - `externalUrl` = `https://appproxy-stub-${AZURE_ENV_NAME}-<tenantPrefix>.msappproxy.net/`
    （`<tenantPrefix>` は `<tenant>.onmicrosoft.com` の `<tenant>` 部分。
     App Proxy の external URL は必ずテナント初期ドメイン名サフィックスで
     終わる必要がある）
  - `externalAuthenticationType = aadPreAuthentication`
  - `isTranslateHostHeaderEnabled = true`
- 確定した `externalUrl` を `APP_PROXY_EXTERNAL_URL` として azd env に保存
- 現在のサインインユーザーに、ギャラリーアプリの `User` ロール
  （default access GUID は使用できない）をアサイン
- `externalUrl` を Entra アプリの `web.redirectUris` (reply URL) に登録
  （未登録だと App Proxy pre-auth のリダイレクトで `AADSTS500113:
  No reply address is registered for the application.` が発生する）

注意: App Proxy アプリは **必ず「On-premises application」ギャラリー
テンプレート (`applicationTemplates/8adf8e6e-67b2-4cf2-a259-e3dc5476c621/instantiate`)
経由で作成すること**。素の `POST /applications` で作ったアプリは
`onPremisesPublishing` リソースが有効化されず、PATCH が
`Application_NotFound` で失敗する。

```bash
azd hooks run postprovision
```

完了すると 2 段認証 (App Proxy pre-auth + Easy Auth) の経路でアクセスできます。

```text
ユーザ
  │ HTTPS
  ▼
https://appproxy-stub-<env>.msappproxy.net   ←─ App Proxy 前段 (Entra pre-auth)
  │ (アサインされたユーザのみ通過)
  ▼
Connector (VM, 10.10.1.x) ── アウトバウンド 443 ──▶
                                      https://app-XXXX.azurewebsites.net
                                      │ Private DNS で 10.10.2.x に解決
                                      ▼
                                      Private Endpoint
                                      └─ Easy Auth (二段目)
```

## トラブルシューティング

- `OnPremisesPublishing_NotEnabled` / `Application '...' not found or
  OnPremisesPublishing is not enabled for your tenant.`
  → Connector 未登録です。手動登録ステップを完了して再度
  `azd hooks run postprovision` を実行してください。
- CSE が `install-appproxy-connector` で失敗する
  → VM の `C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\`
  以下のログを参照。
- Connector が `RegisterConnector.ps1` で失敗
  → サインインアカウントが Application Administrator か Cloud Application
  Administrator ロールを保持していることを確認。
- Connector VM から App Service に接続できない
  → VM 上で `Resolve-DnsName <app-name>.azurewebsites.net` を実行し、
  `privatelink.azurewebsites.net` を経由して `10.10.2.0/24` のアドレスへ解決される
  ことを確認。

---

## カスタムドメインモード (Option B-1, host-name-preservation)

既定モードでは `*.msappproxy.net` 経由のため Easy Auth の OAuth redirect_uri が
App Service 直URL (`app-XXXX.azurewebsites.net`) で組み立てられ、サインイン後の
ブラウザが App Service 直URL に張り付いて App Proxy をバイパスしてしまう
（[詳細はこのドキュメント末尾の調査結果](#easy-auth--app-proxy-の共存に関する制約) 参照）。

これを解決するのが「**App Service と App Proxy に同一の FQDN を割り当て、
DNS で App Proxy を指す**」host-name-preservation パターン (Microsoft 公式)。
Private Endpoint による閉域化とも整合します。

### アーキテクチャ

```
ブラウザ
   │ https://app.mizugokoro.net/
   ▼   ← DNS CNAME が App Proxy フロントエンドを指す
App Proxy (TLS 終端 = mizugokoro.net 用 PFX)
   │ (pre-auth: Entra)
   ▼
Connector ── HTTPS ──▶ https://app-XXXX.azurewebsites.net/
                       └ Private DNS → Private Endpoint (10.10.2.x)
                       └ Host: app.mizugokoro.net (preserved)
                       └ TLS SNI: *.azurewebsites.net (default cert)
                       └ Easy Auth が Host=app.mizugokoro.net を見て
                          redirect_uri を生成 → ブラウザは App Proxy に留まる
```

ポイント:
- App Proxy 設定 `isTranslateHostHeaderEnabled=false` で Host 書き換えを抑止
- App Service には FQDN を **ホスト名バインドのみ** 登録（SSL バインドは不要 ―
  Connector は `*.azurewebsites.net` の既定証明書で TLS を張るため）
- TLS 証明書は **App Proxy 側 1 枚だけ** で済む

### 必要な手動手順 (このリポジトリ前提)

`CUSTOM_DOMAIN` を azd env に設定すると postprovision.sh が以下を判定して
適切に分岐します。

```bash
azd env set CUSTOM_DOMAIN app.mizugokoro.net
```

その後、以下を一度ずつ手動で実施します。`postprovision` を再実行すると
未完の手順を案内するバナーが出ます。

#### 1. App Service の所有権確認用 DNS レコード

App Service のカスタムドメイン登録には所有権の証明が必要。`asuid.<FQDN>` の
TXT レコードを使うと、メインの CNAME を App Proxy に向けたままで検証できる。

検証 ID を取得:

```bash
az webapp show -g <rg> -n <appServiceName> \
    --query customDomainVerificationId -o tsv
```

さくらのドメイン > DNS 設定で以下を追加:

```text
Type : TXT
Name : asuid.app
Data : <上のコマンドで取得した GUID>
TTL  : 3600
```

#### 2. App Service にホスト名をバインド (SSL なし)

```bash
az webapp config hostname add \
    -g <rg> --webapp-name <appServiceName> \
    --hostname app.mizugokoro.net
```

エラーが出る場合は TXT の伝播待ち（数分〜最大 48 時間）。`dig +short TXT
asuid.app.mizugokoro.net` で確認。

#### 3. TLS PFX を入手 (App Proxy 用)

App Proxy はカスタムドメインに対して **PFX 形式の証明書アップロードが必須**。
App Service Managed Certificate (無料) はエクスポート不可なので流用できない。

**選択肢 A — App Service Certificate (Azure 課金, ~$70/年, 推奨)**

Azure ポータル → サブスクリプション → 「App Service Certificates」→ Create
で `app.mizugokoro.net` の証明書を発注。Key Vault に格納される。
ドメイン検証は Azure ポータル上の指示に従い TXT を一時的に追加。
発行後、Key Vault からエクスポート可能。

**選択肢 B — Let's Encrypt (無料, BYO)**

```bash
# 開発マシン上で
sudo certbot certonly --manual --preferred-challenges dns-01 \
    -d app.mizugokoro.net

# プロンプトに従って DNS-01 用の TXT レコードを追加 → 検証成功 → 証明書取得

# PFX に変換
sudo openssl pkcs12 -export \
    -out app.mizugokoro.net.pfx \
    -inkey /etc/letsencrypt/live/app.mizugokoro.net/privkey.pem \
    -in /etc/letsencrypt/live/app.mizugokoro.net/fullchain.pem
# -> PFX パスフレーズを設定 (アップロード時に必要)
```

90 日で失効するので Azure 寄せにしたい場合は A を推奨。

#### 4. App Proxy にカスタムドメイン+証明書を設定 (Entra ポータル)

Entra ポータル → Applications → Enterprise applications →
`appproxy-stub-<env>` → Application proxy:

| 設定 | 値 |
|---|---|
| Internal URL | `https://app-XXXX.azurewebsites.net/` (現状の値のまま) |
| External URL | `https://app.mizugokoro.net/` |
| Pre Authentication | Microsoft Entra ID |
| Translate URLs in headers | **No** ← 重要 |
| Translate URLs in application body | No |
| Certificate | アップロード → 3 で作成した PFX を選択、パスフレーズ入力 |

「Save」をクリック。証明書アップロードはポータルから行うのが最も簡単（Graph API
経由は base64+特殊フォーマット必要で煩雑）。

#### 5. DNS CNAME を App Proxy に向ける

Step 4 を Save した直後、App Proxy が割り当てたフロントエンドの CNAME ターゲット
は External URL を編集する画面に表示されている。形式は通常:

```text
<外部ホスト名>.msappproxy.net
```

さくらのドメイン > DNS 設定で:

```text
Type : CNAME
Name : app
Data : app.mizugokoro.net.<...>.msappproxy.net.
TTL  : 3600
```

`dig +short CNAME app.mizugokoro.net` で App Proxy 側を指していることを確認。

#### 6. postprovision を再実行 (Entra アプリの reply URL 更新等)

```bash
azd hooks run postprovision
```

これで以下が完了:
- Easy Auth Entra アプリの reply URL に
  `https://app.mizugokoro.net/.auth/login/aad/callback` を追加登録
- App Proxy `onPremisesPublishing` の internalUrl 更新
- `APP_PROXY_EXTERNAL_URL` 環境変数を `https://app.mizugokoro.net/` に更新

### 動作確認

```bash
curl -sI https://app.mizugokoro.net/
# → 302 to login.microsoftonline.com (App Proxy pre-auth)
```

ブラウザで `https://app.mizugokoro.net/` にアクセス →
Entra サインイン後、URL が `app.mizugokoro.net` のまま留まれば成功。

---

## Easy Auth + App Proxy の共存に関する制約

(調査記録) — `*.msappproxy.net` 既定モードで Easy Auth を有効にすると、サインイン後に
ブラウザが App Service 直URL に遷移してしまう問題がある。

**原因**: Easy Auth は受信した Host ヘッダから OAuth `redirect_uri` を組み立てる。
App Proxy は Host を内部URL (`app-XXXX.azurewebsites.net`) に書き換えるため、
redirect_uri が直URL になる → サインイン後ブラウザはそこへ遷移 → クッキーも
direct URL に紐づく → 以降のリクエストが App Proxy をバイパス。

**App Proxy が back-end に送るヘッダの実測値** (/healthz エコー検証):
- `X-Forwarded-For`, `X-Ms-Proxy: AzureAD-Application-Proxy`,
  `Client-Ip: <Connector>:port`
- 外部ホスト名を示すヘッダ (`X-Forwarded-Host`, `X-Original-Host`, etc.) は **無し**

このため App Service 側で `forwardProxy.convention=Standard|Custom` を設定しても
参照するヘッダが存在せず無効。`allowedExternalRedirectUrls` は post-login/logout の
ホワイトリストであり redirect_uri 生成には関与しない。

**解決策**: 上記カスタムドメインモード (host-name-preservation) のみ。
Microsoft 公式の [host name preservation ガイドライン](https://learn.microsoft.com/azure/architecture/best-practices/host-name-preservation) に準拠。
