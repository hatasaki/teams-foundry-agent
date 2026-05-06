#!/usr/bin/env bash
set -euo pipefail

# Teams + Foundry + Functions コールバックサンプルの一括デプロイスクリプト。
#
# 事前に必要な既存リソース:
#   - Microsoft Foundry プロジェクト + モデルデプロイメント
#   - Speech / Foundry Tools リソース（カスタムサブドメイン有効）
#
# 事前設定が必須な環境変数:
#   FOUNDRY_RG / FOUNDRY_ACCOUNT / FOUNDRY_PROJECT_ENDPOINT / FOUNDRY_MODEL_DEPLOYMENT_NAME
#   SPEECH_RG / SPEECH_ACCOUNT

# 作成するリソース名・リージョングループ名は環境変数で上書き可能
RG="${RG:-rg-teams-foundry-callback}"
LOC="${LOC:-japaneast}"
STORAGE="${STORAGE:-sttfw$RANDOM}"
PLAN="${PLAN:-asp-teams-foundry}"
BFFAPP="${BFFAPP:-app-teams-foundry-bff-$RANDOM}"
FUNCAPP="${FUNCAPP:-func-teams-foundry-tool-worker-$RANDOM}"
BOT_NAME="${BOT_NAME:-bot-teams-foundry-$RANDOM}"
UAMI="${UAMI:-uami-teams-foundry}"
WORK_QUEUE_NAME="${WORK_QUEUE_NAME:-work-items}"
FOUNDRY_AGENT_NAME="${FOUNDRY_AGENT_NAME:-teams-work-router-agent}"
FOUNDRY_POSTPROCESS_AGENT_NAME="${FOUNDRY_POSTPROCESS_AGENT_NAME:-teams-postprocess-agent}"
BFF_API_APP_NAME="${BFF_API_APP_NAME:-bff-internal-api-$RANDOM}"
FUNCTION_API_APP_NAME="${FUNCTION_API_APP_NAME:-function-tool-api-$RANDOM}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"

# リソースグループを作成
az group create -n "$RG" -l "$LOC"

# BFF / Function が共通で使うユーザー割り当てマネージド ID (UAMI) を作成
az identity create -g "$RG" -n "$UAMI"
UAMI_ID=$(az identity show -g "$RG" -n "$UAMI" --query id -o tsv)
UAMI_CLIENT_ID=$(az identity show -g "$RG" -n "$UAMI" --query clientId -o tsv)
UAMI_SP_OBJECT_ID=$(az ad sp show --id "$UAMI_CLIENT_ID" --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# ストレージ: 入力・出力・ジョブコード・会話参照コンテナ + キューを作成
az storage account create -g "$RG" -n "$STORAGE" -l "$LOC" --sku Standard_LRS --allow-blob-public-access false
az storage container create --account-name "$STORAGE" --name input --auth-mode login
az storage container create --account-name "$STORAGE" --name output --auth-mode login
az storage container create --account-name "$STORAGE" --name jobs --auth-mode login
az storage container create --account-name "$STORAGE" --name conversation-refs --auth-mode login
az storage queue create --account-name "$STORAGE" --name "$WORK_QUEUE_NAME" --auth-mode login

# UAMI にストレージへのデータ読み書き権限（RBAC）を付与
STORAGE_ID=$(az storage account show -g "$RG" -n "$STORAGE" --query id -o tsv)
az role assignment create --assignee "$UAMI_CLIENT_ID" --role "Storage Blob Data Owner" --scope "$STORAGE_ID" || true
az role assignment create --assignee "$UAMI_CLIENT_ID" --role "Storage Queue Data Contributor" --scope "$STORAGE_ID" || true

# Speech リソース: Entra 認証を有効にするためカスタムサブドメインが必須
SPEECH_RESOURCE_ID=$(az cognitiveservices account show -g "$SPEECH_RG" -n "$SPEECH_ACCOUNT" --query id -o tsv)
SPEECH_CUSTOM_SUBDOMAIN=$(az cognitiveservices account show -g "$SPEECH_RG" -n "$SPEECH_ACCOUNT" --query properties.customSubDomainName -o tsv)
if [ -z "$SPEECH_CUSTOM_SUBDOMAIN" ] || [ "$SPEECH_CUSTOM_SUBDOMAIN" = "null" ]; then
  echo "ERROR: Speech resource must have a custom subdomain for Microsoft Entra auth." >&2
  exit 1
fi
SPEECH_ENDPOINT="https://${SPEECH_CUSTOM_SUBDOMAIN}.cognitiveservices.azure.com"
# UAMI に Speech 呼び出しロールを付与
az role assignment create --assignee "$UAMI_CLIENT_ID" --role "Cognitive Services Speech User" --scope "$SPEECH_RESOURCE_ID" || true

# Speech サービス自体が入力音声ブロブを読めるよう、サービスマネージド ID にストレージ読取りロールを付与
az cognitiveservices account identity assign -g "$SPEECH_RG" -n "$SPEECH_ACCOUNT" || true
SPEECH_PRINCIPAL_ID=$(az cognitiveservices account identity show -g "$SPEECH_RG" -n "$SPEECH_ACCOUNT" --query principalId -o tsv)
az role assignment create --assignee-object-id "$SPEECH_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope "$STORAGE_ID" || true

# BFF / Function から Foundry を呼べるよう UAMI に Foundry ロールを付与
FOUNDRY_RESOURCE_ID=$(az cognitiveservices account show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query id -o tsv)
az role assignment create --assignee "$UAMI_CLIENT_ID" --role "Azure AI User" --scope "$FOUNDRY_RESOURCE_ID" || true

# Foundry リソースのシステムマネージド ID を有効化し、Function ツールを呼ぶための appId を取得
az cognitiveservices account identity assign -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" || true
FOUNDRY_OBJECT_ID=$(az cognitiveservices account show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query identity.principalId -o tsv)
FOUNDRY_ALLOWED_APP_ID=$(az ad sp show --id "$FOUNDRY_OBJECT_ID" --query appId -o tsv)

# Function Tool API 用の Entra アプリ登録を作成し、audience とアプリロールを定義
FUNCTION_API_APP_ID=$(az ad app create --display-name "$FUNCTION_API_APP_NAME" --query appId -o tsv)
FUNCTION_TOOL_AUDIENCE="api://${FUNCTION_API_APP_ID}"
FUNCTION_TOOL_ROLE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
cat > "$TMP_DIR/function-api-roles.json" <<EOF
[
  {
    "allowedMemberTypes": ["Application"],
    "description": "Invoke the Function-hosted Foundry OpenAPI tool.",
    "displayName": "Invoke Function Tool",
    "id": "${FUNCTION_TOOL_ROLE_ID}",
    "isEnabled": true,
    "value": "FunctionTool.Invoke"
  }
]
EOF
az ad app update --id "$FUNCTION_API_APP_ID" --identifier-uris "$FUNCTION_TOOL_AUDIENCE" --app-roles @"$TMP_DIR/function-api-roles.json"
az ad sp create --id "$FUNCTION_API_APP_ID" >/dev/null || true
FUNCTION_API_SP_OBJECT_ID=$(az ad sp show --id "$FUNCTION_API_APP_ID" --query id -o tsv)

# Foundry マネージド ID に FunctionTool.Invoke ロールを割り当て (Graph 経由)
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${FOUNDRY_OBJECT_ID}/appRoleAssignments" \
  --body "{\"principalId\":\"${FOUNDRY_OBJECT_ID}\",\"resourceId\":\"${FUNCTION_API_SP_OBJECT_ID}\",\"appRoleId\":\"${FUNCTION_TOOL_ROLE_ID}\"}" || true

# BFF 内部コールバック API 用の Entra アプリ登録を作成し、同様に audience とロールを定義
BFF_API_APP_ID=$(az ad app create --display-name "$BFF_API_APP_NAME" --query appId -o tsv)
BFF_INTERNAL_AUDIENCE="api://${BFF_API_APP_ID}"
BFF_ROLE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
cat > "$TMP_DIR/bff-api-roles.json" <<EOF
[
  {
    "allowedMemberTypes": ["Application"],
    "description": "Call BFF internal job callback endpoints.",
    "displayName": "BFF Internal Callback",
    "id": "${BFF_ROLE_ID}",
    "isEnabled": true,
    "value": "BffInternal.Callback"
  }
]
EOF
az ad app update --id "$BFF_API_APP_ID" --identifier-uris "$BFF_INTERNAL_AUDIENCE" --app-roles @"$TMP_DIR/bff-api-roles.json"
az ad sp create --id "$BFF_API_APP_ID" >/dev/null || true
BFF_API_SP_OBJECT_ID=$(az ad sp show --id "$BFF_API_APP_ID" --query id -o tsv)

# Function Worker が使う UAMI に BffInternal.Callback ロールを割り当て
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${UAMI_SP_OBJECT_ID}/appRoleAssignments" \
  --body "{\"principalId\":\"${UAMI_SP_OBJECT_ID}\",\"resourceId\":\"${BFF_API_SP_OBJECT_ID}\",\"appRoleId\":\"${BFF_ROLE_ID}\"}" || true

# App Service (BFF) プランと Web アプリを作成し、UAMI をアタッチ
az appservice plan create -g "$RG" -n "$PLAN" -l "$LOC" --sku B1 --is-linux
az webapp create -g "$RG" -p "$PLAN" -n "$BFFAPP" --runtime "PYTHON:3.11"
az webapp identity assign -g "$RG" -n "$BFFAPP" --identities "$UAMI_ID"

# BFF にボット・ストレージ・Foundry・内部コールバック認証関連の App Settings を設定
az webapp config appsettings set -g "$RG" -n "$BFFAPP" --settings \
  "SCM_DO_BUILD_DURING_DEPLOYMENT=true" \
  "ENABLE_ORYX_BUILD=true" \
  "MicrosoftAppType=UserAssignedMSI" \
  "MicrosoftAppId=$UAMI_CLIENT_ID" \
  "MicrosoftAppTenantId=$TENANT_ID" \
  "AZURE_CLIENT_ID=$UAMI_CLIENT_ID" \
  "FOUNDRY_PROJECT_ENDPOINT=$FOUNDRY_PROJECT_ENDPOINT" \
  "FOUNDRY_AGENT_NAME=$FOUNDRY_AGENT_NAME" \
  "STORAGE_ACCOUNT_NAME=$STORAGE" \
  "BFF_INTERNAL_AUDIENCE=$BFF_INTERNAL_AUDIENCE" \
  "FUNCTION_WORKER_ALLOWED_APP_ID=$UAMI_CLIENT_ID" \
  "BFF_INTERNAL_REQUIRED_ROLE=BffInternal.Callback"

# Gunicorn 起動スクリプトをスタートアップコマンドに設定
az webapp config set -g "$RG" -n "$BFFAPP" --startup-file "startup.sh"

# BFF コードを zip でデプロイ
pushd "$ROOT_DIR/bff_app_service"
zip -r "$ROOT_DIR/bff_app_service.zip" .
popd
az webapp deploy -g "$RG" -n "$BFFAPP" --src-path "$ROOT_DIR/bff_app_service.zip" --type zip

# Function App: Foundry Agent ツールエンドポイントとキュー Worker をホストする Flex Consumption プラン
az functionapp create \
  -g "$RG" -n "$FUNCAPP" \
  --storage-account "$STORAGE" \
  --flexconsumption-location "$LOC" \
  --runtime python \
  --runtime-version 3.11 \
  --functions-version 4

az functionapp identity assign -g "$RG" -n "$FUNCAPP" --identities "$UAMI_ID"

# Foundry MI が Function リソースを読めるよう Reader を付与（HTTP アクセス認証はコード側で検証）
FUNCAPP_ID=$(az functionapp show -g "$RG" -n "$FUNCAPP" --query id -o tsv)
az role assignment create --assignee-object-id "$FOUNDRY_OBJECT_ID" --assignee-principal-type ServicePrincipal --role "Reader" --scope "$FUNCAPP_ID" || true

# AzureWebJobsStorage / WORK_STORAGE を Managed Identity 接続に切り替えて App Settings を設定
az functionapp config appsettings delete -g "$RG" -n "$FUNCAPP" --setting-names AzureWebJobsStorage || true
az functionapp config appsettings set -g "$RG" -n "$FUNCAPP" --settings \
  "AzureWebJobsStorage__accountName=$STORAGE" \
  "AzureWebJobsStorage__credential=managedidentity" \
  "AzureWebJobsStorage__clientId=$UAMI_CLIENT_ID" \
  "WORK_STORAGE__queueServiceUri=https://${STORAGE}.queue.core.windows.net" \
  "WORK_STORAGE__credential=managedidentity" \
  "WORK_STORAGE__clientId=$UAMI_CLIENT_ID" \
  "STORAGE_ACCOUNT_NAME=$STORAGE" \
  "WORK_QUEUE_NAME=$WORK_QUEUE_NAME" \
  "MicrosoftAppTenantId=$TENANT_ID" \
  "AZURE_CLIENT_ID=$UAMI_CLIENT_ID" \
  "FOUNDRY_PROJECT_ENDPOINT=$FOUNDRY_PROJECT_ENDPOINT" \
  "FOUNDRY_MODEL_DEPLOYMENT_NAME=$FOUNDRY_MODEL_DEPLOYMENT_NAME" \
  "FOUNDRY_POSTPROCESS_AGENT_NAME=$FOUNDRY_POSTPROCESS_AGENT_NAME" \
  "FOUNDRY_ALLOWED_APP_ID=$FOUNDRY_ALLOWED_APP_ID" \
  "FUNCTION_TOOL_AUDIENCE=$FUNCTION_TOOL_AUDIENCE" \
  "FUNCTION_TOOL_REQUIRED_ROLE=FunctionTool.Invoke" \
  "BFF_INTERNAL_BASE_URL=https://${BFFAPP}.azurewebsites.net" \
  "BFF_INTERNAL_AUDIENCE=$BFF_INTERNAL_AUDIENCE" \
  "SPEECH_ENDPOINT=$SPEECH_ENDPOINT" \
  "SPEECH_API_VERSION=2025-10-15" \
  "DEFAULT_LOCALE=ja-JP"

# Function コードをビルドし、Functions Core Tools でデプロイ
pushd "$ROOT_DIR/function_app"
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m py_compile function_app.py
func azure functionapp publish "$FUNCAPP"
popd

# Azure Bot リソースを作成し、メッセージエンドポイントを BFF に向ける
az bot create \
  -g "$RG" \
  -n "$BOT_NAME" \
  --app-type UserAssignedMSI \
  --appid "$UAMI_CLIENT_ID" \
  --msi-resource-id "$UAMI_ID" \
  --tenant-id "$TENANT_ID" \
  --endpoint "https://${BFFAPP}.azurewebsites.net/api/messages" \
  --sku F0

# Microsoft Teams チャネルを有効化
az bot msteams create -g "$RG" -n "$BOT_NAME" || true

# Foundry Agent を作成/更新。OpenAPI ツールのもFunction App を指す
pushd "$ROOT_DIR/agent"
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export FUNCTION_TOOL_BASE_URL="https://${FUNCAPP}.azurewebsites.net"
export FUNCTION_TOOL_AUDIENCE="$FUNCTION_TOOL_AUDIENCE"
export FOUNDRY_AGENT_NAME="$FOUNDRY_AGENT_NAME"
python create_foundry_agent.py
# 后処理 Agent（ツールなし、要約/議事録化/翻訳を担当）を作成/更新
export FOUNDRY_POSTPROCESS_AGENT_NAME="$FOUNDRY_POSTPROCESS_AGENT_NAME"
python create_postprocess_agent.py
popd

cat <<EOF

Deployment finished.

BFF App Service:
  https://${BFFAPP}.azurewebsites.net

Teams Bot messaging endpoint:
  https://${BFFAPP}.azurewebsites.net/api/messages

Function-hosted Agent Tool endpoint:
  https://${FUNCAPP}.azurewebsites.net/api/tools/create_work_item

BFF internal callback endpoints:
  https://${BFFAPP}.azurewebsites.net/internal/jobs/{jobId}/complete
  https://${BFFAPP}.azurewebsites.net/internal/jobs/{jobId}/failed

Function Tool Audience:
  $FUNCTION_TOOL_AUDIENCE

BFF Internal Callback Audience:
  $BFF_INTERNAL_AUDIENCE

Bot App ID / Teams botId:
  $UAMI_CLIENT_ID

Teams manifest placeholders:
  {{BOT_APP_ID}}          = $UAMI_CLIENT_ID
  {{BFF_APP_HOSTNAME}}    = ${BFFAPP}.azurewebsites.net
  {{TEAMS_APP_ID}}        = generate a new GUID
EOF
