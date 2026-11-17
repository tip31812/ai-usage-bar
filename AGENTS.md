# AI Installer Playbook / AI 安裝作業手冊

**If a user gave you this repo and asked you to install / set up / try it, follow this playbook exactly, in order. Do as much as you can yourself; guide the user only through the steps marked 🙋. You MUST show the risk notice (Step 0) and the final summary (Step 6) to the user — do not skip them even if the user did not ask.**
**若使用者把這個 repo 丟給你要你安裝，請依序照本手冊執行。能自己完成的就直接完成；只有標 🙋 的步驟才引導使用者操作。Step 0 的風險說明與 Step 6 的總結一定要對使用者說，即使他沒問。**

Reply in the user's language (this project supports English and 繁體中文). 用使用者的語言回覆。

## Step 0 — Tell the user what this does and the risks first / 先說明用途與風險

Before running anything, say this (adapt wording, keep every point), then continue unless the user objects:
動手前先對使用者說明以下重點（可改寫措辭，但每點都要有），沒有異議就繼續：

- **What it is / 是什麼**: a macOS menu-bar app showing remaining Claude Code and Codex usage. Unofficial, not affiliated with Anthropic or OpenAI. 非官方的選單列額度看板。
- **Reads your login / 會讀你的登入**: it reads the existing Claude Code login from the macOS Keychain ("Claude Code-credentials", read-only) and `~/.codex/auth.json`, then sends that token to `api.anthropic.com` / `chatgpt.com` to fetch usage. It never saves or writes back credentials. 會唯讀取用本機既有的登入並用它向官方查額度，不另存、不寫回。
- **Unofficial endpoints & terms of service / 非公開端點與服務條款**: those usage endpoints are internal to the official tools. They may change or stop working, and using your login token against them may not be covered by Anthropic's / OpenAI's terms — the author has not received any statement either way, so use at your own risk. 這些端點是官方工具內部用的，可能變動或失效；用登入 token 呼叫它們是否符合 Anthropic／OpenAI 服務條款並無官方說法，風險自負。
- **Reads local chat logs / 讀本機對話紀錄**: only the tail of `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**` to show conversation length; nothing leaves the Mac. 只讀檔尾來算對話長度，不外傳。
- **Installs software / 會安裝東西**: compiles from source and installs to `/Applications/AI額度看板.app` (ad-hoc signed, not notarized). 編譯並安裝到 /Applications，未公證。
- **Optional changes (ask first) / 選用變更（須先問）**: "Launch at login" adds a LaunchAgent in `~/Library/LaunchAgents`; chat-length hooks edit `~/.claude/settings.json` / `~/.codex/hooks.json`. 開機啟動與 hook 會改使用者設定，須先徵得同意。
- Read the source if unsure: `Sources/main.swift`, `hooks/`. 不放心可先看原始碼。

## Step 1 — Check the Mac (automatic) / 檢查環境

- `sw_vers -productVersion` must be ≥ 14, otherwise **stop** and tell the user it is unsupported. 系統低於 macOS 14：**停止**，告知無法安裝。
- `uname -m`: `arm64` is fully supported. On `x86_64` (Intel) the universal build should work, but it has only been verified under Rosetta, never on real Intel hardware — tell the user it is untested and let them decide. Intel 機器：通用版理論上可用，但只在 Rosetta 下驗證過，請告知「未在真機測過」讓使用者決定。

## Step 2 — Command Line Tools (🙋 only if missing)

- Check `xcode-select -p` and `which swiftc`.
- If missing: run `xcode-select --install` yourself, then tell the user: "A pop-up appeared — click **Install** and **Agree**, wait until it finishes (a few minutes), then tell me." Wait for their confirmation, then re-check `which swiftc`.
- 沒有就由你執行 `xcode-select --install`，再請使用者在彈出視窗按「安裝」「同意」，等完成後回報；你再確認一次。

## Step 3 — Login to Claude Code and/or Codex (🙋 only if missing)

- Check `claude auth status` (Claude) and whether `~/.codex/auth.json` exists (Codex). **One of the two is enough**; if both are missing, the app has nothing to show.
- If Claude is logged out: ask the user to run `claude auth login` themselves and approve in **their own browser**. Do NOT use an automated browser, do NOT enter credentials for them.
- 缺登入時請使用者自己執行 `claude auth login` 並在自己的瀏覽器授權；不要用自動化瀏覽器、不要代輸帳密。兩家有一家即可。

## Step 4 — Build and install (automatic) / 編譯安裝

```bash
git clone https://github.com/tip31812/ai-usage-bar.git   # skip if already cloned
cd ai-usage-bar && ./build.sh --install
```

- Takes about a minute. If it fails, read the error, fix what you can (usually missing Command Line Tools), do not hack the source.
- A locally compiled app has no quarantine attribute (checked: `xattr -l` is empty) and runs without a Gatekeeper prompt on the author's Mac; only a *downloaded* copy (zip/browser) gets quarantined and blocked. This was verified on one macOS version only. If macOS does block it ("cannot be opened"), tell the user: right-click `/Applications/AI額度看板.app` → **Open** once. 本機編譯的 App 沒有隔離屬性、作者的 Mac 上可直接開（僅在一個 macOS 版本驗證）；只有下載來的副本會被擋。若仍被擋才請使用者按右鍵 →「打開」。

## Step 5 — First launch (🙋 keychain prompt) / 首次啟動

- After install the app opens by itself; verify with `pgrep -x QuotaBar`.
- On first run macOS may show a **Keychain prompt** ("security wants to access Claude Code-credentials"). You cannot click it. Tell the user: "Enter your Mac login password and choose **Always Allow**." Never ask them to type the password to you. 請使用者自己輸入開機密碼並按「永遠允許」，不要把密碼告訴你。
- Tell them to look at the **top-right menu bar** for the small ring icon and click it. If they cannot see it, the menu bar is probably full: hold ⌘ and drag icons, or remove unused ones (README → Troubleshooting).
- Check `~/Library/Logs/AI額度看板.log` if nothing shows; it records the reason (no credentials).

## Step 6 — Optional extras, then summarize / 選用功能與總結

Ask the user (do not do these silently):
1. **Launch at login?** — tick the checkbox in the panel (the user does this; it creates a LaunchAgent).
2. **Chat-length reminder hooks?** — if yes, add the hook from README to `~/.claude/settings.json` and/or `~/.codex/hooks.json` **merging with existing content, never overwriting**, using the absolute path of this clone (do not move the clone afterwards). Codex may ask the user to re-approve it in `/hooks`.

Finish with a short summary: what was installed and where, what the user still needs to do (if anything), the risks from Step 0 in one line, and how to uninstall:
最後用幾行總結：裝了什麼與位置、使用者還需做什麼、一行風險提醒、以及移除方式：

```bash
./uninstall.sh   # run inside the clone / 在 clone 資料夾內執行
```
(and remove the hook entries if added / 若有加 hook 也要移除)

## Rules / 守則

- Never enter passwords, tokens or credentials for the user. 絕不代輸密碼或憑證。
- Never make the app refresh or write Claude tokens; never kill a running `claude` refresh (see README → Known limitations). 不要讓 App 自己換新或寫回 token，不要砍執行中的 claude。
- Don't modify user config files without asking and merging. 改設定檔前先問，且合併而非覆蓋。

---

# Extending: adding another AI service / 擴充：新增其他 AI 服務

For developers (or AI assistants asked to customize the app) — e.g. "add Gemini / Cursor / Copilot usage". 給想自己加服務的人（或被請求客製的 AI）。

## Code map / 程式地圖 (`Sources/`)

| File | What it holds / 內容 |
|---|---|
| `Models.swift` | `Lang`/`tr()` (UI language), `Brand`, the **`UsageSource` protocol**, the **`Sources.all` registry**, `UsageWindow`, `ProviderState`, helpers, `Log` |
| `ClaudeProvider.swift`, `CodexProvider.swift` | **One file per service** implementing `UsageSource`. Copy one as your template. 每家一個檔，複製一份當範本 |
| `Conversations.swift` | Scans local chat logs for conversation length (Claude Code / Codex) |
| `Notifier.swift` | Mac notifications (primary service low/back, Codex long chat, Claude logged out) |
| `Store.swift` | App state (`states`, aligned with `Sources.all`), refresh timers, `Provider` wrapper |
| `Views.swift` | Panel, rings, legend, detail rows, menu-bar label, routing advice (`advise`, `menuBarFocus`) |
| `App.swift` | Launch-at-login agent, `--snapshot` mode, app entry point |

The **first** entry of `Sources.all` is the *primary* service: it is preferred in the routing advice, drives the "almost out / back" notifications, and is the outer ring. 清單第一個是「主服務」：建議優先用它、它的快沒了／回來了會通知、它是最外圈。

## Recipe / 步驟

1. **Find a data source.** Does the service expose remaining quota via a CLI login, an API, or local logs? Verify with `curl`/the CLI first. If there is no way to read usage, stop and tell the user honestly. 先確認真的讀得到額度；沒有就如實告知。
2. **Create `Sources/XxxProvider.swift`**: `enum XxxFetcher: UsageSource { static let brand = Brand(name:symbol:color:); static func fetch(manual: Bool = false) async -> ProviderState }`. Fill `windows` (`UsageWindow(label:usedPercent:resetsAt:)`), `live`, `source`, `error`. `label` is an internal key: use `"每週"` for the weekly window and `"5 小時"` for 5-hour (the UI and `UsageWindow.title` recognize them); other labels are shown as-is. Never write credentials anywhere; log only reasons with `Log`.
3. **Register it**: add `XxxFetcher.self` to `Sources.all` in `Models.swift` (order = ring order, outer → inner).
4. **Everything else follows automatically**: rings, legend, detail rows, routing advice, menu-bar readout, "primary low/back" notification and the conversation-dot color all iterate over the registry.
5. **UI text**: wrap every user-visible string as `tr("中文", "English")`; add the English window title in `UsageWindow.title` if you introduce a new label.
6. **Optional, service-specific**: if the service keeps local chat logs, add a scanner in `Conversations.swift` (set `tool` to the brand name so the dot color matches); `Notifier.checkClaudeLogin` is Claude-CLI specific — add your own login-lost notice if needed.
7. **Build and verify**: `./build.sh`, then `build.noindex/AI額度看板.app/Contents/MacOS/QuotaBar --snapshot out.png --lang en` (live data) and look at the image; `--demo` uses fixed fake numbers for the built-in services only. Don't claim it works until you've seen real numbers, or say clearly that it's unverified. 沒看到真實數字就要說明未驗證。
8. **Respect the rules above**: read-only credentials, ask before touching user config, tell the user about new privacy implications (where the new service's token is sent). 新增服務後，要告訴使用者新的隱私影響。

Tip: keep your changes in your own fork and update the README so the next person knows what you added. 建議在自己的 fork 更新 README。
