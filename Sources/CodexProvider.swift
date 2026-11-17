import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

// MARK: - Codex

enum CodexFetcher {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    static func fetch() async -> ProviderState {
        if let s = try? await fromAPI() { return s }
        return fromSessions()
    }

    static func fromAPI() async throws -> ProviderState {
        let data = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        guard let obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let at = tokens["access_token"] as? String, !at.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(at)", forHTTPHeaderField: "Authorization")
        if let acct = tokens["account_id"] as? String { req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (code, resp) = try await Net.json(req)
        guard code == 200, let rl = resp["rate_limit"] as? [String: Any] else { throw URLError(.badServerResponse) }
        var s = ProviderState()
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any], let u = num(w["used_percent"]) else { continue }
            let secs = num(w["limit_window_seconds"]) ?? 604800
            let reset = num(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            s.windows.append(UsageWindow(label: windowLabel(seconds: secs), usedPercent: u, resetsAt: reset))
        }
        s.windows.sort { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
        s.plan = (resp["plan_type"] as? String)?.capitalized
        s.source = "官方用量 API（即時）"
        s.live = true
        if (rl["limit_reached"] as? Bool) == true { s.note = "已達上限" }
        return s
    }

    /// API 失敗時：讀最近的 Codex 對話紀錄裡最後一筆 rate_limits。
    static func fromSessions() -> ProviderState {
        var s = ProviderState()
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        var files: [(URL, Date)] = []
        for dir in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(dir)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let u as URL in en where u.lastPathComponent.hasPrefix("rollout-") && u.pathExtension == "jsonl" {
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if m > cutoff { files.append((u, m)) }
            }
        }
        for (url, mtime) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let rl = findRateLimits(obj) else { continue }
                for key in ["primary", "secondary"] {
                    guard let w = rl[key] as? [String: Any], let u = num(w["used_percent"]) else { continue }
                    let mins = num(w["window_minutes"]) ?? 10080
                    let reset = num(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                    s.windows.append(UsageWindow(label: windowLabel(seconds: mins * 60), usedPercent: u, resetsAt: reset))
                }
                s.plan = (rl["plan_type"] as? String)?.capitalized
                s.source = "Codex 對話紀錄（\(relative(mtime))）"
                s.note = "API 暫時讀不到；開一下 Codex 就會更新登入"
                return s
            }
        }
        s.source = "無資料"
        s.error = "讀不到 Codex 登入或最近 14 天的對話紀錄"
        return s
    }

    static func findRateLimits(_ v: Any) -> [String: Any]? {
        if let d = v as? [String: Any] {
            if let rl = d["rate_limits"] as? [String: Any] { return rl }
            for (_, x) in d { if let r = findRateLimits(x) { return r } }
        } else if let a = v as? [Any] {
            for x in a { if let r = findRateLimits(x) { return r } }
        }
        return nil
    }
}

