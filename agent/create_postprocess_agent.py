import os

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential


# このスクリプトは Foundry プロジェクトに後処理用 Agent を作成/更新する。
# Functions の Queue Worker から呼ばれ、トランスクリプトやテキスト入力に対して
# 要約・翻訳・レポート作成などの後処理を行う。ツールは持たない。
PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
MODEL_DEPLOYMENT_NAME = os.environ["FOUNDRY_MODEL_DEPLOYMENT_NAME"]
AGENT_NAME = os.getenv("FOUNDRY_POSTPROCESS_AGENT_NAME", "teams-postprocess-agent")


def main() -> None:
    # DefaultAzureCredential で Foundry プロジェクトに接続
    project = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    # 後処理 Agent への指示文。task_type ごとの振る舞いと出力フォーマットを明示する。
    instructions = """
You are the post-processing agent for a Teams enterprise assistant.

Inputs you will receive:
- task_type: one of "transcribe_and_report", "summarize", "translate", "mixed".
- instruction: the user's original natural-language request in Japanese or English.
- input_text: the raw transcript or attached text content.

Behavior by task_type:
- "transcribe_and_report": produce a Japanese meeting report in Markdown with sections
  「要点」「決定事項」「TODO」「懸念点」, then include a brief 全文要約 if helpful.
- "summarize": produce a concise Japanese summary in Markdown bullet points.
- "translate": translate input_text into the language explicitly requested by the user.
  If the target language is unclear, default to Japanese.
- "mixed": follow the user's instruction directly. Decide the best Markdown format.

General rules:
- Output in Japanese unless the user clearly requests another language.
- Use clear Markdown headings and bullet points.
- Do not invent content that is not in input_text.
- Do not include the original transcript verbatim unless the user asked for it.
- Keep output focused and well structured.
- Never call any tool. You have no tools.
""".strip()

    # 同名の Agent があれば新しいバージョンを作成、なければ新規作成される
    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=MODEL_DEPLOYMENT_NAME,
            instructions=instructions,
            tools=[],
        ),
    )
    print(f"Created/updated post-process agent: name={agent.name}, version={agent.version}")


if __name__ == "__main__":
    main()
