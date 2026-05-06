#requires -Version 5.1
<#
.SYNOPSIS
    Teams + Foundry + Functions サンプルアプリを Azure に一括デプロイする (PowerShell 版)。

.DESCRIPTION
    deploy.sh と同じ処理を PowerShell で実装する。Windows PowerShell 5.1 と PowerShell 7 (Linux/macOS) の両方で動作する。

.NOTES
    必須環境変数:
      FOUNDRY_RG / FOUNDRY_ACCOUNT / FOUNDRY_PROJECT_ENDPOINT / FOUNDRY_MODEL_DEPLOYMENT_NAME
      SPEECH_RG / SPEECH_ACCOUNT
    任意環境変数:
      RG / LOC / STORAGE / PLAN / BFFAPP / FUNCAPP / BOT_NAME / UAMI
      WORK_QUEUE_NAME / FOUNDRY_AGENT_NAME / FOUNDRY_POSTPROCESS_AGENT_NAME
      BFF_API_APP_NAME / FUNCTION_API_APP_NAME

    必要ツール: az (ログイン済み), func v4, python 3.10+
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# 必須環境変数を取得し、未設定なら停止する
function Get-RequiredEnv {
    param([Parameter(Mandatory)] [string] $Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) {
        throw "Required environment variable is not set: $Name"
    }
    return $value
}

# 任意の環境変数を取得し、未設定なら既定値を返す
function Get-EnvOrDefault {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $DefaultValue
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) { return $DefaultValue }
    return $value
}

# az / func コマンドの存在を確認
function Assert-Command {
    param([Parameter(Mandatory)] [string] $Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found in PATH: $Name"
    }
}

# az コマンドを実行し、空でない文字列を返す。stderr は無視せずにエラー化
function Invoke-Az {
    param([Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Args)
    $output = & az @Args
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Args -join ' ') failed with exit code $LASTEXITCODE"
    }
    return $output
}

# az コマンドを実行するが、失敗してもスクリプトを止めない (deploy.sh の '|| true' 相当)
function Invoke-AzAllowFailure {
    param([Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Args)
    & az @Args 2>&1 | Out-Null
}

# 必須コマンドの存在チェック
Assert-Command az
Assert-Command func
Assert-Command python

# 必須環境変数 (deploy.sh と同じ)
$FOUNDRY_RG                       = Get-RequiredEnv "FOUNDRY_RG"
$FOUNDRY_ACCOUNT                  = Get-RequiredEnv "FOUNDRY_ACCOUNT"
$FOUNDRY_PROJECT_ENDPOINT         = Get-RequiredEnv "FOUNDRY_PROJECT_ENDPOINT"
$FOUNDRY_MODEL_DEPLOYMENT_NAME    = Get-RequiredEnv "FOUNDRY_MODEL_DEPLOYMENT_NAME"
$SPEECH_RG                        = Get-RequiredEnv "SPEECH_RG"
$SPEECH_ACCOUNT                   = Get-RequiredEnv "SPEECH_ACCOUNT"

# 任意の環境変数 (上書き可)。$RANDOM 相当はホスト名に使えるよう数値化する
$RND = (Get-Random -Maximum 32767).ToString()

$RG                               = Get-EnvOrDefault "RG"                              "rg-teams-foundry-callback"
$LOC                              = Get-EnvOrDefault "LOC"                             "japaneast"
$STORAGE                          = Get-EnvOrDefault "STORAGE"                         "sttfw$RND"
$PLAN                             = Get-EnvOrDefault "PLAN"                            "asp-teams-foundry"
$BFFAPP                           = Get-EnvOrDefault "BFFAPP"                          "app-teams-foundry-bff-$RND"
$FUNCAPP                          = Get-EnvOrDefault "FUNCAPP"                         "func-teams-foundry-tool-worker-$RND"
$BOT_NAME                         = Get-EnvOrDefault "BOT_NAME"                        "bot-teams-foundry-$RND"
$UAMI                             = Get-EnvOrDefault "UAMI"                            "uami-teams-foundry"
$WORK_QUEUE_NAME                  = Get-EnvOrDefault "WORK_QUEUE_NAME"                 "work-items"
$FOUNDRY_AGENT_NAME               = Get-EnvOrDefault "FOUNDRY_AGENT_NAME"              "teams-work-router-agent"
$FOUNDRY_POSTPROCESS_AGENT_NAME   = Get-EnvOrDefault "FOUNDRY_POSTPROCESS_AGENT_NAME"  "teams-postprocess-agent"
$BFF_API_APP_NAME                 = Get-EnvOrDefault "BFF_API_APP_NAME"                "bff-internal-api-$RND"
$FUNCTION_API_APP_NAME            = Get-EnvOrDefault "FUNCTION_API_APP_NAME"           "function-tool-api-$RND"

# パス解決
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Resolve-Path (Join-Path $ScriptDir "..")
$TmpDir    = Join-Path ([System.IO.Path]::GetTempPath()) ("teams-foundry-deploy-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

# ----------------------------------------------------------------------------
# リソースグループと UAMI を作成
# ----------------------------------------------------------------------------
Invoke-Az group create -n $RG -l $LOC | Out-Null

Invoke-Az identity create -g $RG -n $UAMI | Out-Null
$UAMI_ID            = Invoke-Az identity show -g $RG -n $UAMI --query id -o tsv
$UAMI_CLIENT_ID     = Invoke-Az identity show -g $RG -n $UAMI --query clientId -o tsv
$UAMI_SP_OBJECT_ID  = Invoke-Az ad sp show --id $UAMI_CLIENT_ID --query id -o tsv
$TENANT_ID          = Invoke-Az account show --query tenantId -o tsv

# ----------------------------------------------------------------------------
# ストレージとコンテナ・キューを作成
# ----------------------------------------------------------------------------
Invoke-Az storage account create -g $RG -n $STORAGE -l $LOC --sku Standard_LRS --allow-blob-public-access false | Out-Null
foreach ($container in @("input","output","jobs","conversation-refs")) {
    Invoke-Az storage container create --account-name $STORAGE --name $container --auth-mode login | Out-Null
}
Invoke-Az storage queue create --account-name $STORAGE --name $WORK_QUEUE_NAME --auth-mode login | Out-Null

# UAMI にストレージ操作ロールを付与 (失敗しても続行)
$STORAGE_ID = Invoke-Az storage account show -g $RG -n $STORAGE --query id -o tsv
Invoke-AzAllowFailure role assignment create --assignee $UAMI_CLIENT_ID --role "Storage Blob Data Owner"      --scope $STORAGE_ID
Invoke-AzAllowFailure role assignment create --assignee $UAMI_CLIENT_ID --role "Storage Queue Data Contributor" --scope $STORAGE_ID

# ----------------------------------------------------------------------------
# Speech リソース: カスタムサブドメインの確認と権限付与
# ----------------------------------------------------------------------------
$SPEECH_RESOURCE_ID       = Invoke-Az cognitiveservices account show -g $SPEECH_RG -n $SPEECH_ACCOUNT --query id -o tsv
$SPEECH_CUSTOM_SUBDOMAIN  = Invoke-Az cognitiveservices account show -g $SPEECH_RG -n $SPEECH_ACCOUNT --query properties.customSubDomainName -o tsv
if ([string]::IsNullOrEmpty($SPEECH_CUSTOM_SUBDOMAIN) -or $SPEECH_CUSTOM_SUBDOMAIN -eq "null") {
    throw "Speech resource must have a custom subdomain for Microsoft Entra auth."
}
$SPEECH_ENDPOINT = "https://$SPEECH_CUSTOM_SUBDOMAIN.cognitiveservices.azure.com"

Invoke-AzAllowFailure role assignment create --assignee $UAMI_CLIENT_ID --role "Cognitive Services Speech User" --scope $SPEECH_RESOURCE_ID

# Speech サービス自身がストレージから音声ブロブを読めるよう、サービス MI に Reader を付与
Invoke-AzAllowFailure cognitiveservices account identity assign -g $SPEECH_RG -n $SPEECH_ACCOUNT
$SPEECH_PRINCIPAL_ID = Invoke-Az cognitiveservices account identity show -g $SPEECH_RG -n $SPEECH_ACCOUNT --query principalId -o tsv
Invoke-AzAllowFailure role assignment create --assignee-object-id $SPEECH_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope $STORAGE_ID

# ----------------------------------------------------------------------------
# Foundry: UAMI に Azure AI User、システム MI を有効化
# ----------------------------------------------------------------------------
$FOUNDRY_RESOURCE_ID = Invoke-Az cognitiveservices account show -g $FOUNDRY_RG -n $FOUNDRY_ACCOUNT --query id -o tsv
Invoke-AzAllowFailure role assignment create --assignee $UAMI_CLIENT_ID --role "Azure AI User" --scope $FOUNDRY_RESOURCE_ID

Invoke-AzAllowFailure cognitiveservices account identity assign -g $FOUNDRY_RG -n $FOUNDRY_ACCOUNT
$FOUNDRY_OBJECT_ID         = Invoke-Az cognitiveservices account show -g $FOUNDRY_RG -n $FOUNDRY_ACCOUNT --query identity.principalId -o tsv
$FOUNDRY_ALLOWED_APP_ID    = Invoke-Az ad sp show --id $FOUNDRY_OBJECT_ID --query appId -o tsv

# ----------------------------------------------------------------------------
# Function Tool API 用 Entra アプリ登録 + アプリロール
# ----------------------------------------------------------------------------
$FUNCTION_API_APP_ID    = Invoke-Az ad app create --display-name $FUNCTION_API_APP_NAME --query appId -o tsv
$FUNCTION_TOOL_AUDIENCE = "api://$FUNCTION_API_APP_ID"
$FUNCTION_TOOL_ROLE_ID  = [guid]::NewGuid().ToString().ToLower()

$functionApiRolesJson = @"
[
  {
    "allowedMemberTypes": ["Application"],
    "description": "Invoke the Function-hosted Foundry OpenAPI tool.",
    "displayName": "Invoke Function Tool",
    "id": "$FUNCTION_TOOL_ROLE_ID",
    "isEnabled": true,
    "value": "FunctionTool.Invoke"
  }
]
"@
$functionApiRolesPath = Join-Path $TmpDir "function-api-roles.json"
Set-Content -Path $functionApiRolesPath -Value $functionApiRolesJson -Encoding UTF8

Invoke-Az ad app update --id $FUNCTION_API_APP_ID --identifier-uris $FUNCTION_TOOL_AUDIENCE --app-roles "@$functionApiRolesPath" | Out-Null
Invoke-AzAllowFailure ad sp create --id $FUNCTION_API_APP_ID
$FUNCTION_API_SP_OBJECT_ID = Invoke-Az ad sp show --id $FUNCTION_API_APP_ID --query id -o tsv

# Foundry MI に FunctionTool.Invoke を割り当て (Graph API)
$assignFuncBody = "{`"principalId`":`"$FOUNDRY_OBJECT_ID`",`"resourceId`":`"$FUNCTION_API_SP_OBJECT_ID`",`"appRoleId`":`"$FUNCTION_TOOL_ROLE_ID`"}"
Invoke-AzAllowFailure rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$FOUNDRY_OBJECT_ID/appRoleAssignments" --body $assignFuncBody

# ----------------------------------------------------------------------------
# BFF Internal API 用 Entra アプリ登録 + アプリロール
# ----------------------------------------------------------------------------
$BFF_API_APP_ID         = Invoke-Az ad app create --display-name $BFF_API_APP_NAME --query appId -o tsv
$BFF_INTERNAL_AUDIENCE  = "api://$BFF_API_APP_ID"
$BFF_ROLE_ID            = [guid]::NewGuid().ToString().ToLower()

$bffApiRolesJson = @"
[
  {
    "allowedMemberTypes": ["Application"],
    "description": "Call BFF internal job callback endpoints.",
    "displayName": "BFF Internal Callback",
    "id": "$BFF_ROLE_ID",
    "isEnabled": true,
    "value": "BffInternal.Callback"
  }
]
"@
$bffApiRolesPath = Join-Path $TmpDir "bff-api-roles.json"
Set-Content -Path $bffApiRolesPath -Value $bffApiRolesJson -Encoding UTF8

Invoke-Az ad app update --id $BFF_API_APP_ID --identifier-uris $BFF_INTERNAL_AUDIENCE --app-roles "@$bffApiRolesPath" | Out-Null
Invoke-AzAllowFailure ad sp create --id $BFF_API_APP_ID
$BFF_API_SP_OBJECT_ID = Invoke-Az ad sp show --id $BFF_API_APP_ID --query id -o tsv

# UAMI (Function Worker) に BffInternal.Callback を割り当て
$assignBffBody = "{`"principalId`":`"$UAMI_SP_OBJECT_ID`",`"resourceId`":`"$BFF_API_SP_OBJECT_ID`",`"appRoleId`":`"$BFF_ROLE_ID`"}"
Invoke-AzAllowFailure rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$UAMI_SP_OBJECT_ID/appRoleAssignments" --body $assignBffBody

# ----------------------------------------------------------------------------
# App Service (BFF) を作成し、UAMI をアタッチ + AppSettings 設定
# ----------------------------------------------------------------------------
Invoke-Az appservice plan create -g $RG -n $PLAN -l $LOC --sku B1 --is-linux | Out-Null
Invoke-Az webapp create -g $RG -p $PLAN -n $BFFAPP --runtime "PYTHON:3.11" | Out-Null
Invoke-Az webapp identity assign -g $RG -n $BFFAPP --identities $UAMI_ID | Out-Null

Invoke-Az webapp config appsettings set -g $RG -n $BFFAPP --settings `
    "SCM_DO_BUILD_DURING_DEPLOYMENT=true" `
    "ENABLE_ORYX_BUILD=true" `
    "MicrosoftAppType=UserAssignedMSI" `
    "MicrosoftAppId=$UAMI_CLIENT_ID" `
    "MicrosoftAppTenantId=$TENANT_ID" `
    "AZURE_CLIENT_ID=$UAMI_CLIENT_ID" `
    "FOUNDRY_PROJECT_ENDPOINT=$FOUNDRY_PROJECT_ENDPOINT" `
    "FOUNDRY_AGENT_NAME=$FOUNDRY_AGENT_NAME" `
    "STORAGE_ACCOUNT_NAME=$STORAGE" `
    "BFF_INTERNAL_AUDIENCE=$BFF_INTERNAL_AUDIENCE" `
    "FUNCTION_WORKER_ALLOWED_APP_ID=$UAMI_CLIENT_ID" `
    "BFF_INTERNAL_REQUIRED_ROLE=BffInternal.Callback" | Out-Null

Invoke-Az webapp config set -g $RG -n $BFFAPP --startup-file "startup.sh" | Out-Null

# BFF コードを ZIP 化してデプロイ
$BffZipPath = Join-Path $RootDir "bff_app_service.zip"
if (Test-Path $BffZipPath) { Remove-Item $BffZipPath -Force }
Push-Location (Join-Path $RootDir "bff_app_service")
try {
    Compress-Archive -Path (Get-ChildItem -Force | Select-Object -ExpandProperty FullName) -DestinationPath $BffZipPath -Force
}
finally {
    Pop-Location
}
Invoke-Az webapp deploy -g $RG -n $BFFAPP --src-path $BffZipPath --type zip | Out-Null

# ----------------------------------------------------------------------------
# Function App (Flex Consumption) 作成 + AppSettings 設定 + コードデプロイ
# ----------------------------------------------------------------------------
Invoke-Az functionapp create `
    -g $RG -n $FUNCAPP `
    --storage-account $STORAGE `
    --flexconsumption-location $LOC `
    --runtime python `
    --runtime-version 3.11 `
    --functions-version 4 | Out-Null

Invoke-Az functionapp identity assign -g $RG -n $FUNCAPP --identities $UAMI_ID | Out-Null

# Foundry MI に Function リソースの Reader を付与 (HTTP は code 側で検証)
$FUNCAPP_ID = Invoke-Az functionapp show -g $RG -n $FUNCAPP --query id -o tsv
Invoke-AzAllowFailure role assignment create --assignee-object-id $FOUNDRY_OBJECT_ID --assignee-principal-type ServicePrincipal --role "Reader" --scope $FUNCAPP_ID

# AzureWebJobsStorage を MI 接続に切り替え
Invoke-AzAllowFailure functionapp config appsettings delete -g $RG -n $FUNCAPP --setting-names AzureWebJobsStorage

Invoke-Az functionapp config appsettings set -g $RG -n $FUNCAPP --settings `
    "AzureWebJobsStorage__accountName=$STORAGE" `
    "AzureWebJobsStorage__credential=managedidentity" `
    "AzureWebJobsStorage__clientId=$UAMI_CLIENT_ID" `
    "WORK_STORAGE__queueServiceUri=https://$STORAGE.queue.core.windows.net" `
    "WORK_STORAGE__credential=managedidentity" `
    "WORK_STORAGE__clientId=$UAMI_CLIENT_ID" `
    "STORAGE_ACCOUNT_NAME=$STORAGE" `
    "WORK_QUEUE_NAME=$WORK_QUEUE_NAME" `
    "MicrosoftAppTenantId=$TENANT_ID" `
    "AZURE_CLIENT_ID=$UAMI_CLIENT_ID" `
    "FOUNDRY_PROJECT_ENDPOINT=$FOUNDRY_PROJECT_ENDPOINT" `
    "FOUNDRY_MODEL_DEPLOYMENT_NAME=$FOUNDRY_MODEL_DEPLOYMENT_NAME" `
    "FOUNDRY_POSTPROCESS_AGENT_NAME=$FOUNDRY_POSTPROCESS_AGENT_NAME" `
    "FOUNDRY_ALLOWED_APP_ID=$FOUNDRY_ALLOWED_APP_ID" `
    "FUNCTION_TOOL_AUDIENCE=$FUNCTION_TOOL_AUDIENCE" `
    "FUNCTION_TOOL_REQUIRED_ROLE=FunctionTool.Invoke" `
    "BFF_INTERNAL_BASE_URL=https://$BFFAPP.azurewebsites.net" `
    "BFF_INTERNAL_AUDIENCE=$BFF_INTERNAL_AUDIENCE" `
    "SPEECH_ENDPOINT=$SPEECH_ENDPOINT" `
    "SPEECH_API_VERSION=2025-10-15" `
    "DEFAULT_LOCALE=ja-JP" | Out-Null

# Function コードのビルドとデプロイ。venv のアクティベート方法は OS で異なる
Push-Location (Join-Path $RootDir "function_app")
try {
    & python -m venv .venv
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $venvPython = Join-Path (Resolve-Path ".venv") "Scripts\python.exe"
    } else {
        $venvPython = Join-Path (Resolve-Path ".venv") "bin/python"
    }
    & $venvPython -m pip install --quiet -r requirements.txt
    & $venvPython -m py_compile function_app.py
    & func azure functionapp publish $FUNCAPP --python
    if ($LASTEXITCODE -ne 0) { throw "func publish failed" }
}
finally {
    Pop-Location
}

# ----------------------------------------------------------------------------
# Azure Bot リソース + Microsoft Teams チャネル
# ----------------------------------------------------------------------------
Invoke-Az bot create `
    -g $RG `
    -n $BOT_NAME `
    --app-type UserAssignedMSI `
    --appid $UAMI_CLIENT_ID `
    --msi-resource-id $UAMI_ID `
    --tenant-id $TENANT_ID `
    --endpoint "https://$BFFAPP.azurewebsites.net/api/messages" `
    --sku F0 | Out-Null

Invoke-AzAllowFailure bot msteams create -g $RG -n $BOT_NAME

# ----------------------------------------------------------------------------
# Foundry Agent (ルーティング + 後処理) を作成/更新
# ----------------------------------------------------------------------------
Push-Location (Join-Path $RootDir "agent")
try {
    & python -m venv .venv
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $venvPython = Join-Path (Resolve-Path ".venv") "Scripts\python.exe"
    } else {
        $venvPython = Join-Path (Resolve-Path ".venv") "bin/python"
    }
    & $venvPython -m pip install --quiet -r requirements.txt

    # Agent 作成スクリプトに渡す環境変数を設定
    $env:FUNCTION_TOOL_BASE_URL            = "https://$FUNCAPP.azurewebsites.net"
    $env:FUNCTION_TOOL_AUDIENCE            = $FUNCTION_TOOL_AUDIENCE
    $env:FOUNDRY_AGENT_NAME                = $FOUNDRY_AGENT_NAME
    $env:FOUNDRY_PROJECT_ENDPOINT          = $FOUNDRY_PROJECT_ENDPOINT
    $env:FOUNDRY_MODEL_DEPLOYMENT_NAME     = $FOUNDRY_MODEL_DEPLOYMENT_NAME
    $env:FOUNDRY_POSTPROCESS_AGENT_NAME    = $FOUNDRY_POSTPROCESS_AGENT_NAME

    & $venvPython create_foundry_agent.py
    if ($LASTEXITCODE -ne 0) { throw "create_foundry_agent.py failed" }

    & $venvPython create_postprocess_agent.py
    if ($LASTEXITCODE -ne 0) { throw "create_postprocess_agent.py failed" }
}
finally {
    Pop-Location
}

# ----------------------------------------------------------------------------
# 完了サマリー
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "Deployment finished." -ForegroundColor Green
Write-Host ""
Write-Host "BFF App Service:"
Write-Host "  https://$BFFAPP.azurewebsites.net"
Write-Host ""
Write-Host "Teams Bot messaging endpoint:"
Write-Host "  https://$BFFAPP.azurewebsites.net/api/messages"
Write-Host ""
Write-Host "Function-hosted Agent Tool endpoint:"
Write-Host "  https://$FUNCAPP.azurewebsites.net/api/tools/create_work_item"
Write-Host ""
Write-Host "BFF internal callback endpoints:"
Write-Host "  https://$BFFAPP.azurewebsites.net/internal/jobs/{jobId}/complete"
Write-Host "  https://$BFFAPP.azurewebsites.net/internal/jobs/{jobId}/failed"
Write-Host ""
Write-Host "Function Tool Audience:        $FUNCTION_TOOL_AUDIENCE"
Write-Host "BFF Internal Callback Audience: $BFF_INTERNAL_AUDIENCE"
Write-Host "Bot App ID / Teams botId:       $UAMI_CLIENT_ID"
Write-Host ""
Write-Host "Teams manifest placeholders:"
Write-Host "  {{BOT_APP_ID}}        = $UAMI_CLIENT_ID"
Write-Host "  {{BFF_APP_HOSTNAME}}  = $BFFAPP.azurewebsites.net"
Write-Host "  {{TEAMS_APP_ID}}      = generate a new GUID"
