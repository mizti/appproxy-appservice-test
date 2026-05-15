# App Proxy と Easy Auth を併用するための条件

## 概要

Microsoft Entra Application Proxy (旧 Azure AD App Proxy) の前段認証 (pre-auth) を有効にしたまま、App Service の Easy Auth も併用する構成を成立させるには、**カスタム ドメインを用いて入口から出口まで同じホスト名で通す** 必要がある。

既定の `xxx.msappproxy.net` + `yyy.azurewebsites.net` の組み合わせでは、認証後のリダイレクトで App Service の URL (`yyy.azurewebsites.net`) に遷移してしまい、ユーザー体験・直接アクセス制御の両面で構成が破綻する。

以下、カスタム ドメインの例として `web.mizugokoro.net` を用いる。

---

## 必須条件 1 — 入口と出口で同じ FQDN を使う

### 設定の概要
App Proxy の External URL と App Service に登録するカスタム ホスト名を **同一の FQDN** にする。DNS の CNAME も同じ FQDN で App Proxy へ向ける。

### 理由
End-to-end で同一 FQDN を使わないと、ブラウザに表示される URL・Cookie のスコープ・Easy Auth が発行する `redirect_uri` がそれぞれ別ホストになり、認証ループや Cookie 無効化が発生する。

### 設定方法

1. **DNS に所有権確認用 TXT レコードを登録**
   App Service に提示させる検証トークンを取得し、DNS に `asuid.<host>` の TXT レコードとして登録する。
   ```bash
   # App Service のカスタム ドメイン検証 ID を取得
   az webapp show -g <rg> -n <app> --query "customDomainVerificationId" -o tsv
   ```
   取得した値を DNS に登録する (例: Route 53 / Cloud DNS / お名前.com 等)。
   ```
   asuid.web.mizugokoro.net.  TXT  "<customDomainVerificationId の値>"
   ```
   反映確認:
   ```bash
   dig +short TXT asuid.web.mizugokoro.net
   ```
2. **App Service にカスタム ドメインを登録**
   ```bash
   az webapp config hostname add -g <rg> --webapp-name <app> --hostname web.mizugokoro.net
   ```
3. **App Proxy の External URL を `https://web.mizugokoro.net/` に設定** (必須条件 5 の PFX アップロード手順内で実施)
4. **DNS に CNAME レコードを作成**
   ```
   web.mizugokoro.net.  CNAME  <tenantPrefix>-<tenantInitial>.msappproxy.net.
   ```
   `<tenantPrefix>-<tenantInitial>.msappproxy.net` の値は App Proxy アプリの External URL 設定画面に表示される。

### 確認方法
```bash
dig +short web.mizugokoro.net          # → *.msappproxy.net が返ること
az webapp config hostname list -g <rg> --webapp-name <app> -o table
```

---

## 必須条件 2 — App Proxy に Host ヘッダーを書き換えさせない

### 設定の概要
App Proxy の **「ヘッダー内の URL を変換する」** (Translate URLs in Headers) をオフにする。

### 理由
既定では App Proxy はバックエンドへのリクエストの `Host` ヘッダーを内部 URL (`*.azurewebsites.net`) に書き換える。この状態だと Easy Auth がリクエストの Host を見て `redirect_uri` を `*.azurewebsites.net` 宛で生成してしまい、ユーザーが App Proxy 経由から外れる。

### 設定方法 (ポータル)
1. [Entra 管理センター](https://entra.microsoft.com) → **ID** → **アプリケーション** → **エンタープライズ アプリケーション** → 該当アプリを開く
2. 左メニュー → **「アプリケーション プロキシ」**
3. 「詳細」セクションの **「ヘッダー内の URL を変換する」** のチェックを外して **「保存」**

### 設定方法 (Graph API)
```bash
az rest --method patch \
  --uri "https://graph.microsoft.com/beta/applications/<appObjectId>" \
  --headers "Content-Type=application/json" \
  --body '{"onPremisesPublishing":{"isTranslateHostHeaderEnabled":false,"isTranslateLinksInBodyEnabled":false}}'
```

### 確認方法
```bash
az rest --method get \
  --uri "https://graph.microsoft.com/beta/applications/<appObjectId>?\$select=onPremisesPublishing" \
  --headers "ConsistencyLevel=eventual" \
  --query "onPremisesPublishing.isTranslateHostHeaderEnabled"
# → false が返れば OK
```
`ConsistencyLevel: eventual` ヘッダーが無いと `onPremisesPublishing` が空で返るため必須。

---

## 必須条件 3 — App Service の Easy Auth に転送ヘッダーを尊重させる

### 設定の概要
Easy Auth の `httpSettings.forwardProxy.convention` を `Standard` に設定する。

### 理由
App Proxy は `X-Forwarded-Host` / `X-Forwarded-Proto` を付与して転送するが、Easy Auth は既定でこれらを無視し、TCP レイヤのホスト名 (= App Service の内部 FQDN) を基に `redirect_uri` を組み立てる。`Standard` に設定すると転送ヘッダーを信頼し、カスタム FQDN で `redirect_uri` が発行される。

### 設定方法 (Bicep の `authsettingsV2`)
```bicep
resource auth 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: site
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true }
    httpSettings: {
      requireHttps: true
      forwardProxy: {
        convention: 'Standard'
      }
    }
    // ...
  }
}
```

### 設定方法 (CLI)
ポータル UI には `forwardProxy.convention` を切り替える項目が存在しないため、事後的に行う場合にはCLIで設定する。
```bash
RG=<rg>; APP=<app>
az webapp auth show -g $RG -n $APP -o json \
  | jq '.httpSettings.forwardProxy = {"convention":"Standard"}' > /tmp/auth.json
az webapp auth set -g $RG -n $APP --body @/tmp/auth.json
```

### 確認方法
```bash
az webapp auth show -g <rg> -n <app> --query "httpSettings.forwardProxy"
# → { "convention": "Standard", ... }
```

---

## 必須条件 4 — Easy Auth 用 Entra アプリに reply URL を追加

### 設定の概要
Easy Auth が使用する Entra アプリの **リダイレクト URI** に `https://web.mizugokoro.net/.auth/login/aad/callback` を追加する。

### 理由
Easy Auth は `<custom-fqdn>/.auth/login/aad/callback` を `redirect_uri` として Entra へ送る。この URI がアプリ登録の `web.redirectUris` に登録されていないと、Entra 側で `AADSTS50011: The redirect URI specified in the request does not match` エラーとなる

### 設定方法 (ポータル)
1. Entra 管理センター → **アプリケーション** → **アプリの登録** → 該当アプリ
2. 左メニュー「管理」 → **「認証」（Authentication）**
3. 「プラットフォーム構成」の **「Web」** タイル → **「URI の追加」** → `https://web.mizugokoro.net/.auth/login/aad/callback` を入力
4. **「保存」**

### 設定方法 (CLI)

```bash
az ad app update --id <easyAuthAppId> \
  --web-redirect-uris \
    "https://<app>.azurewebsites.net/.auth/login/aad/callback" \
    "https://web.mizugokoro.net/.auth/login/aad/callback"
```
このコマンドは追加ではなく置換であるため既存 URI も併記する必要がある点に注意

### 確認方法
```bash
az ad app show --id <easyAuthAppId> --query "web.redirectUris" -o json
```

---

## 必須条件 5 — App Proxy 用の TLS 証明書 (PFX) を用意

### 設定の概要
カスタムドメイン用の **エクスポート可能な PFX (秘密鍵付き)** を作成し、App Proxy にアップロードする。

### 理由
App Proxy はカスタム ドメイン公開時に TLS 終端用のPFX形式証明書を要求する。App Service が自動発行する「App Service Managed Certificate」は秘密鍵のエクスポートが不可で App Proxy には流用できないため、別途取得する必要がある。
(App Service CertificateやLet's Encryptなどから)

### 設定方法 (証明書取得の例)

- **App Service Certificate** (Azure 発行、有償・自動更新)
  Azure ポータル → サブスクリプション → **App Service 証明書** で発行し、Key Vault に保管 → PFX をエクスポート。
- **Let's Encrypt 等の外部 CA** (無料、自前更新)
  ```bash
  sudo certbot certonly --manual --preferred-challenges dns-01 -d web.mizugokoro.net
  sudo openssl pkcs12 -export \
    -in    /etc/letsencrypt/live/web.mizugokoro.net/fullchain.pem \
    -inkey /etc/letsencrypt/live/web.mizugokoro.net/privkey.pem \
    -out   ~/web.mizugokoro.net.pfx
  ```

### 設定方法 (App Proxy へのアップロード)

1. カスタムドメインをテナントに登録する。Entra管理センターの「ドメイン名」＞カスタムドメイン名から「カスタムドメインの追加」を行い、TXTレコードをDNS設定等してVerifyを行う

2. Entra 管理センター → エンタープライズ アプリケーション → App Proxyのアプリ → *アプリケーション プロキシ」を開く。外部URLのドメイン プルダウンから検証済みカスタム ドメイン (例: `mizugokoro.net`) を選択し、ホスト名部分に `web` を入力して `https://web.mizugokoro.net/` にする
3. 「証明書」セクションで PFX をアップロードし、エクスポート パスワードを入力 → **「保存」**

バックエンド側 (App Service) は既定の `*.azurewebsites.net` 証明書のままで問題ない (Connector は SNI = `*.azurewebsites.net` で TLS を確立するため)。

### 確認方法
ブラウザで `https://web.mizugokoro.net/` にアクセスし、証明書ビューアでアップロードした証明書 (Subject / Issuer / 有効期限) が提示されることを確認する。

---


## 動作確認チェックリスト

| 項目 | 期待値 | 確認方法 |
|---|---|---|
| ログイン後の URL バー | `https://web.mizugokoro.net/` | ブラウザ |
| バックエンドが見る `Host` ヘッダ | `web.mizugokoro.net` | アプリでリクエスト ヘッダをエコー |
| バックエンドが見る `Disguised-Host` ヘッダ | `web.mizugokoro.net` | 同上 |
| `X-MS-Proxy` ヘッダ | `AzureAD-Application-Proxy` | 同上 |
| `X-MS-Client-Principal-Name` ヘッダ | サインインしたユーザーの UPN | 同上 |
| `*.azurewebsites.net` への直接アクセス | **HTTP 403** | `curl -I https://<app>.azurewebsites.net/` |
