# 実装メモ / トラブルシューティング

このドキュメントは、サンプルアプリの実装で踏んだ落とし穴と、その対処を記録するためのものです。READMEは「使う人」向け、本ファイルは「直す人 / 拡張する人」向けです。

## Storage アカウント (Shared Key 無効) と Functions

### 必要な App Setting (identity-based 接続)

`AzureWebJobsStorage__accountName` だけでは不足する。Function ホスト内部で Blob/Queue/Table のサービス URI を解決できないため、以下を **すべて** 明示する。

```text
AzureWebJobsStorage__accountName     = <storage>
AzureWebJobsStorage__blobServiceUri  = https://<storage>.blob.core.windows.net
AzureWebJobsStorage__queueServiceUri = https://<storage>.queue.core.windows.net
AzureWebJobsStorage__tableServiceUri = https://<storage>.table.core.windows.net
AzureWebJobsStorage__credential      = managedidentity
AzureWebJobsStorage__clientId        = <UAMI client id>
```

`WORK_STORAGE`（キュートリガー用）も同様に `__blobServiceUri` / `__queueServiceUri` を併記する。

### デプロイメントストレージも UAMI 認証

組織ポリシーで Storage の Shared Key が無効な場合、`func azure functionapp publish` のリモートビルドが `Key based authentication is not permitted on this storage account.` で失敗する。

```bash
az functionapp deployment config set -g <RG> -n <FUNCAPP> \
  --deployment-storage-auth-type UserAssignedIdentity \
  --deployment-storage-auth-value <UAMI resource id>
az functionapp config appsettings delete -g <RG> -n <FUNCAPP> \
  --setting-names DEPLOYMENT_STORAGE_CONNECTION_STRING
```

UAMI には事前に `Storage Blob Data Owner` を付与しておく。

## Functions Python v2

### `host.json` に `extensionBundle` が必須

`extensionBundle` セクションが無いと、Storage / Service Bus などのバインディング拡張がロードされず、起動時に `The binding type(s) 'queueTrigger' are not registered` エラーになる。

```json
{
  "version": "2.0",
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  }
}
```

### Queue trigger と Python `QueueClient` のエンコーディング

Functions の Queue extension は既定で **Base64 デコード** を想定する。Python の `azure.storage.queue.QueueClient.send_message()` は **plain text** で送るため、両者が不一致だとメッセージはキューに滞留したまま消費されない (`dequeueCount = 0` のまま)。

```json
"extensions": {
  "queues": {
    "messageEncoding": "none"
  }
}
```

## Speech Batch Transcription (REST API)

### `contentUrls` に渡す URL は SAS 付き

Speech サービスは `contentUrls` を **認証ヘッダ無しで** GET する。Storage Shared Key 無効・パブリックアクセス無効では plain な blob URL は取得できず、`InvalidData: The recordings URI contains invalid data.` を返す。

UAMI で発行した User Delegation SAS を blob URL に付加して渡す。

```python
udk = blob_service_client.get_user_delegation_key(
    key_start_time=now - timedelta(minutes=5),
    key_expiry_time=now + timedelta(hours=6),
)
sas = generate_blob_sas(
    account_name=account, container_name=container, blob_name=blob_name,
    user_delegation_key=udk,
    permission=BlobSasPermissions(read=True),
    start=now - timedelta(minutes=5),
    expiry=now + timedelta(hours=6),
)
signed_url = f"{blob_url}?{sas}"
```

### `channels` と `diarization` の整合

`properties.diarization.enabled = true` を指定する場合、`channels` を省略するとデフォルトで `[0, 1]` (ステレオ) を仮定する。ステレオ MP3 入力で diarization を有効化すると **同じく** `InvalidData: The recordings URI contains invalid data.` を返す（エラーメッセージが SAS の問題と区別つかないので注意）。

```python
"properties": {
    "channels": [0],            # mono 扱いを明示
    "diarization": {"enabled": True, "maxSpeakers": 8},
    ...
}
```

### `timeToLiveHours` の最小値

`properties.timeToLiveHours` は **6 以上** が必要（小さい値は `400 InvalidPayload`）。

### Speech のエラー詳細をユーザーに渡す

Speech ジョブ失敗時、エラー詳細は `properties.error.{code, message}` に格納される。コールバックでユーザーに通知する際にこの内容を含めると、切り分けが楽になる。

## Bot Framework Python (UserAssignedMSI)

`botbuilder-integration-aiohttp` の `ConfigurationServiceClientCredentialFactory` は、設定オブジェクトから **`APP_TYPE` / `APP_ID` / `APP_PASSWORD` / `APP_TENANTID`** を読む。`MicrosoftAppType` などの旧名だけだと `MultiTenant` にフォールバックし、`UserAssignedMSI` 構成でも `Unauthorized. Invalid AppId passed on token` で 401 になる。

```python
class BotConfig:
    APP_TYPE     = "UserAssignedMSI"
    APP_ID       = BOT_APP_ID
    APP_PASSWORD = ""
    APP_TENANTID = TENANT_ID
    # 互換のため旧名も併記
    MicrosoftAppType    = APP_TYPE
    MicrosoftAppId      = APP_ID
    MicrosoftAppPassword= APP_PASSWORD
    MicrosoftAppTenantId= APP_TENANTID
```

## LLM Agent に識別子を扱わせる際の注意

Foundry のルーティング Agent (LLM) は、入力に含まれる UUID やトークンを **正確にコピーしないことがある**。

観測例:
```
入力: b855bb91-2d87-4aa4-9e9b-915c1498ddf9
LLM がツールに渡した値: b855bb91-2d87-4aa4-9e9b-915c9-8ddf9
```

設計指針:

- 状態参照のキーは Agent を経由しないルートで伝達する。
  - 本サンプルでは Teams 会話参照を **`job_id`** で保存する。`job_id` は受付時にサーバ側で生成し、コールバック URL のパスとして Function → BFF に伝達される（LLM を経由しない）。
- ツール引数経由で渡す識別子に依存して状態を引く設計は避ける。
- どうしても Agent 経由で識別子を受け渡す場合、Function ツール側でフォーマットを検証して再生成・正規化する。

## Teams マニフェスト

`manifestVersion: 1.19` (M365 アプリマニフェスト) は Teams のカスタムアプリアップロードで弾かれることがある。`1.17` を使うと社内テストアップロードの互換性が高い。

## App Service Plan の SKU

リージョンによっては Basic VM のクォータが 0 のことがある。`APP_PLAN_SKU` 環境変数で `S1` 等に上書きできる。

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| Speech 失敗: `InvalidData: The recordings URI contains invalid data.` | (a) Storage Shared Key 無効環境で生 blob URL を渡している / (b) ステレオ入力で `diarization.enabled=true` のまま `channels` 未指定 | User Delegation SAS を付加 + `channels=[0]` を明示。UAMI に `Storage Blob Data Owner` 付与済みかと Speech のカスタムサブドメイン設定を確認 |
| BFF のコールバックが 404 / BlobNotFound | 過去バージョンで Foundry Agent が `reply_ref_id` (UUID) を変形 | `job_id` を会話参照のキーにする (本サンプルは対応済) |
| Functions のキューが消費されない (`dequeueCount = 0`) | `extensionBundle` 未定義、または `messageEncoding` が Base64/none で不一致 | `host.json` に `extensionBundle` を追加し `queues.messageEncoding: "none"` を設定 |
| `func azure functionapp publish` が `Key based authentication is not permitted on this storage account.` | 組織ポリシーで Shared Key が無効 | `az functionapp deployment config set --deployment-storage-auth-type UserAssignedIdentity` で UAMI 認証に切替 |
| BFF が `Unauthorized. Invalid AppId passed on token` で 401 | Bot Framework SDK の設定属性名が違う | `BotConfig` に `APP_TYPE` / `APP_ID` / `APP_PASSWORD` / `APP_TENANTID` を公開する |
| Teams カスタムアップロードが「マニフェスト解析エラー」 | `manifestVersion: 1.19` (M365 アプリマニフェスト形式) | `1.17` にダウングレード |
| `az appservice plan create` がクォータ超過で失敗 | リージョンの Basic VM クォータが 0 | `APP_PLAN_SKU=S1` などに切替 |
