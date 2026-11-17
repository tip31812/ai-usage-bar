import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

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

