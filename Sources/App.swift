import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

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

