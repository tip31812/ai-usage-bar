#!/usr/bin/env python3
"""Claude Code UserPromptSubmit hook：對話太長時提醒開新對話。

每次送出訊息時讀這段對話的紀錄檔，取最後一次回覆的上下文大小
（input + cache 讀寫 tokens）。超過 30 萬提醒一次；
同一段對話同一個門檻只提醒一次。任何錯誤都安靜結束，不擋使用者送出。
"""
import json
import os
import sys

THRESHOLDS = [
    (300_000, "⚠️ 這段對話已約 {n} 萬 token，每句都會帶著整段內容送出，非常耗額度。"
              "建議現在請 Claude 更新進度與交接，然後開新對話接續。"),
]
STATE_DIR = os.path.expanduser("~/.claude/hook-state/long-conversation")
TAIL_BYTES = 2_000_000


def context_tokens(path):
    """從紀錄檔尾端找最後一筆有 usage 的回覆，回傳上下文 token 數。"""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - TAIL_BYTES))
        lines = f.read().decode("utf-8", "ignore").splitlines()
    for line in reversed(lines):
        if '"usage"' not in line:
            continue
        try:
            msg = json.loads(line).get("message")
        except ValueError:
            continue
        usage = msg.get("usage") if isinstance(msg, dict) else None
        if usage:
            return (usage.get("input_tokens", 0)
                    + usage.get("cache_read_input_tokens", 0)
                    + usage.get("cache_creation_input_tokens", 0))
    return 0


def main():
    data = json.load(sys.stdin)
    path = data.get("transcript_path")
    session = data.get("session_id") or "unknown"
    if not path or not os.path.exists(path):
        return
    tokens = context_tokens(path)

    state_file = os.path.join(STATE_DIR, f"{session}.json")
    try:
        with open(state_file, encoding="utf-8") as f:
            reminded = set(json.load(f))
    except (OSError, ValueError):
        reminded = set()

    for limit, text in THRESHOLDS:
        if tokens < limit:
            continue
        if limit in reminded:
            return
        # 觸發高門檻時，低門檻也算提醒過
        reminded.update(l for l, _ in THRESHOLDS if l <= limit)
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(sorted(reminded), f)
        print(json.dumps({"systemMessage": text.format(n=f"{tokens / 10000:.1f}")}, ensure_ascii=False))
        return


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
