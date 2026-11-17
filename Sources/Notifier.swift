import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

// MARK: - 通知（Claude 額度快沒／回來了；Codex 長對話。Claude 長對話由 Claude Code 的 hook 在對話裡提醒）

enum Notifier {
    static let notifiedKey = "notifiedLongConversations"
    static let claudeLowKey = "claudeLow"

    static func setup() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        Log.write(tr("通知：", "Notification: ") + title)
    }

    /// 主服務（`Sources.all` 的第一個，預設是 Claude）最緊的額度掉到 15% 以下通知一次；之後回到 35% 以上（重置回補）再通知「回來了」。
    /// 狀態記在 UserDefaults，重開看板也不會重複通知。「回來了」只信即時資料，避免 App 記錄過舊時誤報。
    static func checkPrimary(_ ps: [Provider]) {
        guard let primary = ps.first, let t = primary.tightest else { return }
        let name = primary.brand.name
        let low = UserDefaults.standard.bool(forKey: claudeLowKey)
        if !low, t.remainingPercent <= lowRemaining {
            UserDefaults.standard.set(true, forKey: claudeLowKey)
            let back = t.resetsAt.map { tr("\(clock($0))回補", "refills \(clock($0))") } ?? tr("回補時間未知", "refill time unknown")
            // 其他服務裡剩最多的那一個
            let best = ps.dropFirst().compactMap { p in p.tightest.map { (p.brand.name, $0) } }
                .max { $0.1.remainingPercent < $1.1.remainingPercent }
            let next = best.map { (n, w) in
                w.remainingPercent > lowRemaining
                    ? tr("可以先切去 \(n)（剩 \(pct(w))）。", " You can switch to \(n) (\(pct(w)) left).")
                    : tr("\(n) 也只剩 \(pct(w))。", " \(n) is also down to \(pct(w)).")
            } ?? ""
            post(id: "claude-low", title: tr("\(name) 快沒了", "\(name) is almost out"),
                 body: tr("\(t.title)額度剩 \(pct(t))，\(back)。", "\(t.title) quota at \(pct(t)), \(back).") + next)
        } else if low, primary.state.live, t.remainingPercent > warnRemaining {
            UserDefaults.standard.set(false, forKey: claudeLowKey)
            post(id: "claude-back", title: tr("\(name) 回來了", "\(name) is back"),
                 body: tr("額度已回補，現在剩 \(pct(t))，可以切回 \(name) 了。", "Quota refilled: \(pct(t)) left. You can switch back to \(name)."))
        }
    }

    /// 連續 3 輪（約 15 分鐘）都因登入問題讀不到才通知，鑰匙圈偶爾慢一次不會誤報；同一次登出只通知一次，讀到即時資料就重置。
    private static var loginLostStreak = 0
    static let claudeLoggedOutKey = "claudeLoggedOut"
    static func checkClaudeLogin(_ s: ProviderState) {
        guard !s.live, s.loginLost else {
            loginLostStreak = 0
            if s.live { UserDefaults.standard.set(false, forKey: claudeLoggedOutKey) }
            return
        }
        loginLostStreak += 1
        guard loginLostStreak >= 3, !UserDefaults.standard.bool(forKey: claudeLoggedOutKey) else { return }
        UserDefaults.standard.set(true, forKey: claudeLoggedOutKey)
        post(id: "claude-logged-out", title: tr("Claude CLI 登出了", "Claude CLI logged out"),
             body: tr("看板讀不到重置時間。打開終端機輸入 claude auth login，在跳出的瀏覽器頁按授權即可。", "Reset times are unavailable. Run `claude auth login` in Terminal and approve in the browser window that opens."))
    }

    /// 同一段對話、同一個門檻只通知一次（記在 UserDefaults，重開也不重複）
    static func checkLongCodex(_ list: [Conversation]) {
        var done = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        for c in list where c.tool == "Codex" {
            let level = c.tokens >= veryLongConversation ? veryLongConversation : c.tokens >= longConversation ? longConversation : 0
            guard level > 0, !done.contains("\(c.id)@\(level)") else { continue }
            done.insert("\(c.id)@\(level)")
            if level == veryLongConversation { done.insert("\(c.id)@\(longConversation)") }
            post(id: "\(c.id)@\(level)", title: tr("Codex 對話太長了", "Codex conversation is getting long"),
                 body: tr("「\(c.name)」已約 \(wan(c.tokens)) 萬 token，越長越耗額度。整理進度後開新對話會比較省。", "\"\(c.name)\" is at about \(tokenText(c.tokens)) tokens — the longer it gets, the more quota it burns. Summarize and start a new one to save usage."))
        }
        UserDefaults.standard.set(Array(done.suffix(300)), forKey: notifiedKey)
    }
}

func wan(_ tokens: Int) -> String { String(format: "%.1f", Double(tokens) / 10000) }
/// 對話長度顯示：中文「29.1 萬」，英文「291k」
func tokenText(_ tokens: Int) -> String { tr("\(wan(tokens)) 萬", "\(Int((Double(tokens) / 1000).rounded()))k") }

