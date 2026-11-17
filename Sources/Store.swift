import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

// MARK: - 時間文字

func relative(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return tr("剛剛", "just now") }
    if s < 3600 { return tr("\(s / 60) 分鐘前", "\(s / 60) min ago") }
    if s < 86400 { return tr("\(s / 3600) 小時前", "\(s / 3600) h ago") }
    return tr("\(s / 86400) 天前", "\(s / 86400) d ago")
}

func clock(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: Lang.zh ? "zh_TW" : "en_US")
    let today = Calendar.current.isDateInToday(d)
    f.dateFormat = Lang.zh ? (today ? "今天 HH:mm" : "M/d（EEE）HH:mm") : (today ? "'Today' HH:mm" : "EEE M/d HH:mm")
    return f.string(from: d)
}

// MARK: - 狀態

@MainActor
final class Store: ObservableObject {
    /// 與 `Sources.all` 同順序
    @Published var states: [ProviderState] = Sources.all.map { _ in ProviderState() }
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
            async let fetched = Store.fetchAll(manual: manual)
            await refreshConversations()
            states = await fetched
            let ps = providers
            Notifier.checkPrimary(ps)
            if let first = states.first { Notifier.checkClaudeLogin(first) }
            updatedAt = Date()
            loading = false
            scheduleResetRefresh()
        }
    }

    /// 所有服務同時讀取，結果依 `Sources.all` 順序回傳
    static func fetchAll(manual: Bool) async -> [ProviderState] {
        await withTaskGroup(of: (Int, ProviderState).self) { group in
            for (i, source) in Sources.all.enumerated() {
                group.addTask { (i, await source.fetch(manual: manual)) }
            }
            var out = Sources.all.map { _ in ProviderState() }
            for await (i, s) in group { out[i] = s }
            return out
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
        zip(Sources.all, states).map { Provider(brand: $0.brand, state: $1) }
    }
}

