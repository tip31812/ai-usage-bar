# Instructions for AI assistants / 給 AI 助理的說明

If a user asks you to install this project, run `./build.sh --install` — but first **check and tell the user about these manual steps** (you cannot do them for them). 
若使用者請你安裝此專案，執行 `./build.sh --install` 前，請先檢查並**提醒使用者**以下必須自己處理的步驟：

1. **Mac check / 環境檢查**: Apple Silicon (`uname -m` = `arm64`) and macOS 14+ (`sw_vers`). If not, stop and tell the user it is unsupported. 若不是 Apple Silicon 或 macOS < 14，請停止並告知無法安裝。
2. **Command Line Tools**: check `xcode-select -p` / `which swiftc`. If missing, tell the user to run `xcode-select --install` and click through the pop-up, then wait for them. 沒有就請使用者執行 `xcode-select --install` 並在彈出視窗按確認，等他完成。
3. **CLI login / 登入**: the user must be logged in to Claude Code (`claude auth login`) and/or Codex. Login needs their own browser authorization — never try to do it with an automated browser or enter credentials for them. 登入須使用者自己在瀏覽器授權，不要用自動化瀏覽器、也不要代輸帳密。
4. **Keychain prompt / 鑰匙圈**: on first run macOS may ask for access to "Claude Code-credentials". Tell the user to enter their Mac password and choose **Always Allow**. Never enter the password for them. 第一次可能跳出授權視窗，請使用者自己輸入開機密碼並按「永遠允許」。
5. **Gatekeeper**: the app is not notarized. If macOS blocks it, tell the user to right-click the app → **Open** once. 若被擋下，請使用者對 App 按右鍵 →「打開」。

Do not move the app out of `/Applications`, and do not make the app refresh or write Claude tokens (see README "Known limitations"). 不要搬動 App，也不要讓 App 自己換新或寫回 Claude token（見 README）。

Hooks (optional) are in README; editing the user's `~/.claude/settings.json` or `~/.codex/hooks.json` requires their consent. Hook 為選用，修改使用者設定檔前須取得同意。
