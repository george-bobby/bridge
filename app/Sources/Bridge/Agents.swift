import AppKit
import SwiftUI

// MARK: - Agents

enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, cursor, devin
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .devin: return "Devin"
        }
    }
    var color: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return T.text.opacity(0.88)
        case .cursor: return T.text2
        case .devin: return Color(red: 0.24, green: 0.72, blue: 0.62)
        }
    }
    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "hexagon"
        case .cursor: return "cursorarrow"
        case .devin: return "sparkle"
        }
    }
    var hint: String {
        switch self {
        case .claude: return "Claude Code. Runs inside Bridge's guard: risky writes come to you as Allow/Deny cards."
        case .codex: return "OpenAI Codex CLI. Uses its own sandbox and approvals; Bridge's guard doesn't apply."
        case .cursor: return "Cursor's agent CLI. Uses its own permissions; Bridge's guard doesn't apply."
        case .devin: return "Devin CLI. Uses its own permission modes; Bridge's guard doesn't apply."
        }
    }
    static func of(_ s: String) -> AgentKind { AgentKind(rawValue: s) ?? .claude }
}

/// Each agent's mark, at chat-avatar size or inline.
struct AgentMark: View {
    let agent: AgentKind
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27)
            .fill(agent == .claude ? agent.color : T.raised)
            .overlay(RoundedRectangle(cornerRadius: size * 0.27).stroke(agent == .claude ? .clear : T.line, lineWidth: 1))
            .overlay(Image(systemName: agent.symbol).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(agent == .claude ? .white : agent.color))
            .frame(width: size, height: size)
    }
}

// MARK: - Usage

struct UsageWindow: Identifiable, Hashable {
    let j: JSON
    var id: String { j["id"].string }
    var label: String { j["label"].string }
    var short: String { j["short"].string }
    var used: Double? { j["usedPct"].isNull ? nil : j["usedPct"].double }
    var resetsAt: Double? { j["resetsAt"].isNull ? nil : j["resetsAt"].double / 1000 }
    var duration: Double? { j["duration"].isNull ? nil : j["duration"].double }

    var tone: Color {
        guard let u = used else { return T.text3 }
        return u >= 90 ? T.red : u >= 70 ? T.orange : T.green
    }

    /// When it runs out at the current pace, if that's before the reset.
    var runsOut: Double? {
        guard let u = used, u > 0, u < 100, let r = resetsAt, let d = duration else { return nil }
        let now = Date().timeIntervalSince1970
        let elapsed = d - (r - now)
        guard elapsed > 600 else { return nil }
        let eta = now + (100 - u) / (u / elapsed)
        return eta < r ? eta : nil
    }
}

enum Countdown {
    static func until(_ t: Double?) -> String {
        guard let t else { return "" }
        let s = Int(t - Date().timeIntervalSince1970)
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(max(m, 1))m"
    }

    private static let dayClock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f }()
    private static let shortClock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()

    static func clock(_ t: Double) -> String {
        let date = Date(timeIntervalSince1970: t)
        return (date.timeIntervalSinceNow > 86400 ? dayClock : shortClock).string(from: date)
    }
}

struct UsageProvider: Identifiable {
    let j: JSON
    var id: String { j["id"].string }
    var agent: AgentKind { AgentKind.of(id) }
    var ok: Bool { j["status"].string == "ok" }
    var windows: [UsageWindow] { j["windows"].array.map(UsageWindow.init) }
    /// The window closest to its limit: what the status bar shows.
    var tightest: UsageWindow? { windows.filter { $0.used != nil }.max { ($0.used ?? 0) < ($1.used ?? 0) } }
    var plan: String { j["plan"].string }
    var account: String { j["account"].string }
    var reason: String { j["reason"].string }
    /// Facts to list as label/value rows.
    var facts: [JSON] { j["details"].array.filter { !$0["info"].bool } }
    /// Explanations shown as a note rather than a row ("no plan limits published").
    var notes: [String] { j["details"].array.filter { $0["info"].bool }.map { $0["value"].string } }
    /// How loud a problem is: a missing login is just information; a
    /// rejected login or a failed request is something to fix.
    var problemTone: Color {
        if j["status"].string == "error" { return T.red }
        let r = reason.lowercased()
        return r.contains("rejected") || r.contains("expired") || r.contains("rate limited") ? T.orange : T.text3
    }
}

extension AppModel {
    var usageProviders: [UsageProvider] { usage["providers"].array.map(UsageProvider.init) }

    func loadUsage(refresh: Bool = false) async {
        if let u = try? await API.get("/api/usage\(refresh ? "?refresh=1" : "")") { usage = u }
    }
}

struct UsageGauge: View {
    let provider: UsageProvider
    let window: UsageWindow
    @StateObject private var drawn = Box(false)

    var body: some View {
        let used = min(max((window.used ?? 0) / 100, 0), 1)
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(T.line, lineWidth: 2.2)
                Circle().trim(from: 0, to: drawn.v ? used : 0)
                    .stroke(window.tone, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: provider.agent.symbol).font(.system(size: 6.5, weight: .bold)).foregroundStyle(provider.agent.color)
            }
            .frame(width: 16, height: 16)
            Text(verbatim: "\(Int((window.used ?? 0).rounded()))%").font(T.ui(11, .semibold)).foregroundStyle(window.tone).monospacedDigit()
                .contentTransition(.numericText())
        }
        .help("\(provider.agent.label) · \(window.label) · resets in \(Countdown.until(window.resetsAt))")
        .onAppear { withAnimation(M.snappy.delay(0.15)) { drawn.v = true } }
        .animation(M.snappy, value: used)
    }
}

/// Every agent's windows, compactly: the sidebar's usage popover.
struct UsageCard: View {
    let providers: [UsageProvider]
    var open: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Plan usage").font(T.ui(13, .semibold)).foregroundStyle(T.text)
                Spacer()
                if let t = providers.map({ $0.j["fetchedAt"].double }).max(), t > 0 {
                    Text("Updated \(Fmt.ago(t / 1000) == "now" ? "just now" : Fmt.ago(t / 1000) + " ago")").font(T.ui(11)).foregroundStyle(T.text3)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            ForEach(providers) { p in
                Hairline()
                UsageCardRow(provider: p)
            }
            if let open {
                Hairline()
                Button(action: open) {
                    HStack(spacing: 6) {
                        Text("Open Usage")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(LButton())
                .padding(12)
            }
        }
        .frame(width: 340, alignment: .leading)
    }
}

struct UsageCardRow: View {
    let provider: UsageProvider

    var body: some View {
        let p = provider
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                AgentMark(agent: p.agent, size: 16)
                Text(p.agent.label).font(T.ui(12.5, .semibold)).foregroundStyle(T.text)
                if !p.plan.isEmpty { Text(p.plan).font(T.ui(11)).foregroundStyle(T.text3) }
                Spacer()
                if let w = p.tightest {
                    Text(verbatim: "\(Int((w.used ?? 0).rounded()))%").font(T.ui(12, .semibold)).foregroundStyle(w.tone).monospacedDigit()
                }
            }
            if !p.ok {
                UsageNote(text: p.reason, tone: p.problemTone)
            } else if p.windows.isEmpty {
                UsageNote(text: p.j["local"]["week"]["acu"].double > 0 ? String(format: "%.2f ACUs this week through Bridge", p.j["local"]["week"]["acu"].double) : (p.notes.first ?? "No plan limits published"), tone: T.text3)
            }
            ForEach(p.windows) { w in
                HStack(spacing: 10) {
                    Text(w.label).font(T.ui(11.5)).foregroundStyle(T.text2).frame(width: 96, alignment: .leading).lineLimit(1)
                    UsageBar(window: w, height: 4)
                    Text(Countdown.until(w.resetsAt)).font(T.ui(11)).foregroundStyle(T.text3).monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// A one-line explanation: info in grey, problems tinted.
struct UsageNote: View {
    let text: String
    var tone: Color = T.text3
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: tone == T.text3 ? "info.circle" : "exclamationmark.triangle").font(.system(size: 10.5, weight: .medium))
            Text(text).font(T.ui(11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone == T.text3 ? T.text2 : tone)
    }
}

struct UsageBar: View {
    let window: UsageWindow
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(T.line)
                Capsule().fill(window.tone).frame(width: max(height, g.size.width * CGFloat((window.used ?? 0) / 100)))
                    .opacity(window.used == nil ? 0 : 1)
            }
        }
        .frame(height: height)
    }
}

/// The Usage page: plan windows per agent, and what Bridge ran on each.
struct UsageView: View {
    @Environment(AppModel.self) var model
    @StateObject private var loading = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Usage", subtitle: "plan limits for every agent, and what Bridge ran on each", icon: "gauge.with.dots.needle.50percent") {
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: loading.v) {
                    loading.v = true
                    Task { await model.loadUsage(refresh: true); loading.v = false }
                }
            }
            ScrollView { content }
        }
        .onAppear { Task { await model.loadUsage() } }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.usageProviders.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(Array(model.usageProviders.enumerated()), id: \.element.id) { i, p in ProviderCard(provider: p).rise(i) }
            }
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 10, weight: .medium))
                Text("Read with each agent's own login on this Mac (Claude Code, Codex, cursor-agent). Bridge never refreshes or stores those tokens.")
            }
            .font(T.ui(11.5)).foregroundStyle(T.text3)
        }
        .padding(28)
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity)
    }
}

struct ProviderCard: View {
    let provider: UsageProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Hairline()
            VStack(alignment: .leading, spacing: 14) {
                status
                ForEach(provider.windows) { WindowMeter(window: $0) }
                if !provider.facts.isEmpty { facts }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            if !provider.j["local"].isNull {
                Hairline()
                HStack(alignment: .top, spacing: 0) {
                    LocalStat(title: "7 days", b: provider.j["local"]["week"], acu: provider.agent == .devin)
                    LocalStat(title: "30 days", b: provider.j["local"]["month"], acu: provider.agent == .devin)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(T.bg.opacity(0.35))
            }
        }
        .card()
    }

    var header: some View {
        HStack(spacing: 10) {
            AgentMark(agent: provider.agent, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(provider.agent.label).font(T.ui(14, .semibold)).foregroundStyle(T.text)
                    if !provider.plan.isEmpty { Chip(text: provider.plan) }
                }
                if !provider.account.isEmpty { Text(provider.account).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1) }
            }
            Spacer()
            if !provider.ok {
                Chip(text: provider.j["status"].string == "error" ? "Error" : "Unavailable", dot: provider.problemTone == T.text3 ? T.text3 : provider.problemTone)
            } else if let stale = provider.j["stale"].nonEmpty {
                Chip(text: "Stale", dot: T.orange).help(stale)
            } else if let w = provider.tightest {
                Text(verbatim: "\(Int((w.used ?? 0).rounded()))%").font(T.ui(20, .semibold)).foregroundStyle(w.tone).monospacedDigit()
                    .help("\(w.label): the window closest to its limit")
            }
        }
    }

    @ViewBuilder var status: some View {
        if !provider.ok {
            UsageNote(text: provider.reason, tone: provider.problemTone)
        }
        ForEach(provider.notes, id: \.self) { UsageNote(text: $0) }
        if provider.ok && provider.windows.isEmpty && provider.notes.isEmpty { UsageNote(text: "No plan limits published") }
    }

    var facts: some View {
        VStack(spacing: 0) {
            ForEach(Array(provider.facts.enumerated()), id: \.offset) { i, d in
                if i > 0 { Hairline() }
                HStack(alignment: .firstTextBaseline) {
                    Text(d["label"].string).font(T.ui(12)).foregroundStyle(T.text2)
                    Spacer(minLength: 12)
                    Text(d["value"].string).font(T.ui(12, .medium)).foregroundStyle(T.text).monospacedDigit().multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 7)
            }
        }
    }
}

struct WindowMeter: View {
    let window: UsageWindow
    var body: some View {
        let w = window
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(w.label).font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                Spacer()
                Text(w.used.map { "\(Int($0.rounded()))%" } ?? "—").font(T.ui(12.5, .semibold)).foregroundStyle(w.used == nil ? T.text3 : w.tone).monospacedDigit()
            }
            UsageBar(window: w, height: 6)
            HStack(spacing: 4) {
                if let r = w.resetsAt { Text("Resets in \(Countdown.until(r)) · \(Countdown.clock(r))") }
                if let out = w.runsOut {
                    Spacer()
                    Label("Runs out \(Countdown.clock(out))", systemImage: "exclamationmark.triangle.fill").foregroundStyle(T.orange)
                }
            }
            .font(T.ui(11)).foregroundStyle(T.text3)
        }
    }
}

struct LocalStat: View {
    let title: String
    let b: JSON
    let acu: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Through Bridge · \(title)").font(T.ui(11)).foregroundStyle(T.text3)
            HStack(spacing: 4) {
                Text(verbatim: "\(b["turns"].int) turns")
                Text("·").foregroundStyle(T.text3)
                Text(verbatim: "\(Fmt.tokens(b["tokens"].int)) tokens")
            }
            .font(T.ui(12, .medium)).foregroundStyle(T.text2).monospacedDigit()
            if acu { Text(String(format: "%.2f ACUs", b["acu"].double)).font(T.ui(12, .medium)).foregroundStyle(T.text2).monospacedDigit() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


// MARK: - Model picker

extension AppModel {
    func models(for agent: AgentKind) -> [JSON] {
        agentCatalog["agents"].array.first { $0["id"].string == agent.rawValue }?["models"].array ?? []
    }
    func installed(_ agent: AgentKind) -> Bool {
        let a = agentCatalog["agents"].array.first { $0["id"].string == agent.rawValue }
        return a.map { $0["installed"].bool } ?? (agent == .claude)
    }
}
