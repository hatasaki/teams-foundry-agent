# Teams + App Service BFF + Functions ツール/Worker + BFF 内部コールバック構成

このサンプルは、Microsoft Teams から音声/動画/テキストファイルを受け取り、Azure AI Speech によるバッチ文字起こしと Microsoft Foundry Agent による後処理（議事録化・要約・翻訳など）を行ったうえで、Teams にプロアクティブに結果を返すアプリです。Teams / Bot Framework まわりは BFF が一手に担当し、長時間処理は Functions のキュー Worker が非同期で実行します。

## アーキテクチャ

```text
Teams
  → Azure Bot Service
  → App Service BFF /api/messages
  → Foundry ルーティング Agent (teams-work-router-agent)
  → Azure Functions /api/tools/create_work_item
  → Storage Queue work-items
  → Azure Functions queue worker
       ├── Azure AI Speech (Batch Transcription)
       └── Foundry 後処理 Agent (teams-postprocess-agent)
  → App Service BFF /internal/jobs/{jobId}/complete
  → Teams プロアクティブメッセージ
```

## 設計方針

- BFF が Teams / Bot Framework まわりを単独で担当する。
- Functions が長時間処理（Speech Batch / 後処理 Agent）を担当する。
- Foundry Agent のツールエンドポイントは Functions 上にホストする。
- Functions から Teams に直接メッセージを送らない（必ず BFF 経由）。
- BFF の内部コールバックは Microsoft Entra の JWT 検証で保護する。
- App Service Easy Auth は使わず、アプリ層でトークン検証する。

## Foundry Agent の役割

| Agent | 名前（既定） | 役割 | ツール |
|---|---|---|---|
| ルーティング Agent | `teams-work-router-agent` | Teams の指示を解釈し、`task_type` を決定して `create_work_item` を 1 回だけ呼ぶ | OpenAPI ツール (`create_work_item`) |
| 後処理 Agent | `teams-postprocess-agent` | トランスクリプトやテキストを `task_type` に応じて議事録化・要約・翻訳・整形する | なし |

`task_type` の値:

| 値 | 後処理 |
|---|---|
| `transcribe_only` | 後処理 Agent をスキップし、トランスクリプトをそのまま返す |
| `transcribe_and_report` | 後処理 Agent が議事録（要点 / 決定事項 / TODO / 懸念点）を生成 |
| `summarize` | 後処理 Agent が要約を生成 |
| `translate` | 後処理 Agent が翻訳を生成 |
| `mixed` | 後処理 Agent が指示文を解釈して応答 |

## ディレクトリ構成

- `bff_app_service/` — App Service 上の FastAPI。Teams メッセージ受信、添付ファイル保存、ルーティング Agent 呼び出し、内部コールバック処理、Teams プロアクティブ送信。
- `function_app/` — Functions Python v2。`/api/tools/create_work_item` ツールエンドポイントとキュー Worker をホスト。Speech Batch 起動・状態確認・後処理 Agent 呼び出し・BFF コールバックを実施。
- `agent/` — Foundry に Agent（ルーティング / 後処理）を作成/更新する Python スクリプト。
- `teams/` — Teams マニフェストテンプレートとパッケージ生成スクリプト。
- `infra/` — Azure リソース一括デプロイスクリプト。

## 全体ウォークスルー

以下の順番で進めれば、社内テスト環境に Teams 接続まで一気通貫で構築できます。

| ステップ | 内容 |
|---|---|
| 1 | 事前リソースを準備する |
| 2 | 実行環境とツールを揃える |
| 3 | 必要な権限を確認する |
| 4 | 環境変数を設定する |
| 5 | デプロイスクリプトを実行する |
| 6 | デプロイ出力値を控える |
| 7 | アイコンと正規 URL を準備する |
| 8 | Teams マニフェスト ZIP を生成する |
| 9 | Teams にアップロードする |
| 10 | 動作確認する |

---

## 1. 事前リソースの準備

次のリソースは事前にテナント上で作成しておく必要があります。

| リソース | 必要な状態 | 取得しておく値 |
|---|---|---|
| Microsoft Foundry プロジェクト | 作成済み | プロジェクトエンドポイント URL |
| Foundry モデルデプロイメント | 作成済み | デプロイメント名（例: `gpt-4.1-mini`） |
| Azure AI Speech リソース | カスタムサブドメイン有効 | リソースグループ名 / アカウント名 |

> Speech リソースのカスタムサブドメインが未設定だと Entra 認証が利用できず、デプロイスクリプトが途中で失敗します。

## 2. 実行環境とツール

`infra/` には Bash 版と PowerShell 版の同等のデプロイスクリプトが用意されています。

| 環境 | デプロイスクリプト | パッケージ生成スクリプト |
|---|---|---|
| Linux / macOS / WSL | `infra/deploy.sh` | `teams/build_manifest.sh` |
| Windows PowerShell 5.1 / PowerShell 7 (Win/Linux/Mac) | `infra/deploy.ps1` | `teams/build_manifest.ps1` |

### 共通で必要なツール

- Azure CLI (`az`) — `az login` 済み
- Azure Functions Core Tools v4 (`func`)
- Python 3.10 以降（3.11 推奨）

### Bash 版で追加で必要なツール

- `bash` 4.x 以降
- `zip`、`uuidgen`
- `jq`（`teams/build_manifest.sh` のみ）

### PowerShell 版で追加で必要なツール

- Windows PowerShell 5.1（Windows 標準）または PowerShell 7+
- 追加コマンド不要（`Compress-Archive` と `[guid]::NewGuid()` を使用）

## 3. 必要な権限

デプロイスクリプトは Microsoft Entra アプリ登録 2 件と Microsoft Graph 経由のアプリロール割り当てを行います。サインインしているアカウントに次の権限が必要です。

- Microsoft Entra の **Application Administrator**（または同等のアプリ登録権限）
- 対象サブスクリプション/RG の **Owner** または **User Access Administrator**
- Microsoft Teams 管理センターで **カスタムアプリのサイドロード許可**

## 4. 環境変数

必須の環境変数は次の 6 つです。任意の上書き変数（`RG`、`LOC` 等）はスクリプト先頭で既定値を確認してください。

```text
FOUNDRY_RG                    Foundry リソースの RG 名
FOUNDRY_ACCOUNT               Foundry アカウント名
FOUNDRY_PROJECT_ENDPOINT      https://<account>.services.ai.azure.com/api/projects/<project>
FOUNDRY_MODEL_DEPLOYMENT_NAME モデルデプロイメント名
SPEECH_RG                     Speech リソースの RG 名
SPEECH_ACCOUNT                Speech アカウント名
```

## 5. デプロイ実行

### Linux / macOS / WSL の場合

```bash
export FOUNDRY_RG="<foundry-rg>"
export FOUNDRY_ACCOUNT="<foundry-account>"
export FOUNDRY_PROJECT_ENDPOINT="https://<account>.services.ai.azure.com/api/projects/<project>"
export FOUNDRY_MODEL_DEPLOYMENT_NAME="<model-deployment>"
export SPEECH_RG="<speech-rg>"
export SPEECH_ACCOUNT="<speech-account>"

chmod +x infra/deploy.sh
./infra/deploy.sh
```

### Windows PowerShell / PowerShell 7 の場合

```powershell
$env:FOUNDRY_RG                    = "<foundry-rg>"
$env:FOUNDRY_ACCOUNT               = "<foundry-account>"
$env:FOUNDRY_PROJECT_ENDPOINT      = "https://<account>.services.ai.azure.com/api/projects/<project>"
$env:FOUNDRY_MODEL_DEPLOYMENT_NAME = "<model-deployment>"
$env:SPEECH_RG      = "<speech-rg>"
$env:SPEECH_ACCOUNT = "<speech-account>"

./infra/deploy.ps1
```

スクリプトが行う主な処理:

1. リソースグループとユーザー割り当てマネージド ID (UAMI) を作成
2. ストレージアカウントとコンテナ（`input` / `output` / `jobs` / `conversation-refs`）、キュー（`work-items`）を作成
3. UAMI と Speech サービス MI に必要な RBAC ロールを付与
4. Function Tool API と BFF Internal API の Entra アプリ登録を作成しアプリロールを定義
5. Foundry MI に `FunctionTool.Invoke`、UAMI に `BffInternal.Callback` を割り当て
6. App Service (Linux/Python 3.11) を作成し BFF をデプロイ
7. Function App (Flex Consumption / Python 3.11) を作成し Functions コードをデプロイ
8. Azure Bot を作成し Microsoft Teams チャネルを有効化
9. Foundry にルーティング Agent と後処理 Agent を作成/更新

## 6. デプロイ出力値の確認

スクリプト末尾で次の値が出力されます。**Teams マニフェスト生成時に必須**なので必ず控えてください。

| 値 | 用途 |
|---|---|
| `BOT_APP_ID` (= UAMI clientId) | Teams マニフェストの `{{BOT_APP_ID}}` |
| `BFF_APP_HOSTNAME` (`<bffapp>.azurewebsites.net`) | Teams マニフェストの `{{BFF_APP_HOSTNAME}}` |

参考に表示されるエンドポイント:

- BFF: `https://<bffapp>.azurewebsites.net/api/messages`
- Function ツール: `https://<funcapp>.azurewebsites.net/api/tools/create_work_item`
- BFF 内部コールバック: `https://<bffapp>.azurewebsites.net/internal/jobs/{jobId}/complete|failed`

## 7. アイコンと正規 URL の準備（社内テスト用）

Teams マニフェストに必要な素材を用意します。

### アイコン

- `teams/color.png` — 192x192 px、フルカラー
- `teams/outline.png` — 32x32 px、透過モノクロ

### `developer` セクションの URL（社内テスト用）

社内 SharePoint やイントラに次の 3 ページを用意し、その URL を控えます。法務確認は本番運用時に実施してください。

- 組織サイト URL（`websiteUrl`）
- プライバシーポリシー URL（`privacyUrl`）
- 利用規約 URL（`termsOfUseUrl`）

## 8. Teams マニフェスト ZIP の生成

`teams/teams_manifest.template.json` はテンプレートで、**直接編集しません**。同梱のスクリプトが `teams/dist/teams-app.zip` を生成します。

### 初回ビルド（新しい Teams アプリ GUID を採番）

#### Linux / macOS / WSL

```bash
chmod +x teams/build_manifest.sh
./teams/build_manifest.sh \
    --bot-app-id "<deploy 出力の BOT_APP_ID>" \
    --bff-hostname "<bffapp>.azurewebsites.net" \
    --developer-name "Contoso 株式会社" \
    --website-url "https://intranet.contoso.example/teams-bot" \
    --privacy-url "https://intranet.contoso.example/teams-bot/privacy" \
    --terms-of-use-url "https://intranet.contoso.example/teams-bot/terms"
```

#### Windows PowerShell / PowerShell 7

```powershell
./teams/build_manifest.ps1 `
    -BotAppId "<deploy 出力の BOT_APP_ID>" `
    -BffHostname "<bffapp>.azurewebsites.net" `
    -DeveloperName "Contoso 株式会社" `
    -WebsiteUrl "https://intranet.contoso.example/teams-bot" `
    -PrivacyUrl "https://intranet.contoso.example/teams-bot/privacy" `
    -TermsOfUseUrl "https://intranet.contoso.example/teams-bot/terms"
```

実行後、コンソールに `TEAMS_APP_ID = <GUID>` が表示されます。**この値を保存**してください。再ビルド時に同じ値を渡さないと、Teams は別アプリと認識して再インストールが必要になります。

### 再ビルド（同じ Teams アプリの更新）

```bash
./teams/build_manifest.sh --teams-app-id "<保存した GUID>" --bot-app-id "..." # 以降は同じ
```

```powershell
./teams/build_manifest.ps1 -TeamsAppId "<保存した GUID>" -BotAppId "..." # 以降は同じ
```

### 生成物

- `teams/dist/manifest.json`
- `teams/dist/color.png` / `teams/dist/outline.png`
- `teams/dist/teams-app.zip` ← Teams にアップロードするファイル

## 9. Teams にアップロード

Microsoft Teams 管理センターで **カスタムアプリのサイドロードが許可されている**ことを確認したうえで、次のいずれかの方法でアップロードします。

### 個人テスト

1. Teams クライアント → **アプリ** → **アプリを管理** → **アプリをアップロード** → **カスタム アプリをアップロード**
2. `teams/dist/teams-app.zip` を選択
3. 個人スコープに追加してテスト

### 組織内配布

1. Teams 管理センター → **Teams アプリ** → **アプリを管理** → **アップロード**
2. アプリ許可ポリシーで対象ユーザー/グループに割り当て

## 10. 動作確認

Teams の個人チャットで Bot にメッセージを送り、`task_type` ごとに動作を確認します。

| 入力 | 期待動作 |
|---|---|
| 「こんにちは」（添付なし） | ルーティング Agent が直接応答（ツール呼ばない） |
| 録音.wav + 「テキスト化して」 | `transcribe_only` → トランスクリプトをそのまま返信 |
| 録音.wav + 「会議レポートを作成して」 | `transcribe_and_report` → 議事録 Markdown を返信 |
| 録音.wav + 「英語に翻訳して」 | `translate` → 翻訳テキストを返信 |
| log.txt + 「要約して」 | `summarize` → 要約を返信 |

トラブル時のログ確認場所:

| 観点 | 確認場所 |
|---|---|
| 受信ログ | App Service `<bffapp>` の Application Insights / ログストリーム |
| ジョブステート | Storage `jobs/<job-id>.json` |
| 入力ファイル | Storage `input/<job-id>/...` |
| トランスクリプト | Storage `output/<job-id>/transcript.txt` |
| 後処理結果 | Storage `output/<job-id>/result.md` |
| Function ログ | Function App `<funcapp>` の Application Insights |
| Bot 接続 | Azure ポータル Bot リソース → Channels（Microsoft Teams が Running） |

---

## マネージド ID と JWT 検証

デプロイスクリプトは次の 2 つの Entra アプリ登録を作成します。

| アプリ | Audience | アプリロール | ロール付与先 | 用途 |
|---|---|---|---|---|
| Function Tool API | `api://<function-tool-api-app-id>` | `FunctionTool.Invoke` | Foundry リソースの MI | Foundry Agent → Function ツール呼び出し |
| BFF Internal API | `api://<bff-internal-api-app-id>` | `BffInternal.Callback` | Function App の UAMI | Function Worker → BFF 内部コールバック |

検証する内容（BFF / Function ツール共通）:

- JWKS による JWT 署名検証
- audience（API ID URI）
- テナント ID
- 呼び出し元 appId
- アプリロール

## 既存リソースのカスタマイズ

任意の環境変数で名前を上書きできます。デプロイスクリプト先頭で確認してください。

| 変数 | 既定値 |
|---|---|
| `RG` | `rg-teams-foundry-callback` |
| `LOC` | `japaneast` |
| `STORAGE` | `sttfw<RANDOM>` |
| `BFFAPP` | `app-teams-foundry-bff-<RANDOM>` |
| `FUNCAPP` | `func-teams-foundry-tool-worker-<RANDOM>` |
| `BOT_NAME` | `bot-teams-foundry-<RANDOM>` |
| `UAMI` | `uami-teams-foundry` |
| `WORK_QUEUE_NAME` | `work-items` |
| `FOUNDRY_AGENT_NAME` | `teams-work-router-agent` |
| `FOUNDRY_POSTPROCESS_AGENT_NAME` | `teams-postprocess-agent` |

# Teams + App Service BFF + Function Tool/Worker + BFF Internal Callback

This version keeps all Teams response/proactive-message logic in the BFF App Service.

## Architecture

```text
Teams
  -> Azure Bot Service
  -> App Service BFF /api/messages
  -> Foundry Agent
  -> Azure Functions /api/tools/create_work_item
  -> Storage Queue work-items
  -> Azure Functions queue worker
  -> Speech Batch / Foundry model
  -> App Service BFF /internal/jobs/{jobId}/complete
  -> Teams proactive message
```

## Why this version

- BFF owns all Teams/Bot Framework concerns.
- Function owns all async processing.
- Agent Tool endpoint remains in Azure Functions.
- Function never sends Teams messages directly.
- BFF internal callbacks are protected by app-level Microsoft Entra JWT validation.
- No App Service Easy Auth is used.

## Folders

- `bff_app_service/`
  - FastAPI app on Azure App Service.
  - Receives Teams messages.
  - Saves Teams attachments to Blob.
  - Calls Foundry Agent.
  - Receives internal callbacks from Function Worker and sends Teams proactive messages.

- `function_app/`
  - Azure Functions Python v2 app.
  - Hosts Foundry Agent Tool endpoint: `/api/tools/create_work_item`.
  - Hosts Queue worker.
  - Calls BFF internal callbacks after completion/failure.

- `agent/`
  - Creates/updates Foundry Agent with Function-hosted OpenAPI Tool.

- `teams/`
  - Teams manifest template.

- `infra/`
  - Deployment script.

## Required existing resources

- New Microsoft Foundry project.
- Model deployment in the Foundry project.
- Speech/Foundry Tools resource with custom subdomain enabled.

## Prerequisites for deployment

Two equivalent deployment scripts are provided:

- `infra/deploy.sh` — Bash. Runs on Linux, macOS, or Windows WSL.
- `infra/deploy.ps1` — PowerShell. Runs on Windows PowerShell 5.1+ and PowerShell 7+ (Windows / Linux / macOS).

Use whichever fits your environment. Both produce the same Azure resources.

### Common required tools

- Azure CLI (`az`) — signed in via `az login`, with permissions to create resource groups, role assignments, and Microsoft Entra app registrations in the target tenant.
- Azure Functions Core Tools v4 (`func`) — used by `func azure functionapp publish`.
- Python 3.10 or later (3.11 recommended) with `python -m venv`.

### Bash (`infra/deploy.sh`) additional requirements

- `zip` and `uuidgen` available as shell commands.
- Bash 4.x or later (`bash`, `set -euo pipefail`).

### PowerShell (`infra/deploy.ps1`) additional requirements

- PowerShell 5.1 (Windows built-in) or PowerShell 7+.
- `Compress-Archive` and `[guid]::NewGuid()` are used in place of `zip` / `uuidgen`.

The script creates two Microsoft Entra app registrations (Function Tool API and BFF Internal API) and assigns app roles via Microsoft Graph. The signed-in identity needs at least the **Application Administrator** Entra role and **Owner** on the target subscription/resource group.

## Deploy

Set the required environment variables for the Foundry project, model deployment, and Speech resource that already exist in your tenant.

### Linux / macOS / WSL (Bash)

```bash
export FOUNDRY_RG="<foundry-resource-rg>"
export FOUNDRY_ACCOUNT="<foundry-resource-name>"
export FOUNDRY_PROJECT_ENDPOINT="https://<foundry-resource-name>.services.ai.azure.com/api/projects/<project-name>"
export FOUNDRY_MODEL_DEPLOYMENT_NAME="<model-deployment-name>"

export SPEECH_RG="<speech-resource-rg>"
export SPEECH_ACCOUNT="<speech-resource-name>"

chmod +x infra/deploy.sh
./infra/deploy.sh
```

### Windows PowerShell / PowerShell 7

```powershell
$env:FOUNDRY_RG                    = "<foundry-resource-rg>"
$env:FOUNDRY_ACCOUNT               = "<foundry-resource-name>"
$env:FOUNDRY_PROJECT_ENDPOINT      = "https://<foundry-resource-name>.services.ai.azure.com/api/projects/<project-name>"
$env:FOUNDRY_MODEL_DEPLOYMENT_NAME = "<model-deployment-name>"

$env:SPEECH_RG      = "<speech-resource-rg>"
$env:SPEECH_ACCOUNT = "<speech-resource-name>"

./infra/deploy.ps1
```

When the script finishes it prints the BFF hostname and the bot App ID. Keep these values for the Teams manifest build step below.

## Managed identity and JWT validation

This sample creates two Entra app registrations:

1. Function Tool API
   - Audience: `api://<function-tool-api-app-id>`
   - App role: `FunctionTool.Invoke`
   - Assigned to Foundry resource managed identity
   - Used by Foundry Agent -> Function Tool endpoint

2. BFF Internal API
   - Audience: `api://<bff-internal-api-app-id>`
   - App role: `BffInternal.Callback`
   - Assigned to the UAMI used by Function App
   - Used by Function Worker -> BFF internal callback

The BFF validates:
- JWT signature using Entra JWKS
- audience
- tenant id
- caller app id
- app role

The Function Tool endpoint validates:
- JWT signature using Entra JWKS
- audience
- tenant id
- caller app id
- app role

## Teams manifest

`teams/teams_manifest.template.json` is the source template and is **not modified directly**. Two equivalent build scripts are provided to generate `teams/dist/teams-app.zip` from the template:

- `teams/build_manifest.sh` — Bash. Requires `jq`, `zip`, and (optionally) `uuidgen`.
- `teams/build_manifest.ps1` — PowerShell. Uses built-in `Compress-Archive` and `[guid]::NewGuid()`.

Place your icons at `teams/color.png` (192x192) and `teams/outline.png` (32x32 transparent) before running.

### First build (a new Teams app GUID is generated)

#### Linux / macOS / WSL

```bash
chmod +x teams/build_manifest.sh
./teams/build_manifest.sh \
    --bot-app-id "<UAMI client id printed by deploy>" \
    --bff-hostname "<bffapp>.azurewebsites.net" \
    --developer-name "Contoso 株式会社" \
    --website-url "https://intranet.contoso.example/teams-bot" \
    --privacy-url "https://intranet.contoso.example/teams-bot/privacy" \
    --terms-of-use-url "https://intranet.contoso.example/teams-bot/terms"
```

#### Windows PowerShell / PowerShell 7

```powershell
./teams/build_manifest.ps1 `
    -BotAppId "<UAMI client id printed by deploy>" `
    -BffHostname "<bffapp>.azurewebsites.net" `
    -DeveloperName "Contoso 株式会社" `
    -WebsiteUrl "https://intranet.contoso.example/teams-bot" `
    -PrivacyUrl "https://intranet.contoso.example/teams-bot/privacy" `
    -TermsOfUseUrl "https://intranet.contoso.example/teams-bot/terms"
```

The script prints the newly generated `TEAMS_APP_ID`. **Save this value** for subsequent rebuilds.

### Rebuild (reuse the same Teams app)

Pass the saved `TEAMS_APP_ID` so Teams treats it as an update of the same app:

```bash
./teams/build_manifest.sh --teams-app-id "<saved guid>" --bot-app-id ...   # (rest as above)
```

```powershell
./teams/build_manifest.ps1 -TeamsAppId "<saved guid>" -BotAppId ...        # (rest as above)
```

### Output

Both scripts produce:

- `teams/dist/manifest.json`
- `teams/dist/color.png`, `teams/dist/outline.png`
- `teams/dist/teams-app.zip` — upload this to Teams as a custom app.
