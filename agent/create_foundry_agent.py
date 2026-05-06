import os
from pathlib import Path
from typing import Any, cast

import jsonref
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential


# このスクリプトは Foundry プロジェクトに Teams ルーティング用の Agent を作成/更新する。
# Agent は Azure Functions 上の create_work_item を OpenAPI ツールとして保持する。
PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
MODEL_DEPLOYMENT_NAME = os.environ["FOUNDRY_MODEL_DEPLOYMENT_NAME"]
FUNCTION_TOOL_BASE_URL = os.environ["FUNCTION_TOOL_BASE_URL"].rstrip("/")
FUNCTION_TOOL_AUDIENCE = os.environ["FUNCTION_TOOL_AUDIENCE"]
AGENT_NAME = os.getenv("FOUNDRY_AGENT_NAME", "teams-work-router-agent")


def load_spec() -> dict[str, Any]:
    # OpenAPI スペックを読み込み、Function App の URL プレースホルダを置換する
    raw = Path(__file__).with_name("openapi.tool.json").read_text(encoding="utf-8")
    raw = raw.replace("{{FUNCTION_TOOL_BASE_URL}}", FUNCTION_TOOL_BASE_URL)
    return cast(dict[str, Any], jsonref.loads(raw))


def main() -> None:
    # DefaultAzureCredential で Foundry プロジェクトに接続
    project = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    # OpenAPI ツール定義: Function App の create_work_item を Managed Identity 認証で呼ぶ
    tool = {
        "type": "openapi",
        "openapi": {
            "name": "teams_async_work_items",
            "description": "Azure Functions-hosted tool for creating asynchronous Teams file and long-running tasks.",
            "spec": load_spec(),
            "auth": {
                "type": "managed_identity",
                "security_scheme": {"audience": FUNCTION_TOOL_AUDIENCE},
            },
        },
    }

    # Agent への指示文。ポーリング禁止、Teams 通知は BFF で実施などのルールを明示する。
    # task_type の値を明示し、Functions 側の後処理スキップ判断に使う。
    instructions = """
You are a Teams routing agent for an enterprise assistant.

Responsibilities:
- Interpret natural-language Teams messages and attached file references.
- Answer directly only for short no-file chat tasks or short inline translation.
- For any attached file processing, long-running transcription, translation/report generation over files, or multi-step work, call create_work_item exactly once.
- The create_work_item tool is hosted by Azure Functions.
- Never poll job status. Never fetch results. Never wait for Speech transcription completion.
- Teams notification is handled by the BFF after the Function worker calls its internal callback.
- When creating work, include task_type, instruction, file_refs, reply_ref_id, and job_id if provided.
- Tell the user that the work was accepted and that Teams will receive a completion message.

task_type values (choose exactly one):
- "transcribe_only": user wants only the raw transcription text of audio/video. No summarization, no report, no translation requested.
- "transcribe_and_report": user wants the transcription PLUS a meeting report / minutes (decisions, TODOs, key points).
- "summarize": user wants a summary of attached text/audio.
- "translate": user wants translation of the file content.
- "mixed": multiple or unclear post-processing requests; let the post-process agent interpret the instruction.

Rules for choosing task_type:
- If the user request is purely transcription with no further processing (e.g. 「テキスト化して」「文字起こしして」「transcribe」only), use "transcribe_only".
- If the user mentions report / minutes / 要点 / 議事録 / 決定事項 alongside transcription, use "transcribe_and_report".
- If the user explicitly asks for translation only, use "translate".
- If the user explicitly asks for summary only, use "summarize".
- Otherwise use "mixed".
- Always set "instruction" to the user's original natural-language request so the post-process agent can act on it.
""".strip()

    # 同名の Agent があれば新しいバージョンを作成、なければ新規作成される
    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=MODEL_DEPLOYMENT_NAME,
            instructions=instructions,
            tools=[tool],
        ),
    )
    print(f"Created/updated agent version: name={agent.name}, version={agent.version}")


if __name__ == "__main__":
    main()
