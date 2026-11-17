#!/usr/bin/env python3
"""Codex UserPromptSubmit hook: remind once at each conversation length threshold.

Reads only the tail of the current transcript and stores only threshold flags.
Any failure is silent so a prompt is never blocked by this reminder.
"""

import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path


THRESHOLDS = (250_000, 300_000)
TAIL_BYTES = 2_000_000
STATE_DIR = Path.home() / ".codex" / "hook-state" / "long-conversation"


def context_tokens(path):
    """Return the latest Codex input token count, including cached input."""
    with open(path, "rb") as transcript:
        transcript.seek(0, os.SEEK_END)
        transcript.seek(max(0, transcript.tell() - TAIL_BYTES))
        lines = transcript.read().decode("utf-8", "replace").splitlines()

    for line in reversed(lines):
        if '"token_count"' not in line:
            continue
        try:
            entry = json.loads(line)
            payload = entry.get("payload") or {}
            if entry.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            usage = (payload.get("info") or {}).get("last_token_usage") or {}
            tokens = usage.get("input_tokens")
            if isinstance(tokens, (int, float)) and not isinstance(tokens, bool) and tokens > 0:
                return int(tokens)
        except (TypeError, ValueError, AttributeError):
            continue
    return 0


def save_reminded(path, reminded):
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".reminder-", dir=STATE_DIR)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as state:
            json.dump(sorted(reminded), state)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    event = json.load(sys.stdin)
    session_id = event.get("session_id")
    transcript_path = event.get("transcript_path")
    if not session_id or not transcript_path or not os.path.isfile(transcript_path):
        return

    tokens = context_tokens(transcript_path)
    level = max((limit for limit in THRESHOLDS if tokens >= limit), default=0)
    if not level:
        return

    state_name = hashlib.sha256(session_id.encode("utf-8")).hexdigest() + ".json"
    state_path = STATE_DIR / state_name
    try:
        reminded = set(json.loads(state_path.read_text(encoding="utf-8")))
    except (OSError, ValueError, TypeError):
        reminded = set()
    if level in reminded:
        return

    reminded.update(limit for limit in THRESHOLDS if limit <= level)
    save_reminded(state_path, reminded)

    amount = f"{tokens / 10_000:.1f}"
    if level == 300_000:
        message = (f"⚠️ 這段 Codex 對話的目前上下文約 {amount} 萬 token。"
                   "若工作已到一個段落，請先更新專案進度與交接，再考慮開新對話接續。"
                   "Codex 可能已自動整理上下文，不需要立即中斷工作。")
    else:
        message = (f"💡 這段 Codex 對話的目前上下文約 {amount} 萬 token。"
                   "找個段落整理進度；若後續回覆開始遺漏重要決策，再考慮開新對話。")
    print(json.dumps({"systemMessage": message}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
