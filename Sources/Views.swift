import SwiftUI
import AppKit
import SQLite3
import ServiceManagement
import UserNotifications

// MARK: - 畫面

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
    if s <= 0 { return tr("即將更新", "Updating soon") }
    let day = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if day > 0 { return tr("\(day) 天 \(h) 小時", "\(day)d \(h)h") }
    if h > 0 { return tr("\(h) 小時 \(m) 分", "\(h)h \(m)m") }
    return tr("\(max(1, m)) 分鐘", "\(max(1, m))m")
}

/// 週重置剩幾天：滿 1 天說「天」，不到 1 天說「小時」
func daysLeft(_ d: Date) -> String {
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return tr("即將重置", "Resetting soon") }
    if s < 86400 { return tr("剩 \(max(1, s / 3600)) 小時", "\(max(1, s / 3600))h left") }
    return tr("剩 \(s / 86400) 天", "\(s / 86400)d left")
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
                Text(tr("週重置", "Resets")).foregroundStyle(hurry ? Color.orange : .secondary)
                Text(daysLeft(r)).fontWeight(.bold)
                if hurry { Text(tr("快用！", "Use it!")).fontWeight(.bold) }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(hurry ? Color.orange : Color.primary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill((hurry ? Color.orange : brand).opacity(0.13)))
            .help(tr("每週額度 \(clock(r)) 重置，還剩 \(Int(w.remainingPercent.rounded()))%", "Weekly quota resets \(clock(r)); \(Int(w.remainingPercent.rounded()))% left"))
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


// MARK: - 分流建議（Claude 優先：5 小時額度會回補，能用就先用）

struct Advice {
    let brand: Brand?     // nil＝兩家都快沒了
    let title: String
    let detail: String
}

/// 分流建議：`ps` 的第一個是主服務（優先使用，預設 Claude）；其餘依序當備用。
func advise(_ ps: [Provider]) -> Advice? {
    guard let primary = ps.first else { return nil }
    let others = Array(ps.dropFirst())
    if ps.allSatisfy({ $0.tightest == nil }) { return nil }
    let name = primary.brand.name
    if let c = primary.tightest, c.remainingPercent > lowRemaining {
        // 其他服務的每週快重置但還剩很多：分點工作給它，免得浪費
        for o in others {
            if let w = o.weekly, let r = w.resetsAt, shouldHurry(w) {
                return Advice(brand: primary.brand, title: tr("現在用 \(name)", "Use \(name) now"),
                              detail: tr("\(o.brand.name) \(daysLeft(r))就重置、還有 \(pct(w))，分點工作給它",
                                         "\(o.brand.name) resets in \(daysLeft(r)) with \(pct(w)) left — give it some work"))
            }
        }
        let tail = c.remainingPercent <= warnRemaining ? tr("，快到底了", " — almost out") : ""
        return Advice(brand: primary.brand, title: tr("現在用 \(name)", "Use \(name) now"),
                      detail: tr("\(c.title)還剩 \(pct(c))", "\(c.title) has \(pct(c)) left") + tail)
    }
    let back = primary.tightest.map { w in
        w.resetsAt.map { tr("\(name) \(clock($0)) 回補", "\(name) refills \(clock($0))") } ?? tr("\(name) 回補時間未知", "\(name) refill time unknown")
    } ?? tr("\(name) 讀不到資料", "\(name) data unavailable")
    if let o = others.first(where: { ($0.tightest?.remainingPercent ?? 0) > lowRemaining }), let x = o.tightest {
        return Advice(brand: o.brand, title: tr("先用 \(o.brand.name)", "Use \(o.brand.name) first"),
                      detail: tr("\(back)（\(o.brand.name) 剩 \(pct(x))）", "\(back) (\(o.brand.name) \(pct(x)) left)"))
    }
    let allLow = ps.count == 2 ? tr("兩家都快沒了", "Both almost out") : tr("全都快沒了", "All almost out")
    return Advice(brand: nil, title: allLow, detail: back)
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
                    Text(tr("未連線", "Not connected")).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                }
            }
            // 最緊的就是每週、而且有重置時間時，標籤已經講了，不再重複
            let weekly = p.weekly
            let badgeCovers = t != nil && t?.id == weekly?.id && weekly?.resetsAt != nil
            if !badgeCovers {
                Group {
                    if let t {
                        if let r = t.resetsAt { Text(tr("\(t.title) · \(shortCountdown(r))後重置", "\(t.title) · resets in \(shortCountdown(r))")) }
                        else { Text(tr("\(t.title) · 重置時間未知", "\(t.title) · reset unknown")) }
                    } else {
                        Text(p.state.error ?? tr("讀取中…", "Loading…"))
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
                        Text("\(p.brand.name) \(w.title)").foregroundStyle(.secondary)
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
            Text(tr("最近使用的對話（3 小時內）", "Recent conversations (last 3 hours)"))
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(items.prefix(4)) { c in
                HStack(spacing: 6) {
                    Circle().fill(Sources.brand(named: c.tool)?.color ?? .gray).frame(width: 6, height: 6)
                    Text(c.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(c.name)
                    Spacer(minLength: 6)
                    if c.tokens >= longConversation {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                            .foregroundStyle(c.tokens >= veryLongConversation ? Color.red : Color.orange)
                    }
                    Text(tokenText(c.tokens))
                        .fontWeight(.semibold)
                        .foregroundStyle(c.tokens >= veryLongConversation ? Color.red
                                         : c.tokens >= longConversation ? Color.orange : .secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 11).monospacedDigit())
            }
            if items.contains(where: { $0.tokens >= longConversation }) {
                Label(tr("超過 15 萬就算長對話，越長每句越耗額度；整理進度後開新對話較省", "Over 150k tokens is a long conversation — the longer it gets, the more each message costs. Summarize and start a new one to save usage."),
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
                    Text(tr("AI 額度", "AI Usage")).font(.system(size: 17, weight: .bold, design: .rounded))
                    if let u = store.updatedAt {
                        Text(tr(relative(u) + "更新", "Updated " + relative(u))).font(.system(size: 11)).foregroundStyle(.tertiary)
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
                    .help(tr("立即更新（每 5 分鐘自動更新）", "Refresh now (auto-refreshes every 5 min)"))
                }

                let ps = store.providers
                if let a = advise(ps) {
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
                    FooterButton(title: tr("開機啟動", "Launch at login"), symbol: launchAtLogin ? "checkmark.circle.fill" : "circle",
                                 active: launchAtLogin) { toggleLogin() }
                    Spacer()
                    FooterButton(title: tr("結束", "Quit"), symbol: "power") { NSApp.terminate(nil) }
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

/// 選單列顯示面板建議使用的服務（第一個還有額度的）；全都很低時顯示剩較多的一個。
func menuBarFocus(_ ps: [Provider]) -> Provider? {
    if let p = ps.first(where: { ($0.tightest?.remainingPercent ?? -1) > lowRemaining }) { return p }
    return ps.filter { $0.tightest != nil }
        .max { ($0.tightest?.remainingPercent ?? 0) < ($1.tightest?.remainingPercent ?? 0) }
}

/// 選單列：圓圈用彩色圖片，文字由系統直接繪製；圖片失敗時文字仍可點開看板。
struct MenuBarLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        let providers = store.providers
        let focus = menuBarFocus(providers)
        HStack(spacing: 4) {
            Image(nsImage: renderRing(providers: providers, focus: focus))
            Self.text(focus, fallback: tr("AI 額度", "AI Usage"))
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
        return renderer.nsImage ?? NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: tr("AI 額度", "AI Usage")) ?? NSImage(size: NSSize(width: 17, height: 17))
    }

    /// 快照驗證用的完整選單列圖像。
    @MainActor func render(dark: Bool? = nil) -> NSImage {
        _ = store.appearanceTick
        let isDark = dark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let providers = store.providers
        let focus = menuBarFocus(providers)
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
        return r.nsImage ?? NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: tr("AI 額度", "AI Usage")) ?? NSImage(size: NSSize(width: 17, height: 17))
    }
}

