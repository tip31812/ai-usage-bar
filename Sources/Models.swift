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

