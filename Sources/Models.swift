import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

// MARK: - 語言

/// 介面語言：預設跟隨系統（中文系統→繁體中文，其餘→英文）；`--lang zh|en` 可強制指定（驗證／截圖用）。
enum Lang {
    static let zh: Bool = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--lang"), i + 1 < a.count { return a[i + 1].lowercased().hasPrefix("zh") }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }()
}
/// 依語言挑字串：tr("中文", "English")
func tr(_ zh: String, _ en: String) -> String { Lang.zh ? zh : en }

// MARK: - 服務（Provider）共同介面

/// 一個 AI 服務的外觀（名稱、圖示、顏色）
struct Brand {
    let name: String
    let symbol: String      // SF Symbol 名稱
    let color: Color
}

/// 每個 AI 服務實作這個介面，再加進 `Sources.all`（順序＝圓圈由外到內，第一個＝優先使用的主服務）。
protocol UsageSource {
    static var brand: Brand { get }
    /// 讀一次剩餘額度。失敗時不要丟錯，回傳帶 `error` 的 ProviderState。
    static func fetch(manual: Bool) async -> ProviderState
}

enum Sources {
    static let all: [UsageSource.Type] = [ClaudeFetcher.self, CodexFetcher.self]
    static func brand(named name: String) -> Brand? { all.first { $0.brand.name == name }?.brand }
}

// MARK: - 資料模型

struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var remainingPercent: Double { max(0, 100 - usedPercent) }
    /// `label` 是程式內部用的固定代號（中文）；顯示給人看用 `title`
    var title: String {
        switch label {
        case "5 小時": return tr(label, "5-hour")
        case "每日": return tr(label, "Daily")
        case "每週": return tr(label, "Weekly")
        case "每週 Opus": return tr(label, "Weekly Opus")
        case "每週 Sonnet": return tr(label, "Weekly Sonnet")
        default: return label
        }
    }
}

struct ProviderState {
    var windows: [UsageWindow] = []
    var plan: String?
    var live = false
    var source: String = tr("讀取中…", "Loading…")
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

