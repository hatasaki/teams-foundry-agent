#requires -Version 5.1
<#
.SYNOPSIS
    Teams マニフェストテンプレートからプレースホルダを置換し、配布用 ZIP を生成する。

.DESCRIPTION
    teams_manifest.template.json を読み込み、TEAMS_APP_ID / BOT_APP_ID / BFF_APP_HOSTNAME と
    developer セクションの URL・組織名を社内テスト用の値で置換した manifest.json を作成する。
    color.png / outline.png と一緒に dist/teams-app.zip にパッケージ化する。
    元のテンプレートファイルは変更しない。

.PARAMETER BotAppId
    Azure Bot の App ID。deploy.sh 出力の UAMI_CLIENT_ID。

.PARAMETER BffHostname
    BFF App Service のホスト名 (例: app-teams-foundry-bff-12345.azurewebsites.net)。

.PARAMETER DeveloperName
    developer.name の表示名。社内利用なら組織名を指定。

.PARAMETER WebsiteUrl
    developer.websiteUrl の URL。

.PARAMETER PrivacyUrl
    developer.privacyUrl の URL。

.PARAMETER TermsOfUseUrl
    developer.termsOfUseUrl の URL。

.PARAMETER TeamsAppId
    Teams アプリ ID として使う GUID。省略時は新規生成する。
    再ビルド時は既存の値をそのまま指定すること。

.PARAMETER ColorIcon
    color.png のパス。既定値: teams/color.png

.PARAMETER OutlineIcon
    outline.png のパス。既定値: teams/outline.png

.PARAMETER OutputDir
    出力先ディレクトリ。既定値: teams/dist

.EXAMPLE
    ./teams/build_manifest.ps1 `
        -BotAppId "00000000-0000-0000-0000-000000000000" `
        -BffHostname "app-teams-foundry-bff-12345.azurewebsites.net" `
        -DeveloperName "Contoso 株式会社" `
        -WebsiteUrl "https://intranet.contoso.co.jp/teams-bot" `
        -PrivacyUrl "https://intranet.contoso.co.jp/teams-bot/privacy" `
        -TermsOfUseUrl "https://intranet.contoso.co.jp/teams-bot/terms"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BotAppId,
    [Parameter(Mandatory = $true)] [string] $BffHostname,
    [Parameter(Mandatory = $true)] [string] $DeveloperName,
    [Parameter(Mandatory = $true)] [string] $WebsiteUrl,
    [Parameter(Mandatory = $true)] [string] $PrivacyUrl,
    [Parameter(Mandatory = $true)] [string] $TermsOfUseUrl,
    [string] $TeamsAppId,
    [string] $ColorIcon,
    [string] $OutlineIcon,
    [string] $OutputDir
)

$ErrorActionPreference = "Stop"

# スクリプトのあるディレクトリを基準にパスを解決する
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $ScriptDir "teams_manifest.template.json"

if (-not $ColorIcon)   { $ColorIcon   = Join-Path $ScriptDir "color.png" }
if (-not $OutlineIcon) { $OutlineIcon = Join-Path $ScriptDir "outline.png" }
if (-not $OutputDir)   { $OutputDir   = Join-Path $ScriptDir "dist" }

if (-not (Test-Path $TemplatePath)) {
    throw "テンプレートが見つかりません: $TemplatePath"
}
foreach ($icon in @($ColorIcon, $OutlineIcon)) {
    if (-not (Test-Path $icon)) {
        throw "アイコンファイルが見つかりません: $icon"
    }
}

# 未指定なら新しい GUID を採番。再ビルド時は呼び出し側で同じ値を渡すこと。
if (-not $TeamsAppId) {
    $TeamsAppId = [guid]::NewGuid().ToString()
    Write-Host "TEAMS_APP_ID を新規生成しました: $TeamsAppId" -ForegroundColor Yellow
    Write-Host "再ビルド時はこの値を -TeamsAppId で渡してください。" -ForegroundColor Yellow
}

# テンプレートを読み込み、プレースホルダを文字列置換
$content = Get-Content -Raw -Encoding UTF8 -Path $TemplatePath
$content = $content.Replace('{{TEAMS_APP_ID}}', $TeamsAppId)
$content = $content.Replace('{{BOT_APP_ID}}', $BotAppId)
$content = $content.Replace('{{BFF_APP_HOSTNAME}}', $BffHostname)

# developer セクションは JSON としてパースしてから書き換える
$manifest = $content | ConvertFrom-Json
$manifest.developer.name          = $DeveloperName
$manifest.developer.websiteUrl    = $WebsiteUrl
$manifest.developer.privacyUrl    = $PrivacyUrl
$manifest.developer.termsOfUseUrl = $TermsOfUseUrl

# 出力ディレクトリを準備
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$manifestOut = Join-Path $OutputDir "manifest.json"
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestOut -Encoding UTF8

# アイコンを出力ディレクトリへコピー
Copy-Item -Path $ColorIcon   -Destination (Join-Path $OutputDir "color.png")   -Force
Copy-Item -Path $OutlineIcon -Destination (Join-Path $OutputDir "outline.png") -Force

# Teams アプリパッケージ ZIP を作成（manifest.json と PNG をルート直下に含める）
$zipPath = Join-Path $OutputDir "teams-app.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive `
    -Path (Join-Path $OutputDir "manifest.json"),
          (Join-Path $OutputDir "color.png"),
          (Join-Path $OutputDir "outline.png") `
    -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Teams アプリパッケージを生成しました:" -ForegroundColor Green
Write-Host "  $zipPath"
Write-Host ""
Write-Host "TEAMS_APP_ID = $TeamsAppId"
Write-Host "BOT_APP_ID   = $BotAppId"
Write-Host "BFF_HOST     = $BffHostname"
