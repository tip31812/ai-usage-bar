// AI 額度看板：Mac 選單列顯示 Claude 與 Codex 剩餘額度與重置時間。
// 只讀本機既有登入資料，不另外存任何金鑰；資料只送回 Anthropic／OpenAI 自家 API。
import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

// MARK: - 資料模型

struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

struct ProviderState {
    var windows: [UsageWindow] = []
    var plan: String?
    var live = false
    var source: String = "讀取中…"
    var note: String?
    var error: String?
    /// Claude 這輪讀不到，原因是登入沒了或過期（不是網路、429 這類暫時問題）
    var loginLost = false
    /// 選單列顯示用：最緊的那個時間窗的剩餘％
    var tightestRemaining: Double? { windows.map(\.remainingPercent).min() }
}

// MARK: - 共用工具

enum Net {
    static func json(_ req: URLRequest) async throws -> (Int, [String: Any]) {
        var r = req
        r.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (code, obj)
    }
}

func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

func isoDate(_ v: Any?) -> Date? {
    guard let s = v as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func windowLabel(seconds: Double) -> String {
    switch seconds {
    case ..<(6 * 3600): return "5 小時"
    case ..<(2 * 86400): return "每日"
    default: return "每週"
    }
}

// MARK: - 記錄（只記原因，不記任何登入資料）

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AI額度看板.log")
    static func write(_ msg: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] \(msg)\n"
        // 超過 200KB 就從頭開始，避免越長越大
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// MARK: - Claude

enum ClaudeFetcher {
    static let service = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 看板自己只讀不寫：不碰 refresh token、不寫回鑰匙圈（避免和 Claude Code 搶同一份登入）。
    /// 登入過期或被拒時，請 Claude CLI 跑一次本機的 /usage，由 CLI 自己換新並寫回，再重讀一次。
    static func fetch(manual: Bool = false) async -> ProviderState {
        var (state, why, renewable) = await attempt()
        Log.write("Claude 第一次：\(state != nil ? "即時" : why)")
        if state == nil, renewable {
            let ok = await nudgeCLI(force: manual)
            Log.write("請 CLI 換新：\(ok ? "成功" : "沒跑或失敗")")
            if ok {
                (state, why, _) = await attempt()
                Log.write("Claude 換新後：\(state != nil ? "即時" : why)")
            }
        }
        if let state { return state }
        var s = desktopFallback()
        if s.error == nil { s.note = why + "，暫用 App 記錄（沒有重置時間）" }
        s.loginLost = why == "讀不到 Claude CLI 登入" || why == "CLI 登入已過期" || why == "用量 API 回應 401"
        return s
    }

    /// 讀一次登入並問一次用量 API。renewable＝失敗原因是登入過期或被拒，值得請 CLI 換新。
    private static func attempt() async -> (ProviderState?, String, Bool) {
        guard let oauth = await readKeychain(), let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return (nil, "讀不到 Claude CLI 登入", false)
        }
        let expiresMs = num(oauth["expiresAt"]) ?? 0
        if expiresMs > 0 && Date(timeIntervalSince1970: expiresMs / 1000) < Date() {
            return (nil, "CLI 登入已過期", true)
        }
        do {
            var state = try await callUsage(token)
            state.plan = (oauth["subscriptionType"] as? String)?.capitalized
            return (state, "", false)
        } catch let e as UsageError {
            return (nil, "用量 API 回應 \(e.code)", e.code == 401)
        } catch {
            return (nil, "連不上用量 API", false)
        }
    }

    /// 上次請 CLI 換新的時間；最多 15 分鐘一次，CLI 本身壞掉時才不會一直重跑
    private static var lastNudge: Date?
    /// 還沒跑完的 CLI；跑完前不開第二個
    private static var nudging: Process?

    /// 自動更新最多 15 分鐘試一次；手動按 ↻ 不受限，但仍至少隔 30 秒，避免連按
    private static func claimNudge(force: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let p = nudging, p.isRunning { return false }
        let gap: TimeInterval = force ? 30 : 15 * 60
        if let t = lastNudge, Date().timeIntervalSince(t) < gap { return false }
        lastNudge = Date()
        return true
    }

    private static func track(_ p: Process) { lock.lock(); nudging = p; lock.unlock() }

    /// 執行 `claude -p /usage`：本機指令、不耗對話額度，但會讓 CLI 先把過期的登入換新。成功回傳 true。
    static func nudgeCLI(force: Bool = false) async -> Bool {
        guard claimNudge(force: force) else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.appendingPathComponent(".local/bin/claude").path]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        // 在快取資料夾執行，不在任何專案資料夾留下對話紀錄
        let dir = home.appendingPathComponent("Library/Caches/app.tipstudio.quotabar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-p", "/usage"]
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        track(p)
        var waited = 0
        while p.isRunning && waited < 300 {  // 最多等 30 秒
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        // 逾時不砍：CLI 換新時會用掉舊的 refresh token，砍在換到一半會把登入弄丟（2026-10-24 疑似發生過）
        if p.isRunning { Log.write("CLI 30 秒沒跑完，讓它自己跑完，這輪先用備援"); return false }
        return p.terminationStatus == 0
    }

    private static let lock = NSLock()
    /// 還沒結束的讀取（例如系統正在跳授權視窗）就不再開第二個，避免視窗越疊越多
    private static var reading: Process?

    /// 背景讀管線的結果；邊跑邊讀，輸出超過管線緩衝（64KB）時 security 才不會卡住等人讀
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        var data: Data? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ d: Data) { lock.lock(); value = d; lock.unlock() }
    }

    private static func startRead() -> (Process, Output)? {
        lock.lock()
        defer { lock.unlock() }
        if let p = reading, p.isRunning { return nil }
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let output = Output()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { output.set(handle.readDataToEndOfFile()) }
        reading = p
        return (p, output)
    }

    /// 透過系統 /usr/bin/security 讀（和 Claude Code 同一種讀法，共用它的鑰匙圈授權；看板重新編譯也不會被當成新 App 再要授權）。
    static func readKeychain() async -> [String: Any]? {
        guard let (p, output) = startRead() else { Log.write("上一個 security 還沒結束，這輪跳過"); return nil }
        // 最多等 5 秒；逾時不砍掉（砍了會留下關不掉的授權視窗），這輪先用備援
        var waited = 0
        while (p.isRunning || output.data == nil) && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        if p.isRunning { Log.write("security 5 秒內沒回應（可能在等授權視窗）"); return nil }
        guard p.terminationStatus == 0, let data = output.data else {
            Log.write("security 結束碼 \(p.terminationStatus)")
            return nil
        }
        guard let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = all["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth
    }

    struct UsageError: Error { let code: Int }

    static func callUsage(_ token: String) async throws -> ProviderState {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (code, obj) = try await Net.json(req)
        guard code == 200 else { throw UsageError(code: code) }
        var s = ProviderState()
        let keys: [(String, String)] = [
            ("five_hour", "5 小時"), ("seven_day", "每週"),
            ("seven_day_opus", "每週 Opus"), ("seven_day_sonnet", "每週 Sonnet"),
        ]
        for (k, label) in keys {
            guard let w = obj[k] as? [String: Any], let u = num(w["utilization"]) else { continue }
            s.windows.append(UsageWindow(label: label, usedPercent: u, resetsAt: isoDate(w["resets_at"])))
        }
        s.source = "官方用量 API（即時）"
        s.live = true
        if s.windows.isEmpty { s.error = "API 有回應但沒有額度欄位" }
        return s
    }

    /// 讀不到 CLI 登入或 token 過期時：讀 Claude 桌面 App 自己記錄的用量樣本（只有百分比，沒有重置時間）。
    static func desktopFallback() -> ProviderState {
        var s = ProviderState()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = obj["samples"] as? [[String: Any]],
              let last = samples.max(by: { (num($0["t"]) ?? 0) < (num($1["t"]) ?? 0) }),
              let u = last["u"] as? [String: Any] else {
            s.source = "無資料"
            s.error = "找不到 Claude 登入，也讀不到桌面 App 記錄"
            return s
        }
        if let fh = num(u["fh"]) { s.windows.append(UsageWindow(label: "5 小時", usedPercent: fh, resetsAt: nil)) }
        if let sd = num(u["sd"]) { s.windows.append(UsageWindow(label: "每週", usedPercent: sd, resetsAt: nil)) }
        let t = Date(timeIntervalSince1970: (num(last["t"]) ?? 0) / 1000)
        s.source = "Claude App 記錄（\(relative(t))）"
        s.note = "登入 Claude CLI 後可顯示重置時間"
        return s
    }
}

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

// MARK: - 對話長度（Claude Code／Codex 的本機對話紀錄）

struct Conversation: Identifiable {
    let id: String
    let tool: String      // "Claude" 或 "Codex"
    let name: String
    let tokens: Int       // 最後一次回覆時的上下文大小
    let updated: Date
}

/// 長對話門檻：15 萬開始耗額度，30 萬非常耗
let longConversation = 150_000
let veryLongConversation = 300_000

enum ConversationScanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// 幾小時內有動過的才算「進行中」
    static let activeWindow: TimeInterval = 3 * 3600

    static func scan() -> [Conversation] {
        (claude() + codex()).filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
    }

    /// 讀檔案尾端（最後 2MB），長對話紀錄可能幾十 MB，不整個讀
    static func tailLines(_ url: URL, bytes: Int = 2_000_000) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    /// 讀檔案第一行（只讀開頭 256KB）
    static func headLine(_ url: URL) -> Substring? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256_000)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first
    }

    struct CodexIndex {
        let visibleIDs: Set<String>
        let names: [String: String]
    }

    /// Codex 狀態資料庫同時提供可見對話及名稱；已刪除／封存的不列入。
    /// 資料庫暫時讀不到時才退回 rollout 掃描，避免整個清單消失。
    static func codexIndex() -> CodexIndex? {
        let path = home.appendingPathComponent(".codex/state_5.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, title FROM threads WHERE archived = 0", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        func column(_ index: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, index) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, index))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
        func useful(_ text: String?) -> String? {
            guard let text else { return nil }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : String(clean.prefix(80))
        }

        var names: [String: String] = [:]
        var visibleIDs = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let id = column(0) {
                visibleIDs.insert(id)
                if let name = useful(column(1)) {
                    names[id] = name
                } else if let title = column(2) {
                    // 舊紀錄可能只有原始首則訊息，先取「My request」內的第一行。
                    let request = title.components(separatedBy: "## My request:").last ?? title
                    let firstLine = request.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty && !$0.hasPrefix("#") }
                    names[id] = useful(firstLine)
                }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return nil }
        return CodexIndex(visibleIDs: visibleIDs, names: names)
    }

    static func recentFiles(in root: URL, deep: Bool, match: (URL) -> Bool) -> [(URL, Date)] {
        let cutoff = Date().addingTimeInterval(-activeWindow)
        var out: [(URL, Date)] = []
        let opts: FileManager.DirectoryEnumerationOptions = deep ? [] : [.skipsSubdirectoryDescendants]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: opts) else { return [] }
        for case let u as URL in en where match(u) {
            if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > cutoff {
                out.append((u, m))
            }
        }
        return out
    }

    /// Claude Code：~/.claude/projects/<專案>/<對話>.jsonl
    static func claude() -> [Conversation] {
        let root = home.appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var result: [Conversation] = []
        for dir in dirs {
            for (url, mtime) in recentFiles(in: dir, deep: false, match: { $0.pathExtension == "jsonl" }) {
                // Claude Desktop 刪除對話時會留下此標記；檔案若仍在，也不要顯示。
                let released = url.deletingPathExtension().appendingPathExtension("desktop-released.json")
                if let data = try? Data(contentsOf: released),
                   let marker = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   marker["reason"] as? String == "delete" { continue }
                var tokens = 0, title: String?, cwd: String?
                for line in tailLines(url).reversed() {
                    guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                    if title == nil, o["type"] as? String == "custom-title" { title = o["customTitle"] as? String }
                    if cwd == nil { cwd = o["cwd"] as? String }
                    if tokens == 0, let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                        tokens = Int((num(u["input_tokens"]) ?? 0) + (num(u["cache_read_input_tokens"]) ?? 0)
                                     + (num(u["cache_creation_input_tokens"]) ?? 0))
                    }
                    if tokens > 0 && title != nil && cwd != nil { break }
                }
                // 看板自己請 CLI 換新登入的那種對話不列
                if cwd?.contains("app.tipstudio.quotabar") == true { continue }
                let name = title ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude 對話"
                result.append(Conversation(id: "claude:" + url.lastPathComponent, tool: "Claude", name: name, tokens: tokens, updated: mtime))
            }
        }
        return result
    }

    /// Codex：~/.codex/sessions/年/月/日/rollout-*.jsonl
    static func codex() -> [Conversation] {
        let root = home.appendingPathComponent(".codex/sessions")
        let index = codexIndex()
        var result: [Conversation] = []
        for (url, mtime) in recentFiles(in: root, deep: true, match: { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }) {
            var tokens = 0
            for line in tailLines(url).reversed() where line.contains("\"token_count\"") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let info = (o["payload"] as? [String: Any])?["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else { continue }
                tokens = Int(num(last["input_tokens"]) ?? 0)
                break
            }
            // session_meta 的 id 對應狀態資料庫中的使用者可見名稱。
            guard let first = headLine(url),
                  let o = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any],
                  let id = (o["payload"] as? [String: Any])?["id"] as? String else { continue }
            if let index, !index.visibleIDs.contains(id) { continue }
            let name = index?.names[id] ?? "Codex 對話 \(id.prefix(8))"
            result.append(Conversation(id: "codex:" + url.lastPathComponent, tool: "Codex", name: name, tokens: tokens, updated: mtime))
        }
        return result
    }
}

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

// MARK: - 時間文字

func relative(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "剛剛" }
    if s < 3600 { return "\(s / 60) 分鐘前" }
    if s < 86400 { return "\(s / 3600) 小時前" }
    return "\(s / 86400) 天前"
}

func clock(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_TW")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm" : "M/d（EEE）HH:mm"
    return f.string(from: d)
}

// MARK: - 狀態

@MainActor
final class Store: ObservableObject {
    @Published var claude = ProviderState()
    @Published var codex = ProviderState()
    @Published var updatedAt: Date?
    @Published var loading = false
    /// 系統切換淺／深色時 +1，讓選單列圖片重畫
    @Published var appearanceTick = 0
    @Published var conversations: [Conversation] = []
    private var timer: Timer?
    private var resetTimer: Timer?

    init(autoRefresh: Bool = true) {
        guard autoRefresh else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.appearanceTick += 1 } }
        // 睡醒馬上更新，不用等下一輪 5 分鐘；等 5 秒讓網路先連上
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.refresh()
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh(manual: Bool = false) {
        if loading {
            if manual { Task { await refreshConversations() } }
            return
        }
        loading = true
        Task {
            async let c = ClaudeFetcher.fetch(manual: manual)
            async let x = CodexFetcher.fetch()
            await refreshConversations()
            let (cs, xs) = await (c, x)
            claude = cs
            codex = xs
            let ps = providers
            Notifier.checkClaude(ps[0], codex: ps[1])
            Notifier.checkClaudeLogin(cs)
            updatedAt = Date()
            loading = false
            scheduleResetRefresh()
        }
    }

    private func refreshConversations() async {
        conversations = await Task.detached { ConversationScanner.scan() }.value
        Notifier.checkLongCodex(conversations)
    }

    /// 有額度會在下一輪自動更新前重置時，重置後 20 秒就更新，「回來了」通知與建議不用多等
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        let next = providers.flatMap { $0.state.windows.compactMap(\.resetsAt) }.filter { $0 > Date() }.min()
        guard let next, next.timeIntervalSinceNow < 300 else { return }
        resetTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSinceNow + 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

// MARK: - 畫面

struct Brand {
    let name: String
    let symbol: String
    let color: Color
    static let claude = Brand(name: "Claude", symbol: "asterisk", color: Color(red: 0.85, green: 0.47, blue: 0.34))
    static let codex = Brand(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.06, green: 0.64, blue: 0.50))
}

/// 剩 ≤15% 算「快沒了」（紅、改建議另一家）；≤35% 開始提醒（橘）
let lowRemaining = 15.0
let warnRemaining = 35.0

/// 剩餘量低時才改用警示色，平常用品牌色
func ringColor(_ remaining: Double, brand: Color) -> Color {
    remaining <= lowRemaining ? .red : remaining <= warnRemaining ? .orange : brand
}

func pct(_ w: UsageWindow) -> String { "\(Int(w.remainingPercent.rounded()))%" }

func shortCountdown(_ d: Date) -> String {
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "即將更新" }
    let day = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if day > 0 { return "\(day) 天 \(h) 小時" }
    if h > 0 { return "\(h) 小時 \(m) 分" }
    return "\(max(1, m)) 分鐘"
}

/// 週重置剩幾天：滿 1 天說「天」，不到 1 天說「小時」
func daysLeft(_ d: Date) -> String {
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "即將重置" }
    if s < 86400 { return "剩 \(max(1, s / 3600)) 小時" }
    return "剩 \(s / 86400) 天"
}

/// 快重置了但額度還剩很多：剩不到 2 天、還有 30% 以上
func shouldHurry(_ w: UsageWindow) -> Bool {
    guard let r = w.resetsAt else { return false }
    let s = r.timeIntervalSinceNow
    return s > 0 && s < 2 * 86400 && w.remainingPercent >= 30
}

/// 每家名字下方的「週重置 剩 N 天」標籤
struct WeeklyBadge: View {
    let w: UsageWindow
    let brand: Color
    var body: some View {
        if let r = w.resetsAt {
            let hurry = shouldHurry(w)
            HStack(spacing: 4) {
                Image(systemName: hurry ? "flame.fill" : "calendar")
                    .font(.system(size: 10, weight: .semibold))
                Text("週重置").foregroundStyle(hurry ? Color.orange : .secondary)
                Text(daysLeft(r)).fontWeight(.bold)
                if hurry { Text("快用！").fontWeight(.bold) }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(hurry ? Color.orange : Color.primary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill((hurry ? Color.orange : brand).opacity(0.13)))
            .help("每週額度 \(clock(r)) 重置，還剩 \(Int(w.remainingPercent.rounded()))%")
        }
    }
}

struct FooterButton: View {
    let title: String
    let symbol: String
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Provider: Identifiable {
    let brand: Brand
    let state: ProviderState
    var id: String { brand.name }
    /// 最緊的時間窗：剩最少的那一個
    var tightest: UsageWindow? { state.windows.min { $0.remainingPercent < $1.remainingPercent } }
    /// 全模型共用的每週額度（沒有就退而求其次用 Opus／Sonnet 的每週）
    var weekly: UsageWindow? {
        state.windows.first { $0.label == "每週" } ?? state.windows.first { $0.label.hasPrefix("每週") }
    }
}

extension Store {
    var providers: [Provider] {
        [Provider(brand: .claude, state: claude), Provider(brand: .codex, state: codex)]
    }
}

// MARK: - 分流建議（Claude 優先：5 小時額度會回補，能用就先用）

struct Advice {
    let brand: Brand?     // nil＝兩家都快沒了
    let title: String
    let detail: String
}

func advise(claude: Provider, codex: Provider) -> Advice? {
    let c = claude.tightest, x = codex.tightest
    if c == nil && x == nil { return nil }
    if let c, c.remainingPercent > lowRemaining {
        // Codex 每週快重置但還剩很多：分點工作給它，免得浪費
        if let w = codex.weekly, let r = w.resetsAt, shouldHurry(w) {
            return Advice(brand: .claude, title: "現在用 Claude",
                          detail: "Codex \(daysLeft(r))就重置、還有 \(pct(w))，分點工作給它")
        }
        let tail = c.remainingPercent <= warnRemaining ? "，快到底了" : ""
        return Advice(brand: .claude, title: "現在用 Claude", detail: "\(c.label)還剩 \(pct(c))" + tail)
    }
    let back = c.map { w in w.resetsAt.map { "Claude \(clock($0)) 回補" } ?? "Claude 回補時間未知" } ?? "Claude 讀不到資料"
    if let x, x.remainingPercent > lowRemaining {
        return Advice(brand: .codex, title: "先用 Codex", detail: "\(back)（Codex 剩 \(pct(x))）")
    }
    return Advice(brand: nil, title: "兩家都快沒了", detail: back)
}

/// 面板最上方的一句話建議
struct AdviceRow: View {
    let a: Advice
    var body: some View {
        let color = a.brand?.color ?? .red
        HStack(spacing: 9) {
            Image(systemName: a.brand?.symbol ?? "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.system(size: 13, weight: .semibold))
                Text(a.detail).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
    }
}

/// 同心圓：外圈 Claude、內圈 Codex
struct ConcentricRings: View {
    let providers: [Provider]
    var size: CGFloat = 140
    var line: CGFloat = 16
    var gap: CGFloat = 6

    var body: some View {
        ZStack {
            ForEach(Array(providers.enumerated()), id: \.offset) { i, p in
                let d = size - CGFloat(i) * 2 * (line + gap)
                let remaining = p.tightest?.remainingPercent
                let color = remaining.map { ringColor($0, brand: p.brand.color) } ?? p.brand.color
                ZStack {
                    Circle().stroke(color.opacity(0.17), lineWidth: line)
                    if let remaining {
                        Circle()
                            .trim(from: 0, to: max(0.001, remaining / 100))
                            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: d - line, height: d - line)
            }
        }
        .frame(width: size, height: size)
    }
}

struct LegendRow: View {
    let p: Provider
    var body: some View {
        let t = p.tightest
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: p.brand.symbol)
                    .font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.brand.color.gradient))
                Text(p.brand.name).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if let t {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(t.remainingPercent.rounded()))")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text("%").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .foregroundStyle(ringColor(t.remainingPercent, brand: p.brand.color))
                } else {
                    Text("未連線").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                }
            }
            // 最緊的就是每週、而且有重置時間時，標籤已經講了，不再重複
            let weekly = p.weekly
            let badgeCovers = t != nil && t?.id == weekly?.id && weekly?.resetsAt != nil
            if !badgeCovers {
                Group {
                    if let t {
                        if let r = t.resetsAt { Text("\(t.label) · \(shortCountdown(r))後重置") }
                        else { Text("\(t.label) · 重置時間未知") }
                    } else {
                        Text(p.state.error ?? "讀取中…")
                    }
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                .lineLimit(1)
            }
            if let weekly {
                WeeklyBadge(w: weekly, brand: p.brand.color)
                    .padding(.leading, 20)
                    .padding(.top, 3)
            }
        }
        .help(p.state.source)
    }
}

/// 各家所有時間窗的小字明細
struct DetailList: View {
    let providers: [Provider]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(providers) { p in
                ForEach(p.state.windows) { w in
                    HStack(spacing: 6) {
                        Circle().fill(p.brand.color).frame(width: 6, height: 6)
                        Text("\(p.brand.name) \(w.label)").foregroundStyle(.secondary)
                        Spacer()
                        if let r = w.resetsAt, w.label.hasPrefix("每週") {
                            Text(daysLeft(r)).fontWeight(.semibold)
                                .foregroundStyle(shouldHurry(w) ? Color.orange : .secondary)
                        }
                        Text(w.resetsAt.map { clock($0) } ?? "—").foregroundStyle(.tertiary)
                        Text("\(Int(w.remainingPercent.rounded()))%")
                            .fontWeight(.semibold)
                            .foregroundStyle(ringColor(w.remainingPercent, brand: p.brand.color))
                            .frame(width: 36, alignment: .trailing)
                    }
                    .font(.system(size: 11).monospacedDigit())
                }
            }
            ForEach(providers.filter { $0.state.note != nil }) { p in
                Label(p.state.note!, systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

/// 最近使用的對話與長度；長對話標橘／紅
struct ConversationList: View {
    let items: [Conversation]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("最近使用的對話（3 小時內）")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(items.prefix(4)) { c in
                HStack(spacing: 6) {
                    Circle().fill(c.tool == "Claude" ? Brand.claude.color : Brand.codex.color).frame(width: 6, height: 6)
                    Text(c.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(c.name)
                    Spacer(minLength: 6)
                    if c.tokens >= longConversation {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                            .foregroundStyle(c.tokens >= veryLongConversation ? Color.red : Color.orange)
                    }
                    Text("\(wan(c.tokens)) 萬")
                        .fontWeight(.semibold)
                        .foregroundStyle(c.tokens >= veryLongConversation ? Color.red
                                         : c.tokens >= longConversation ? Color.orange : .secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 11).monospacedDigit())
            }
            if items.contains(where: { $0.tokens >= longConversation }) {
                Label("超過 15 萬就算長對話，越長每句越耗額度；整理進度後開新對話較省",
                      systemImage: "lightbulb")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = LoginAgent.isEnabled

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("AI 額度").font(.system(size: 17, weight: .bold, design: .rounded))
                    if let u = store.updatedAt {
                        Text(relative(u) + "更新").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { store.refresh(manual: true) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                            .rotationEffect(.degrees(store.loading ? 360 : 0))
                            .animation(store.loading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                                       value: store.loading)
                    }
                    .buttonStyle(.plain)
                    .help("立即更新（每 5 分鐘自動更新）")
                }

                let ps = store.providers
                if let a = advise(claude: ps[0], codex: ps[1]) {
                    AdviceRow(a: a)
                }

                HStack(alignment: .center, spacing: 16) {
                    ConcentricRings(providers: store.providers)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.providers) { LegendRow(p: $0) }
                    }
                }

                DetailList(providers: store.providers)

                if !store.conversations.isEmpty {
                    ConversationList(items: store.conversations)
                }

                HStack(spacing: 2) {
                    FooterButton(title: "開機啟動", symbol: launchAtLogin ? "checkmark.circle.fill" : "circle",
                                 active: launchAtLogin) { toggleLogin() }
                    Spacer()
                    FooterButton(title: "結束", symbol: "power") { NSApp.terminate(nil) }
                }
            }
            .padding(16)
            .frame(width: 350)
        }
    }

    func toggleLogin() {
        if launchAtLogin {
            LoginAgent.disable()
        } else {
            try? LoginAgent.writePlist()
            if LoginAgent.handOffToLaunchd() { NSApp.terminate(nil) }
        }
        launchAtLogin = LoginAgent.isEnabled
    }
}

/// 選單列顯示面板建議使用的服務；兩家都很低時顯示剩較多的一家。
func menuBarFocus(claude: Provider, codex: Provider) -> Provider? {
    let c = claude.tightest?.remainingPercent
    let x = codex.tightest?.remainingPercent
    if let c, c > lowRemaining { return claude }
    if let x, x > lowRemaining { return codex }
    switch (c, x) {
    case let (c?, x?): return c >= x ? claude : codex
    case (_?, nil): return claude
    case (nil, _?): return codex
    default: return nil
    }
}

/// 選單列：圓圈用彩色圖片，文字由系統直接繪製；圖片失敗時文字仍可點開看板。
struct MenuBarLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        let providers = store.providers
        let focus = menuBarFocus(claude: providers[0], codex: providers[1])
        HStack(spacing: 4) {
            Image(nsImage: renderRing(providers: providers, focus: focus))
            Self.text(focus, fallback: "AI 額度")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .fixedSize()
    }

    /// 服務名稱改用品牌色小圖示（✳／</>）畫在圓圈旁：選單列太擠時 macOS 會把最左邊的項目藏到瀏海後面，越窄越不容易被藏
    static func text(_ focus: Provider?, fallback: String) -> Text {
        guard let p = focus, let w = p.tightest else { return Text(fallback) }
        return Text("\(Int(w.remainingPercent.rounded()))%")
    }

    static func ringAndMark(providers: [Provider], focus: Provider?) -> some View {
        HStack(spacing: 3) {
            ConcentricRings(providers: providers, size: 17, line: 2.8, gap: 1.2)
            if let p = focus {
                Image(systemName: p.brand.symbol)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(p.brand.color)
            }
        }
    }

    @MainActor private func renderRing(providers: [Provider], focus: Provider?) -> NSImage {
        let content = Self.ringAndMark(providers: providers, focus: focus)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "AI 額度") ?? NSImage(size: NSSize(width: 17, height: 17))
    }

    /// 快照驗證用的完整選單列圖像。
    @MainActor func render(dark: Bool? = nil) -> NSImage {
        _ = store.appearanceTick
        let isDark = dark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let providers = store.providers
        let focus = menuBarFocus(claude: providers[0], codex: providers[1])
        let content = HStack(spacing: 4) {
            Self.ringAndMark(providers: providers, focus: focus)
                .environment(\.colorScheme, isDark ? .dark : .light)
            Self.text(focus, fallback: "–")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(isDark ? Color.white : Color.black.opacity(0.85))
        }
        .padding(.vertical, 1)
        let r = ImageRenderer(content: content)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        return r.nsImage ?? NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "AI 額度") ?? NSImage(size: NSSize(width: 17, height: 17))
    }
}

// MARK: - 開機啟動（LaunchAgent）

/// 登入時自動開；異常結束（當掉、被系統砍）由 launchd 自動重開；按「結束」是正常結束，不重開。
enum LoginAgent {
    static let label = "app.tipstudio.quotabar"
    static let executable = "/Applications/AI額度看板.app/Contents/MacOS/QuotaBar"
    static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static var domain: String { "gui/\(getuid())" }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    /// launchd 開的程式會帶 XPC_SERVICE_NAME＝label
    static var underLaunchd: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    static func writePlist() throws {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: plistURL)
    }

    /// 只刪設定檔：這次登入期間仍會在當掉時重開，下次登入起不再自動開
    static func disable() { try? FileManager.default.removeItem(at: plistURL) }

    /// 不是 launchd 開的（例如從 Finder 點開）就請 launchd 開一個接手，當掉才會被重開。回傳 true＝已交棒，自己該結束。
    static func handOffToLaunchd() -> Bool {
        guard isEnabled, !underLaunchd else { return false }
        launchctl(["bootstrap", domain, plistURL.path])  // 已載入時會失敗，無妨
        return launchctl(["kickstart", "\(domain)/\(label)"]) == 0
    }

    /// 舊版用 SMAppService 登記開機啟動；改成 LaunchAgent，避免登入時開兩個
    static func migrateFromLoginItem() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        try? writePlist()
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Finder 再次開啟已在執行的選單列 App 時，重建其選單列項目。
final class QuotaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.write("使用者重新開啟 App，重建選單列項目")
        if LoginAgent.underLaunchd {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = LoginAgent.launchctl(["kickstart", "-k", "\(LoginAgent.domain)/\(LoginAgent.label)"])
            }
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", "/Applications/AI額度看板.app"]
            try? p.run()
            sender.terminate(nil)
        }
        return false
    }
}

/// 驗證用：QuotaBar --snapshot out.png [--dark] → 抓一次資料、把面板與選單列畫成圖後結束。
@MainActor
func runSnapshot(to path: String, dark: Bool) {
    Task { @MainActor in
        let store = Store(autoRefresh: false)
        async let c = ClaudeFetcher.fetch()
        async let x = CodexFetcher.fetch()
        (store.claude, store.codex) = await (c, x)
        store.conversations = ConversationScanner.scan()
        if CommandLine.arguments.contains("--demo") {   // 示範資料：截圖用，不顯示真實對話名稱
            let now = Date()
            store.conversations = [
                Conversation(id: "demo1", tool: "Codex", name: "My web app", tokens: 291_000, updated: now),
                Conversation(id: "demo2", tool: "Claude", name: "Blog redesign", tokens: 193_000, updated: now),
            ]
        }
        store.updatedAt = Date()
        let scheme: ColorScheme = dark ? .dark : .light
        let view = VStack(spacing: 0) {
            HStack {
                Spacer()
                Image(nsImage: MenuBarLabel(store: store).render(dark: dark))
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .background(Color.primary.opacity(0.06))
            PanelView(store: store)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("saved", path)
        }
        exit(0)
    }
}

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(QuotaAppDelegate.self) private var appDelegate
    /// 拍快照時不開常駐的自動更新，免得和快照自己的讀取搶 security、甚至送出通知
    @StateObject private var store = Store(autoRefresh: !CommandLine.arguments.contains("--snapshot"))
    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            runSnapshot(to: args[i + 1], dark: args.contains("--dark"))
        } else {
            Notifier.setup()
            LoginAgent.migrateFromLoginItem()
            if LoginAgent.handOffToLaunchd() { exit(0) }
        }
    }
    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
