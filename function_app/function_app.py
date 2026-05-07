import base64
import json
import logging
import os
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional
from urllib.parse import quote, urlparse

import azure.functions as func
import jwt
import requests
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobSasPermissions, BlobServiceClient, ContentSettings, generate_blob_sas
from azure.storage.queue import QueueClient


# Foundry Agent から呼ばれる OpenAPI ツールと、非同期処理を行うキュー Worker を同一 Function App で提供する。
# HTTP トリガーは Functions レベルでは匿名、コード内で Foundry MI の Bearer トークンを検証する。
# キュートリガーはストレージ接続を Managed Identity で行う。
app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
logger = logging.getLogger(__name__)
credential = DefaultAzureCredential()


def env(name: str, default: Optional[str] = None) -> str:
    # 必須の App Settings を取得。未設定なら起動時にエラーを出す
    value = os.getenv(name, default)
    if value is None or value == "":
        raise RuntimeError(f"Missing required app setting: {name}")
    return value


# ストレージ / キュー / Speech / Foundry / 認証関連の設定値
STORAGE_ACCOUNT_NAME = env("STORAGE_ACCOUNT_NAME")
WORK_QUEUE_NAME = os.getenv("WORK_QUEUE_NAME", "work-items")
OUTPUT_CONTAINER = os.getenv("OUTPUT_CONTAINER", "output")
JOBS_CONTAINER = os.getenv("JOBS_CONTAINER", "jobs")
SPEECH_ENDPOINT = env("SPEECH_ENDPOINT").rstrip("/")
SPEECH_API_VERSION = os.getenv("SPEECH_API_VERSION", "2025-10-15")
DEFAULT_LOCALE = os.getenv("DEFAULT_LOCALE", "ja-JP")
FOUNDRY_PROJECT_ENDPOINT = env("FOUNDRY_PROJECT_ENDPOINT")
FOUNDRY_MODEL_DEPLOYMENT_NAME = env("FOUNDRY_MODEL_DEPLOYMENT_NAME")
# 后処理 Agent 名。Foundry に作成済みの Agent を指定し、要約・議事録化・翻訳などの後処理をさせる
FOUNDRY_POSTPROCESS_AGENT_NAME = os.getenv("FOUNDRY_POSTPROCESS_AGENT_NAME", "teams-postprocess-agent")
MAX_CHECK_ATTEMPTS = int(os.getenv("MAX_CHECK_ATTEMPTS", "96"))
FOUNDRY_ALLOWED_APP_ID = os.getenv("FOUNDRY_ALLOWED_APP_ID", "")
FUNCTION_TOOL_AUDIENCE = env("FUNCTION_TOOL_AUDIENCE")
FUNCTION_TOOL_REQUIRED_ROLE = os.getenv("FUNCTION_TOOL_REQUIRED_ROLE", "FunctionTool.Invoke")
TENANT_ID = env("MicrosoftAppTenantId")
BFF_INTERNAL_BASE_URL = env("BFF_INTERNAL_BASE_URL").rstrip("/")
BFF_INTERNAL_AUDIENCE = env("BFF_INTERNAL_AUDIENCE")
MAX_TEAMS_MESSAGE_CHARS = int(os.getenv("MAX_TEAMS_MESSAGE_CHARS", "25000"))


def now_utc_iso() -> str:
    # ジョブレコードのタイムスタンプを ISO8601 (UTC) で返す
    return datetime.now(timezone.utc).isoformat()


def json_response(body: Dict[str, Any], status_code: int = 200) -> func.HttpResponse:
    # JSON レスポンスを返すヘルパー
    return func.HttpResponse(
        json.dumps(body, ensure_ascii=False),
        status_code=status_code,
        mimetype="application/json",
    )


def blob_service() -> BlobServiceClient:
    # Managed Identity で Blob Storage クライアントを生成
    return BlobServiceClient(
        account_url=f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net",
        credential=credential,
    )


def queue_client() -> QueueClient:
    # ジョブキューへの送信用クライアント。同じストレージアカウントのキューを使う
    return QueueClient(
        account_url=f"https://{STORAGE_ACCOUNT_NAME}.queue.core.windows.net",
        queue_name=WORK_QUEUE_NAME,
        credential=credential,
    )


def foundry_openai_client():
    # 後処理で Foundry モデルを呼ぶための OpenAI 互換クライアント
    project = AIProjectClient(endpoint=FOUNDRY_PROJECT_ENDPOINT, credential=credential)
    return project.get_openai_client()


def upload_json(container: str, name: str, data: Dict[str, Any]) -> str:
    # ジョブレコードなどの JSON を Blob に保存する
    client = blob_service().get_blob_client(container=container, blob=name)
    client.upload_blob(
        json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8"),
        overwrite=True,
        content_settings=ContentSettings(content_type="application/json; charset=utf-8"),
    )
    return client.url


def download_json(container: str, name: str) -> Dict[str, Any]:
    # Blob から JSON を取得
    client = blob_service().get_blob_client(container=container, blob=name)
    return json.loads(client.download_blob().readall().decode("utf-8"))


def upload_text(container: str, name: str, text: str, content_type: str = "text/plain; charset=utf-8") -> str:
    # テキスト（文字起こし結果や Markdown レポート）を Blob に保存する
    client = blob_service().get_blob_client(container=container, blob=name)
    client.upload_blob(
        text.encode("utf-8"),
        overwrite=True,
        content_settings=ContentSettings(content_type=content_type),
    )
    return client.url


def download_text_from_blob_url(blob_url: str) -> str:
    # 同一ストレージアカウントの Blob URL からテキストをダウンロードする
    prefix = f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net/"
    if not blob_url.startswith(prefix):
        raise ValueError("Only same-storage blob URLs are supported.")
    path = blob_url[len(prefix):]
    container, blob_name = path.split("/", 1)
    blob = blob_service().get_blob_client(container=container, blob=blob_name)
    return blob.download_blob().readall().decode("utf-8", errors="replace")


def enqueue(item: Dict[str, Any], delay_seconds: int = 0) -> None:
    # キューへジョブ項目を送信。delay_seconds で可視性を遅らせ、ポーリング間隔を表現する
    queue_client().send_message(
        json.dumps(item, ensure_ascii=False),
        visibility_timeout=max(0, int(delay_seconds)),
        time_to_live=7 * 24 * 60 * 60,
    )


def backoff_seconds(attempt: int) -> int:
    # Speech ジョブ状態確認の指数バックオフ（2分 → 5分 → 10分 → 15分）
    if attempt <= 1:
        return 120
    if attempt == 2:
        return 300
    if attempt == 3:
        return 600
    return 900


def decode_queue_message(msg: func.QueueMessage) -> Dict[str, Any]:
    # キューメッセージを JSON としてデコード。Base64 エンコードされているケースにも対応
    raw = msg.get_body().decode("utf-8")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return json.loads(base64.b64decode(raw).decode("utf-8"))


def validate_foundry_bearer(req: func.HttpRequest) -> Optional[func.HttpResponse]:
    """Validate Foundry managed-identity token for OpenAPI tool endpoint."""
    # Foundry リソースの Managed Identity から認証された要求かを検証する
    if not FOUNDRY_ALLOWED_APP_ID:
        logger.warning("FOUNDRY_ALLOWED_APP_ID is not set. Skipping tool endpoint token validation.")
        return None

    auth = req.headers.get("Authorization", "")
    if not auth.lower().startswith("bearer "):
        return json_response({"ok": False, "error": "Missing bearer token."}, 401)

    token = auth.split(" ", 1)[1]
    try:
        # Entra の JWKS で署名を検証し、audience を Function Tool API に限定する
        jwks_url = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"
        signing_key = jwt.PyJWKClient(jwks_url).get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            audience=FUNCTION_TOOL_AUDIENCE,
            options={"verify_iss": False},
        )
        # テナント、呼び出し元 appId、アプリロールを順にチェック
        if claims.get("tid") != TENANT_ID:
            return json_response({"ok": False, "error": "Invalid tenant."}, 403)

        caller_app_id = claims.get("appid") or claims.get("azp") or claims.get("client_id")
        if caller_app_id != FOUNDRY_ALLOWED_APP_ID:
            return json_response({"ok": False, "error": "Caller is not the allowed Foundry managed identity."}, 403)

        roles = claims.get("roles") or []
        if FUNCTION_TOOL_REQUIRED_ROLE and FUNCTION_TOOL_REQUIRED_ROLE not in roles:
            return json_response({"ok": False, "error": "Required app role is missing."}, 403)
    except Exception as exc:
        logger.exception("Bearer token validation failed")
        return json_response({"ok": False, "error": f"Invalid bearer token: {exc}"}, 401)

    return None


def is_audio_or_video(file_ref: Dict[str, Any]) -> bool:
    # ファイルが Speech で文字起こし可能な音声／動画として扱えるか判定
    ct = (file_ref.get("content_type") or "").lower()
    name = (file_ref.get("name") or "").lower()
    return ct.startswith("audio/") or ct.startswith("video/") or name.endswith(
        (".wav", ".mp3", ".m4a", ".mp4", ".aac", ".ogg", ".webm", ".wma")
    )


def is_plain_text(file_ref: Dict[str, Any]) -> bool:
    # テキスト系ファイルか判定し、そのままモデルに渡せるかを判断
    ct = (file_ref.get("content_type") or "").lower()
    name = (file_ref.get("name") or "").lower()
    return ct.startswith("text/") or name.endswith((".txt", ".md", ".csv", ".json", ".log"))


def speech_token() -> str:
    # Speech リソースへ Entra 認証するためのアクセストークンを取得
    return credential.get_token("https://cognitiveservices.azure.com/.default").token


def build_blob_sas_url(blob_url: str, validity_hours: int = 6) -> str:
    """Blob URL に User Delegation SAS を付加して Speech Batch から取得可能な URL を返す。

    Storage アカウントが Shared Key 無効・パブリックアクセス無効でも、UAMI で取得した
    User Delegation Key を使えば SAS を発行できる。Speech Batch の contentUrls は
    認証ヘッダーを付けずに blob を取得するため SAS が必要。
    """
    parsed = urlparse(blob_url)
    # https://<account>.blob.core.windows.net/<container>/<blob...>
    account = parsed.netloc.split(".")[0]
    parts = parsed.path.lstrip("/").split("/", 1)
    if len(parts) != 2:
        return blob_url
    container, blob_name = parts

    now = datetime.now(timezone.utc)
    udk = blob_service().get_user_delegation_key(
        key_start_time=now - timedelta(minutes=5),
        key_expiry_time=now + timedelta(hours=validity_hours),
    )
    sas = generate_blob_sas(
        account_name=account,
        container_name=container,
        blob_name=blob_name,
        user_delegation_key=udk,
        permission=BlobSasPermissions(read=True),
        start=now - timedelta(minutes=5),
        expiry=now + timedelta(hours=validity_hours),
    )
    return f"{blob_url}?{sas}"


def speech_headers() -> Dict[str, str]:
    # Speech REST API 要求用の Authorization ヘッダー
    return {
        "Authorization": f"Bearer {speech_token()}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


def parse_transcription_id(url: str) -> Optional[str]:
    # transcription リソース URL から ID 部分を抽出
    match = re.search(r"/transcriptions/([^/?]+)", url or "")
    return match.group(1) if match else None


def submit_speech_batch(audio_urls: List[str], display_name: str) -> Dict[str, Any]:
    # Azure AI Speech の Batch Transcription を起動する。Entra 認証にはカスタムサブドメインが必須
    if ".api.cognitive.microsoft.com" in SPEECH_ENDPOINT:
        raise RuntimeError("SPEECH_ENDPOINT must be a custom-subdomain endpoint for Entra authentication.")

    url = f"{SPEECH_ENDPOINT}/speechtotext/transcriptions:submit?api-version={SPEECH_API_VERSION}"
    body = {
        "displayName": display_name,
        "locale": DEFAULT_LOCALE,
        "contentUrls": audio_urls,
        "properties": {
            "timeToLiveHours": 48,
            # diarization は mono 入力前提。channels=[0] を明示してステレオ MP3 でも安全に動作させる
            # （channels を省略するとデフォルトで [0, 1] になり、ステレオファイルで InvalidData となる）
            "channels": [0],
            "diarization": {"enabled": True, "maxSpeakers": 8},
            "punctuationMode": "DictatedAndAutomatic",
            "profanityFilterMode": "Masked",
        },
    }
    resp = requests.post(url, headers=speech_headers(), json=body, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    # 起動レスポンスまたは Location ヘッダーから transcription_id を抽出
    data["transcription_id"] = parse_transcription_id(data.get("self")) or parse_transcription_id(resp.headers.get("Location"))
    return data


def get_speech_status(transcription_id: str) -> Dict[str, Any]:
    # Speech ジョブの現在のステータスを取得
    url = f"{SPEECH_ENDPOINT}/speechtotext/transcriptions/{quote(transcription_id, safe='')}?api-version={SPEECH_API_VERSION}"
    resp = requests.get(url, headers=speech_headers(), timeout=30)
    resp.raise_for_status()
    return resp.json()


def list_speech_files(transcription_id: str) -> Dict[str, Any]:
    # 完了したジョブの出力ファイル一覧を取得
    url = f"{SPEECH_ENDPOINT}/speechtotext/transcriptions/{quote(transcription_id, safe='')}/files?api-version={SPEECH_API_VERSION}"
    resp = requests.get(url, headers=speech_headers(), timeout=30)
    resp.raise_for_status()
    return resp.json()


def download_transcript(transcription_id: str) -> str:
    # Transcription ファイルを集約し、display テキストを連結して返す
    files = list_speech_files(transcription_id)
    parts: List[str] = []
    for f in files.get("values") or []:
        if f.get("kind") != "Transcription":
            continue
        content_url = (f.get("links") or {}).get("contentUrl")
        if not content_url:
            continue
        result = requests.get(content_url, timeout=120)
        result.raise_for_status()
        data = result.json()
        for phrase in data.get("combinedRecognizedPhrases", []) or []:
            display = phrase.get("display")
            if display:
                parts.append(display)
    return "\n".join(parts).strip()


def call_foundry_model(prompt: str) -> str:
    # 互換用のモデル直呼び。現状未使用だがデバッグやフォールバック用に残す
    response = foundry_openai_client().responses.create(
        model=FOUNDRY_MODEL_DEPLOYMENT_NAME,
        input=prompt,
    )
    return getattr(response, "output_text", "") or ""


def call_postprocess_agent(task_type: str, instruction: str, input_text: str) -> str:
    # Foundry 上の后処理 Agent を responses API の agent_reference で呼び出し、
    # task_type / instruction / input_text を JSON として渡す。
    payload = {
        "task_type": task_type,
        "instruction": instruction,
        "input_text": input_text[:120000],
    }
    user_input = json.dumps(payload, ensure_ascii=False)
    response = foundry_openai_client().responses.create(
        input=user_input,
        extra_body={
            "agent_reference": {
                "name": FOUNDRY_POSTPROCESS_AGENT_NAME,
                "type": "agent_reference",
            }
        },
    )
    return getattr(response, "output_text", "") or ""


def token_scope(audience: str) -> str:
    # アプリケーションフォークン取得で使う .default スコープを生成
    return audience.rstrip("/") + "/.default"


def bff_internal_headers() -> Dict[str, str]:
    # BFF 内部コールバック用の Bearer トークン（UAMI で取得）を付けたヘッダー
    token = credential.get_token(token_scope(BFF_INTERNAL_AUDIENCE)).token
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


def notify_bff_complete(item: Dict[str, Any], result_text: str) -> None:
    # ジョブ完了を BFF に通知。BFF が Teams へプロアクティブ送信する
    job_id = item["job_id"]
    url = f"{BFF_INTERNAL_BASE_URL}/internal/jobs/{job_id}/complete"
    payload = {
        "job_id": job_id,
        "reply_ref_id": item["reply_ref_id"],
        "result_text": result_text[:MAX_TEAMS_MESSAGE_CHARS],
        "result_url": item.get("result_url"),
        "transcript_url": item.get("transcript_url"),
        "state": item.get("state"),
    }
    resp = requests.post(url, headers=bff_internal_headers(), json=payload, timeout=60)
    resp.raise_for_status()


def notify_bff_failed(item: Dict[str, Any], error: str) -> None:
    # ジョブ失敗を BFF に通知。reply_ref_id がない場合は通知をスキップ
    if not item.get("reply_ref_id"):
        return
    job_id = item.get("job_id", "unknown")
    url = f"{BFF_INTERNAL_BASE_URL}/internal/jobs/{job_id}/failed"
    payload = {
        "job_id": job_id,
        "reply_ref_id": item["reply_ref_id"],
        "error": error,
    }
    resp = requests.post(url, headers=bff_internal_headers(), json=payload, timeout=60)
    resp.raise_for_status()


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    # ヘルスチェックエンドポイント
    return json_response({"ok": True, "service": "function-tool-and-worker"})


@app.route(route="tools/create_work_item", methods=["POST"])
def create_work_item(req: func.HttpRequest) -> func.HttpResponse:
    """Foundry Agent OpenAPI Tool endpoint. Hosted in Azure Functions."""
    # Foundry Agent から呼ばれるツールエンドポイント。ジョブをキューにエンキューして即時 202 を返す
    auth_error = validate_foundry_bearer(req)
    if auth_error:
        return auth_error

    try:
        payload = req.get_json()
        # job_id が未指定ならタイムスタンプベースで生成
        job_id = payload.get("job_id") or "job-" + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        reply_ref_id = payload.get("reply_ref_id")

        if not reply_ref_id:
            return json_response({"ok": False, "error": "reply_ref_id is required."}, 400)

        # ジョブレコードを初期状態で Blob に保存し、キューにエンキュー
        item = {
            "job_id": job_id,
            "state": "new",
            "task_type": payload.get("task_type", "mixed"),
            "instruction": payload.get("instruction", ""),
            "file_refs": payload.get("file_refs", []),
            "reply_ref_id": reply_ref_id,
            "attempt": 0,
            "created_at": now_utc_iso(),
            "updated_at": now_utc_iso(),
        }
        upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
        enqueue(item)

        return json_response(
            {
                "ok": True,
                "job_id": job_id,
                "message": "Work item queued. Do not poll from the agent. The worker will notify BFF when complete.",
            },
            202,
        )
    except Exception as exc:
        logger.exception("Failed to create work item")
        return json_response({"ok": False, "error": str(exc)}, 500)


@app.queue_trigger(arg_name="msg", queue_name="%WORK_QUEUE_NAME%", connection="WORK_STORAGE")
def process_work_item(msg: func.QueueMessage) -> None:
    # 非同期 Worker 本体。ステートマシンとしてジョブを進める
    item = decode_queue_message(msg)
    job_id = item["job_id"]
    state = item.get("state", "new")
    logger.info("Processing job_id=%s state=%s", job_id, state)

    try:
        # state によって処理を分岐: 初期処理 / Speech 状態確認 / 後処理
        if state == "new":
            handle_new(item)
        elif state == "speech_check":
            handle_speech_check(item)
        elif state == "postprocess":
            handle_postprocess(item)
        else:
            raise ValueError(f"Unknown state: {state}")
    except Exception as exc:
        # 例外時は失敗状態で保存し、BFF に失敗を通知して Teams へ返信させる
        logger.exception("Job failed")
        item["state"] = "failed"
        item["error"] = str(exc)
        item["updated_at"] = now_utc_iso()
        upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
        notify_bff_failed(item, str(exc))


def handle_new(item: Dict[str, Any]) -> None:
    # 初回処理: 音声/動画は Speech を起動し、テキストはそのまま後処理へ進む
    job_id = item["job_id"]
    file_refs = item.get("file_refs") or []
    audio_refs = [f for f in file_refs if is_audio_or_video(f)]
    text_refs = [f for f in file_refs if is_plain_text(f)]

    if audio_refs:
        # Speech Batch を起動し、speech_check 状態でキューを遅延エンキュー
        # Storage が Shared Key 無効ポリシーでもアクセスできるよう、User Delegation SAS を付加した URL を渡す
        signed_urls = [build_blob_sas_url(f["blob_url"]) for f in audio_refs]
        speech = submit_speech_batch(signed_urls, f"teams-job-{job_id}")
        item.update({
            "state": "speech_check",
            "speech_transcription_id": speech["transcription_id"],
            "speech_status": speech.get("status"),
            "attempt": 1,
            "updated_at": now_utc_iso(),
        })
        upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
        enqueue(item, delay_seconds=backoff_seconds(1))
        return

    if text_refs:
        # テキストファイルは中身を読んで input_text に集約
        texts = []
        for ref in text_refs:
            texts.append(f"# File: {ref.get('name')}\n{download_text_from_blob_url(ref['blob_url'])}")
        item["input_text"] = "\n\n".join(texts)
        item["state"] = "postprocess"
        upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
        enqueue(item)
        return

    # ファイルがない場合も後処理へ進める（指示文だけでモデルに含める）
    item["input_text"] = ""
    item["state"] = "postprocess"
    upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
    enqueue(item)


def handle_speech_check(item: Dict[str, Any]) -> None:
    # Speech ジョブの状態を確認し、完了 / 失敗 / 継続を判断
    job_id = item["job_id"]
    attempt = int(item.get("attempt", 1))
    transcription_id = item["speech_transcription_id"]
    status_payload = get_speech_status(transcription_id)
    status = status_payload.get("status")

    item["speech_status"] = status
    item["updated_at"] = now_utc_iso()

    if status == "Succeeded":
        # 文字起こし結果をダウンロードして出力コンテナに保存し、後処理へ進む
        transcript = download_transcript(transcription_id)
        transcript_url = upload_text(OUTPUT_CONTAINER, f"{job_id}/transcript.txt", transcript)
        item["transcript_url"] = transcript_url
        item["input_text"] = transcript
        item["state"] = "postprocess"
        item["attempt"] = 0
        upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
        enqueue(item)
        return

    if status in ("Failed", "Cancelled"):
        # Speech 側で失敗した場合は BFF に失敗を通知
        item["state"] = "failed"
        item["error"] = json.dumps(status_payload, ensure_ascii=False)
        upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
        # Speech から返されたエラー詳細をユーザー向けメッセージに含める
        speech_err = ((status_payload.get("properties") or {}).get("error") or {})
        err_code = speech_err.get("code") or status
        err_msg = speech_err.get("message") or ""
        user_msg = f"Speech 文字起こしに失敗しました。({err_code}: {err_msg})" if err_msg else "Speech 文字起こしに失敗しました。"
        logger.error("Speech transcription failed job=%s code=%s message=%s", job_id, err_code, err_msg)
        notify_bff_failed(item, user_msg)
        return

    if attempt >= MAX_CHECK_ATTEMPTS:
        # 試行回数上限でタイムアウトとして扱う
        item["state"] = "timeout"
        item["error"] = "Max speech check attempts exceeded."
        upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
        notify_bff_failed(item, "処理がタイムアウトしました。")
        return

    # さらに待機して再度ステータス確認ジョブをキューにエンキュー
    item["attempt"] = attempt + 1
    upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
    enqueue(item, delay_seconds=backoff_seconds(item["attempt"]))


def handle_postprocess(item: Dict[str, Any]) -> None:
    # 後処理: task_type によって后処理 Agent を呼ぶか、トランスクリプトをそのまま返すかを判断し、
    # 結果を BFF に通知する
    job_id = item["job_id"]
    task_type = (item.get("task_type") or "mixed").lower()
    instruction = item.get("instruction", "")
    input_text = item.get("input_text", "")

    if task_type == "transcribe_only":
        # ユーザー指示が「テキスト化のみ」なら后処理 Agent を呼ばず、トランスクリプトをそのまま結果とする
        result = input_text
        # transcript_url がすでにあるため result_url は生成しない
        item["state"] = "completed"
        item["completed_at"] = now_utc_iso()
        item["updated_at"] = now_utc_iso()
        upload_json(JOBS_CONTAINER, f"{job_id}.json", item)
        notify_bff_complete(item, result)
        return

    # それ以外 (transcribe_and_report / summarize / translate / mixed) は后処理 Agent に委ねる
    result = call_postprocess_agent(task_type, instruction, input_text)
    # 結果を Markdown として出力コンテナに保存
    result_url = upload_text(OUTPUT_CONTAINER, f"{job_id}/result.md", result, "text/markdown; charset=utf-8")

    item["state"] = "completed"
    item["result_url"] = result_url
    item["completed_at"] = now_utc_iso()
    item["updated_at"] = now_utc_iso()
    upload_json(JOBS_CONTAINER, f"{job_id}.json", item)

    # BFF に完了を通知し、Teams への応答を依頼
    notify_bff_complete(item, result)
