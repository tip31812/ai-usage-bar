#!/bin/zsh
# 移除 AI額度看板 / Uninstall AI Usage Bar
set -u
launchctl bootout "gui/$(id -u)/app.tipstudio.quotabar" 2>/dev/null || true
pkill -x QuotaBar 2>/dev/null || true
rm -rf /Applications/AI額度看板.app
rm -f ~/Library/LaunchAgents/app.tipstudio.quotabar.plist
rm -rf ~/Library/Caches/app.tipstudio.quotabar
rm -f ~/Library/Logs/AI額度看板.log
defaults delete app.tipstudio.quotabar 2>/dev/null || true
echo "已移除 App、開機啟動設定、快取與記錄檔。 / App, login agent, cache and log removed."
echo
echo "如果你有加對話提醒 hook，請手動從這兩個檔案刪掉對應段落（本腳本不會改你的設定）："
echo "If you added the chat-length hooks, remove them yourself (this script never edits your config):"
echo "  ~/.claude/settings.json   (UserPromptSubmit → long_conversation_reminder.py)"
echo "  ~/.codex/hooks.json       (UserPromptSubmit → codex_long_conversation_reminder.py)"
echo "  ~/.claude/hook-state/long-conversation/  ~/.codex/hook-state/long-conversation/  (optional state)"
