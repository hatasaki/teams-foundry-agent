#!/usr/bin/env bash
# Teams マニフェストテンプレートからプレースホルダを置換し、配布用 ZIP を生成する。
# build_manifest.ps1 (PowerShell 版) と等価な処理を Bash で実装する。
# 元のテンプレートファイルは変更しない。

set -euo pipefail

# 使い方を表示
usage() {
    cat <<'EOF'
Usage:
  build_manifest.sh \
    --bot-app-id <UUID> \
    --bff-hostname <hostname> \
    --developer-name "<organization name>" \
    --website-url <url> \
    --privacy-url <url> \
    --terms-of-use-url <url> \
    [--teams-app-id <UUID>] \
    [--color-icon <path>] \
    [--outline-icon <path>] \
    [--output-dir <path>]

Notes:
  - --teams-app-id は省略時に新規生成される。再ビルド時は同じ値を指定すること。
  - 必要ツール: jq, zip
EOF
}

# 必須コマンドの存在確認
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $1" >&2
        exit 1
    fi
}
require_cmd jq
require_cmd zip

# パラメータ既定値
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="$SCRIPT_DIR/teams_manifest.template.json"
COLOR_ICON="$SCRIPT_DIR/color.png"
OUTLINE_ICON="$SCRIPT_DIR/outline.png"
OUTPUT_DIR="$SCRIPT_DIR/dist"
TEAMS_APP_ID=""
BOT_APP_ID=""
BFF_HOSTNAME=""
DEVELOPER_NAME=""
WEBSITE_URL=""
PRIVACY_URL=""
TERMS_OF_USE_URL=""

# 引数パース
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bot-app-id)        BOT_APP_ID="$2"; shift 2 ;;
        --bff-hostname)      BFF_HOSTNAME="$2"; shift 2 ;;
        --developer-name)    DEVELOPER_NAME="$2"; shift 2 ;;
        --website-url)       WEBSITE_URL="$2"; shift 2 ;;
        --privacy-url)       PRIVACY_URL="$2"; shift 2 ;;
        --terms-of-use-url)  TERMS_OF_USE_URL="$2"; shift 2 ;;
        --teams-app-id)      TEAMS_APP_ID="$2"; shift 2 ;;
        --color-icon)        COLOR_ICON="$2"; shift 2 ;;
        --outline-icon)      OUTLINE_ICON="$2"; shift 2 ;;
        --output-dir)        OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# 必須引数チェック
for var_name in BOT_APP_ID BFF_HOSTNAME DEVELOPER_NAME WEBSITE_URL PRIVACY_URL TERMS_OF_USE_URL; do
    if [[ -z "${!var_name}" ]]; then
        echo "ERROR: --$(echo "$var_name" | tr '[:upper:]_' '[:lower:]-') is required" >&2
        usage
        exit 1
    fi
done

# テンプレートとアイコンの存在確認
[[ -f "$TEMPLATE_PATH" ]] || { echo "ERROR: template not found: $TEMPLATE_PATH" >&2; exit 1; }
[[ -f "$COLOR_ICON"   ]] || { echo "ERROR: color icon not found: $COLOR_ICON" >&2;     exit 1; }
[[ -f "$OUTLINE_ICON" ]] || { echo "ERROR: outline icon not found: $OUTLINE_ICON" >&2; exit 1; }

# TEAMS_APP_ID が未指定なら新規採番
if [[ -z "$TEAMS_APP_ID" ]]; then
    if command -v uuidgen >/dev/null 2>&1; then
        TEAMS_APP_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    else
        # uuidgen がない環境では python の uuid モジュールにフォールバック
        TEAMS_APP_ID="$(python -c 'import uuid;print(uuid.uuid4())')"
    fi
    echo "TEAMS_APP_ID を新規生成しました: $TEAMS_APP_ID"
    echo "再ビルド時はこの値を --teams-app-id で渡してください。"
fi

mkdir -p "$OUTPUT_DIR"
MANIFEST_OUT="$OUTPUT_DIR/manifest.json"

# テンプレート → プレースホルダ置換 → developer セクションを jq で書き換え
# sed で文字列置換、その後に jq でオブジェクトプロパティを安全に更新する
sed \
    -e "s|{{TEAMS_APP_ID}}|$TEAMS_APP_ID|g" \
    -e "s|{{BOT_APP_ID}}|$BOT_APP_ID|g" \
    -e "s|{{BFF_APP_HOSTNAME}}|$BFF_HOSTNAME|g" \
    "$TEMPLATE_PATH" \
| jq \
    --arg name "$DEVELOPER_NAME" \
    --arg website "$WEBSITE_URL" \
    --arg privacy "$PRIVACY_URL" \
    --arg terms "$TERMS_OF_USE_URL" \
    '.developer.name = $name
     | .developer.websiteUrl = $website
     | .developer.privacyUrl = $privacy
     | .developer.termsOfUseUrl = $terms' \
> "$MANIFEST_OUT"

# アイコンをコピー
cp -f "$COLOR_ICON"   "$OUTPUT_DIR/color.png"
cp -f "$OUTLINE_ICON" "$OUTPUT_DIR/outline.png"

# Teams アプリパッケージを作成 (manifest と PNG をルート直下に格納)
ZIP_PATH="$OUTPUT_DIR/teams-app.zip"
rm -f "$ZIP_PATH"
( cd "$OUTPUT_DIR" && zip -q "$ZIP_PATH" manifest.json color.png outline.png )

cat <<EOF

Teams アプリパッケージを生成しました:
  $ZIP_PATH

TEAMS_APP_ID = $TEAMS_APP_ID
BOT_APP_ID   = $BOT_APP_ID
BFF_HOST     = $BFF_HOSTNAME
EOF
