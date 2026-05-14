# このリポジトリの目的

- このリポジトリはAzureにおいてApp ProxyとApp Serviceを連携させ、インターネットからのアクセスを遮断したApp Serviceに対してApp Proxy経由で安全にアクセスできる構成を検証・実証するためのものである
- 本リポジトリはAzure Developer CLI形式で構成されており、``azd up``コマンドによってすべての構成を完了させることが可能である
- また、App ServiceのEasy AuthとApp Proxyでの二重認証が正しく働くことの確認も行う