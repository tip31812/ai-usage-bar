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
        Log.write("通知：\(title)")
    }

    /// Claude 最緊的額度掉到 15% 以下通知一次；之後回到 35% 以上（重置回補）再通知「回來了」。
    /// 狀態記在 UserDefaults，重開看板也不會重複通知。「回來了」只信即時資料，避免 App 記錄過舊時誤報。
    static func checkClaude(_ claude: Provider, codex: Provider) {
        guard let t = claude.tightest else { return }
        let low = UserDefaults.standard.bool(forKey: claudeLowKey)
        if !low, t.remainingPercent <= lowRemaining {
            UserDefaults.standard.set(true, forKey: claudeLowKey)
            let back = t.resetsAt.map { "\(clock($0))回補" } ?? "回補時間未知"
            let next = codex.tightest.map {
                $0.remainingPercent > lowRemaining ? "可以先切去 Codex（剩 \(pct($0))）。" : "Codex 也只剩 \(pct($0))。"
            } ?? ""
            post(id: "claude-low", title: "Claude 快沒了", body: "\(t.label)額度剩 \(pct(t))，\(back)。" + next)
        } else if low, claude.state.live, t.remainingPercent > warnRemaining {
            UserDefaults.standard.set(false, forKey: claudeLowKey)
            post(id: "claude-back", title: "Claude 回來了", body: "額度已回補，現在剩 \(pct(t))，可以切回 Claude 了。")
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
        post(id: "claude-logged-out", title: "Claude CLI 登出了",
             body: "看板讀不到重置時間。打開終端機輸入 claude auth login，在跳出的瀏覽器頁按授權即可。")
    }

    /// 同一段對話、同一個門檻只通知一次（記在 UserDefaults，重開也不重複）
    static func checkLongCodex(_ list: [Conversation]) {
        var done = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        for c in list where c.tool == "Codex" {
            let level = c.tokens >= veryLongConversation ? veryLongConversation : c.tokens >= longConversation ? longConversation : 0
            guard level > 0, !done.contains("\(c.id)@\(level)") else { continue }
            done.insert("\(c.id)@\(level)")
            if level == veryLongConversation { done.insert("\(c.id)@\(longConversation)") }
            post(id: "\(c.id)@\(level)", title: "Codex 對話太長了",
                 body: "「\(c.name)」已約 \(wan(c.tokens)) 萬 token，越長越耗額度。整理進度後開新對話會比較省。")
        }
        UserDefaults.standard.set(Array(done.suffix(300)), forKey: notifiedKey)
    }
}

func wan(_ tokens: Int) -> String { String(format: "%.1f", Double(tokens) / 10000) }

