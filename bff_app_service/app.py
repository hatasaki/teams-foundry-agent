import json
import logging
import mimetypes
import os
import re
import uuid
from typing import Any, Dict, List, Optional

import jwt
import requests
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings
from botbuilder.core import TurnContext
from botbuilder.integration.aiohttp import CloudAdapter, ConfigurationBotFrameworkAuthentication
from botbuilder.schema import Activity, ActivityTypes, ConversationReference
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, PlainTextResponse


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("teams-foundry-bff")

# Teams からのメッセージと Function Worker からの内部コールバックを受ける BFF アプリ
app = FastAPI(title="Teams Foundry BFF", version="1.1.0")


def env(name: str, default: Optional[str] = None) -> str:
    # 必須環境変数を取得するヘルパー。未設定なら起動時にエラーを出す
    value = os.getenv(name, default)
    if value is None or value == "":
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


# App Service BFF の設定値（ボット、ストレージ、Foundry、内部コールバック認証関連）
BOT_APP_ID = env("MicrosoftAppId")
TENANT_ID = env("MicrosoftAppTenantId")
STORAGE_ACCOUNT_NAME = env("STORAGE_ACCOUNT_NAME")
INPUT_CONTAINER = os.getenv("INPUT_CONTAINER", "input")
CONVERSATIONS_CONTAINER = os.getenv("CONVERSATIONS_CONTAINER", "conversation-refs")
FOUNDRY_PROJECT_ENDPOINT = env("FOUNDRY_PROJECT_ENDPOINT")
FOUNDRY_AGENT_NAME = env("FOUNDRY_AGENT_NAME")
MAX_TEAMS_MESSAGE_CHARS = int(os.getenv("MAX_TEAMS_MESSAGE_CHARS", "25000"))

# 内部コールバック認証設定。
# BFF_INTERNAL_AUDIENCE は Entra アプリ ID URI（例: api://<bff-internal-api-app-id>）。
BFF_INTERNAL_AUDIENCE = env("BFF_INTERNAL_AUDIENCE")
# Function Worker のマネージド ID の appId。これ以外の呼び出し元は拒否する。
FUNCTION_WORKER_ALLOWED_APP_ID = env("FUNCTION_WORKER_ALLOWED_APP_ID")
# Function Worker に付与されているべきアプリロール名。
BFF_INTERNAL_REQUIRED_ROLE = os.getenv("BFF_INTERNAL_REQUIRED_ROLE", "BffInternal.Callback")

# UAMI / システム割り当て ID を使って Azure サービスへ Entra 認証するための資格情報
credential = DefaultAzureCredential()


class BotConfig:
    # Azure Bot Service は BFF と同じユーザー割り当てマネージド ID を使用する。
    # Bot Framework SDK の ConfigurationServiceClientCredentialFactory は
    # APP_TYPE / APP_ID / APP_PASSWORD / APP_TENANTID 属性を読み取るため、
    # 互換性のため両方の属性名を公開する。
    APP_TYPE = os.getenv("MicrosoftAppType", "UserAssignedMSI")
    APP_ID = BOT_APP_ID
    APP_PASSWORD = os.getenv("MicrosoftAppPassword", "")
    APP_TENANTID = TENANT_ID
    MicrosoftAppType = APP_TYPE
    MicrosoftAppId = APP_ID
    MicrosoftAppPassword = APP_PASSWORD
    MicrosoftAppTenantId = APP_TENANTID


# Bot Framework のアダプタ。Teams からのアクティビティ処理とプロアクティブ送信に利用
ADAPTER = CloudAdapter(ConfigurationBotFrameworkAuthentication(BotConfig()))


async def on_turn_error(context: TurnContext, error: Exception):
    # ターン処理で例外が発生した際の共通ハンドラ。Teams へエラーを返す
    logger.exception("Bot error: %s", error)
    await context.send_activity("処理中にエラーが発生しました。管理者に確認してください。")


ADAPTER.on_turn_error = on_turn_error


def blob_service() -> BlobServiceClient:
    # Managed Identity で Blob Storage にアクセスするクライアントを生成
    return BlobServiceClient(
        account_url=f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net",
        credential=credential,
    )


def foundry_openai_client():
    # Foundry プロジェクト経由で OpenAI 互換クライアントを取得し、Agent を呼び出す
    project = AIProjectClient(endpoint=FOUNDRY_PROJECT_ENDPOINT, credential=credential)
    return project.get_openai_client()


def safe_filename(name: str) -> str:
    # Blob 名に使えるサニタイズされたファイル名を返す
    return re.sub(r"[^a-zA-Z0-9._-]+", "_", name or "file")[:180]


def upload_json(container: str, name: str, data: Dict[str, Any]) -> str:
    # JSON オブジェクトを指定コンテナに UTF-8 でアップロード
    client = blob_service().get_blob_client(container=container, blob=name)
    client.upload_blob(
        json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8"),
        overwrite=True,
        content_settings=ContentSettings(content_type="application/json; charset=utf-8"),
    )
    return client.url


def download_json(container: str, name: str) -> Dict[str, Any]:
    # 保存された JSON オブジェクトをダウンロードしてデコード
    client = blob_service().get_blob_client(container=container, blob=name)
    return json.loads(client.download_blob().readall().decode("utf-8"))


def save_conversation_reference(activity: Activity, reply_ref_id: str) -> str:
    # 後でプロアクティブ送信するために会話参照（ConversationReference）を保存する
    reference = TurnContext.get_conversation_reference(activity)
    return upload_json(CONVERSATIONS_CONTAINER, f"{reply_ref_id}.json", reference.serialize())


async def save_incoming_teams_attachments(activity: Activity, job_id: str) -> List[Dict[str, Any]]:
    """Save Teams incoming files to Blob Storage and return file_refs.

    Personal chat file attachments commonly arrive as:
      contentType == application/vnd.microsoft.teams.file.download.info
      content.downloadUrl == pre-authenticated URL
    """
    # Teams から受信した添付ファイルを Blob に保存し、Agent へ渡す file_refs を返す
    file_refs: List[Dict[str, Any]] = []

    for index, att in enumerate(activity.attachments or []):
        name = safe_filename(att.name or f"attachment-{index}")
        content_type = att.content_type or ""
        download_url = None

        # Teams のファイル添付は事前認証済み URL で渡される
        if content_type == "application/vnd.microsoft.teams.file.download.info":
            content = att.content or {}
            download_url = content.get("downloadUrl") or att.content_url
        elif att.content_url:
            download_url = att.content_url

        if not download_url:
            continue

        # ファイル本体をダウンロード
        resp = requests.get(download_url, timeout=180)
        resp.raise_for_status()

        # Content-Type が不明な場合はファイル名拡張子から推測
        detected_type = resp.headers.get("Content-Type")
        if not detected_type or detected_type == "application/octet-stream":
            detected_type = mimetypes.guess_type(name)[0] or "application/octet-stream"

        # job_id プレフィックス付きで input コンテナに保存
        blob_name = f"{job_id}/{index}-{name}"
        blob = blob_service().get_blob_client(container=INPUT_CONTAINER, blob=blob_name)
        blob.upload_blob(
            resp.content,
            overwrite=True,
            content_settings=ContentSettings(content_type=detected_type),
        )

        file_refs.append(
            {
                "name": name,
                "blob_url": blob.url,
                "content_type": detected_type,
                "size": len(resp.content),
            }
        )

    return file_refs


def build_agent_input(user_text: str, file_refs: List[Dict[str, Any]], reply_ref_id: str, job_id: str) -> str:
    # Foundry Agent へ渡す入力を構築。ルーティング規則をシステムプロンプト代わりに含める
    payload = {
        "user_message": user_text,
        "file_refs": file_refs,
        "reply_ref_id": reply_ref_id,
        "job_id": job_id,
        "rules": [
            "For attached-file processing, transcription, long-running translation, report generation, or multi-step work, call create_work_item exactly once.",
            "Do not poll status. Do not fetch results. Do not wait for transcription completion.",
            "For short no-file chat or short inline translation, answer directly.",
            "The create_work_item tool is hosted by Azure Functions.",
            "Teams notifications are handled only by the BFF internal callback endpoints.",
        ],
    }
    return (
        "You are a Teams BFF routing agent. Decide whether to answer directly or enqueue work.\n"
        "Input JSON:\n"
        f"{json.dumps(payload, ensure_ascii=False, indent=2)}"
    )


def call_foundry_agent(user_text: str, file_refs: List[Dict[str, Any]], reply_ref_id: str, job_id: str) -> str:
    # Foundry Agent を responses API の agent_reference で呼び出し、返答テキストを取得
    client = foundry_openai_client()
    response = client.responses.create(
        input=build_agent_input(user_text, file_refs, reply_ref_id, job_id),
        extra_body={"agent_reference": {"name": FOUNDRY_AGENT_NAME, "type": "agent_reference"}},
    )
    return getattr(response, "output_text", "") or "受付しました。処理を開始します。"


def validate_internal_callback_token(authorization: Optional[str]) -> None:
    # Function Worker からの内部コールバックで送られる Bearer トークンを検証する
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")

    token = authorization.split(" ", 1)[1]
    # Entra の JWKS から署名検証鍵を取得し、トークンの署名と audience を検証
    jwks_url = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"

    try:
        signing_key = jwt.PyJWKClient(jwks_url).get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            audience=BFF_INTERNAL_AUDIENCE,
            options={"verify_iss": False},
        )
    except Exception as exc:
        logger.exception("Invalid internal callback token")
        raise HTTPException(status_code=401, detail=f"Invalid bearer token: {exc}")

    # テナント ID 、呼び出し元 appId、要求アプリロールを順にチェックし、不一致なら 403
    if claims.get("tid") != TENANT_ID:
        raise HTTPException(status_code=403, detail="Invalid tenant")

    caller_app_id = claims.get("appid") or claims.get("azp") or claims.get("client_id")
    if caller_app_id != FUNCTION_WORKER_ALLOWED_APP_ID:
        raise HTTPException(status_code=403, detail="Caller is not the allowed Function managed identity")

    roles = claims.get("roles") or []
    if BFF_INTERNAL_REQUIRED_ROLE and BFF_INTERNAL_REQUIRED_ROLE not in roles:
        raise HTTPException(status_code=403, detail="Required app role is missing")


async def send_teams_message(reply_ref_id: str, text: str):
    # 保存済みの ConversationReference を復元し、Teams にプロアクティブメッセージを送信
    ref_dict = download_json(CONVERSATIONS_CONTAINER, f"{reply_ref_id}.json")
    reference = ConversationReference().deserialize(ref_dict)

    async def callback(turn_context: TurnContext):
        # Teams の 1 メッセージ上限を超えないようトランケートして送信
        await turn_context.send_activity(text[:MAX_TEAMS_MESSAGE_CHARS])

    await ADAPTER.continue_conversation(reference, callback, BOT_APP_ID)


@app.get("/api/health")
async def health():
    # ヘルスチェック用エンドポイント
    return {
        "ok": True,
        "service": "teams-foundry-bff-app-service",
        "agent": FOUNDRY_AGENT_NAME,
    }


@app.post("/api/messages")
async def messages(request: Request, authorization: Optional[str] = Header(default="")):
    """Teams / Azure Bot Service messaging endpoint."""
    # Teams からのアクティビティを受信するエンドポイント
    body = await request.json()
    activity = Activity().deserialize(body)

    async def bot_logic(turn_context: TurnContext):
        # チャットメッセージ以外（参加イベント等）は無視
        if turn_context.activity.type != ActivityTypes.message:
            return

        user_text = (turn_context.activity.text or "").strip()
        # ジョブ ID と返信用参照 ID を生成（会話参照は reply_ref_id で Blob に保存）
        job_id = str(uuid.uuid4())
        reply_ref_id = str(uuid.uuid4())

        # 後のプロアクティブ送信のために会話参照と添付ファイルを保存
        save_conversation_reference(turn_context.activity, reply_ref_id)
        file_refs = await save_incoming_teams_attachments(turn_context.activity, job_id)

        # ユーザーに受付したことを即時返信
        await turn_context.send_activity("ご依頼を受け付けました")

        try:
            # Foundry Agent を呼び出し、直接返信 or ツール起動をルーティングさせる
            agent_reply = call_foundry_agent(user_text, file_refs, reply_ref_id, job_id)
        except Exception as exc:
            logger.exception("Foundry agent call failed")
            await turn_context.send_activity(f"Foundry Agent の呼び出しに失敗しました: {exc}")
            return

        if agent_reply:
            # Agent の返答を Teams に送信（長さ上限を超えないようトランケート）
            await turn_context.send_activity(agent_reply[:MAX_TEAMS_MESSAGE_CHARS])

    # Bot Framework アダプタでアクティビティを処理
    invoke_response = await ADAPTER.process_activity(authorization, activity, bot_logic)
    if invoke_response:
        return JSONResponse(content=invoke_response.body or {}, status_code=invoke_response.status)
    return PlainTextResponse("", status_code=201)


@app.post("/internal/jobs/{job_id}/complete")
async def job_complete(job_id: str, request: Request, authorization: Optional[str] = Header(default=None)):
    """Internal callback from Function worker. Sends Teams proactive completion message."""
    # Function Worker からの完了通知。JWT 検証を必ず実施
    validate_internal_callback_token(authorization)
    payload = await request.json()

    reply_ref_id = payload.get("reply_ref_id")
    if not reply_ref_id:
        raise HTTPException(status_code=400, detail="reply_ref_id is required")

    result_text = payload.get("result_text") or ""
    result_url = payload.get("result_url")
    transcript_url = payload.get("transcript_url")

    # 文字起こし / 処理結果 URL があればユーザへのメッセージに付加
    details = []
    if transcript_url:
        details.append(f"文字起こし保存先: {transcript_url}")
    if result_url:
        details.append(f"結果保存先: {result_url}")

    message = f"ジョブ {job_id} が完了しました。\n\n"
    if details:
        message += "\n".join(details) + "\n\n"
    message += result_text

    # Teams にプロアクティブ送信
    await send_teams_message(reply_ref_id, message)
    return {"ok": True, "job_id": job_id, "notified": True}


@app.post("/internal/jobs/{job_id}/failed")
async def job_failed(job_id: str, request: Request, authorization: Optional[str] = Header(default=None)):
    """Internal callback from Function worker. Sends Teams proactive failure message."""
    # Function Worker からの失敗通知。JWT 検証してから Teams に失敗メッセージを送信
    validate_internal_callback_token(authorization)
    payload = await request.json()

    reply_ref_id = payload.get("reply_ref_id")
    if not reply_ref_id:
        raise HTTPException(status_code=400, detail="reply_ref_id is required")

    error = payload.get("error") or "Unknown error"
    await send_teams_message(reply_ref_id, f"ジョブ {job_id} は失敗しました。\n\n{error}")
    return {"ok": True, "job_id": job_id, "notified": True}
