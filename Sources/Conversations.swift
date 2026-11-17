import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

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

