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
        case .codex: return Color(white: 0.86)
        case .cursor: return Color(white: 0.62)
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

/// The composer's agent switch. Switching mid-session hands the work over:
/// the next agent's first turn opens with a briefing of everything so far.
struct AgentPicker: View {
    @Environment(AppModel.self) var model
    let runId: String
    let current: AgentKind

    var body: some View {
        Menu {
            ForEach(AgentKind.allCases) { a in
                Button {
                    Task { await model.setOpts(runId, ["agent": a.rawValue]) }
                    if a != current && model.openRun["messages"].array.contains(where: { $0["role"].string == "assistant" }) {
                        model.say("Next turn goes to \(a.label), with a handoff briefing")
                    }
                } label: {
                    if a == current { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                }
                .help(a.hint)
            }
        } label: {
            HStack(spacing: 5) {
                AgentMark(agent: current, size: 14)
                Text(current.label).font(T.ui(11.5, .medium))
                if current != .claude { Image(systemName: "shield.slash").font(.system(size: 9.5)).foregroundStyle(T.orange) }
            }
            .foregroundStyle(T.text2)
            .padding(.horizontal, 7).frame(height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(current.hint)
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

    static func clock(_ t: Double) -> String {
        let date = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.dateFormat = date.timeIntervalSinceNow > 86400 ? "EEE h:mm a" : "h:mm a"
        return f.string(from: date)
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
}

extension AppModel {
    var usageProviders: [UsageProvider] { usage["providers"].array.map(UsageProvider.init) }

    func loadUsage(refresh: Bool = false) async {
        if let u = try? await API.get("/api/usage\(refresh ? "?refresh=1" : "")") { usage = u }
    }
}

/// Bottom-right: each agent's tightest window, like "✳ 49% 4d 3h". Hover for
/// every window; click for the Usage page.
struct UsageStrip: View {
    @Environment(AppModel.self) var model
    @StateObject private var hover = Box(false)

    var body: some View {
        let providers = model.usageProviders.filter { $0.ok && $0.tightest != nil }
        if !providers.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                if hover.v { UsageCard(providers: model.usageProviders).transition(.opacity.combined(with: .move(edge: .bottom))) }
                Button { model.route = .usage } label: {
                    HStack(spacing: 10) {
                        Text("Used").font(T.ui(11)).foregroundStyle(T.text3)
                        ForEach(providers) { p in
                            if let w = p.tightest {
                                HStack(spacing: 4) {
                                    Image(systemName: p.agent.symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(p.agent.color)
                                    Text(verbatim: "\(Int((w.used ?? 0).rounded()))%").font(T.ui(11, .semibold)).foregroundStyle(w.tone).monospacedDigit()
                                    Text(Countdown.until(w.resetsAt)).font(T.ui(11)).foregroundStyle(T.text3).monospacedDigit()
                                }
                                .help("\(p.agent.label) · \(w.label)")
                            }
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(T.raised))
                    .overlay(Capsule().stroke(T.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover.v = h } }
            .padding(12)
        }
    }
}

/// The hover card: every agent's windows, compactly.
struct UsageCard: View {
    let providers: [UsageProvider]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(providers) { p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        AgentMark(agent: p.agent, size: 14)
                        Text(p.agent.label).font(T.ui(12, .semibold))
                        if !p.j["plan"].string.isEmpty { Chip(text: p.j["plan"].string) }
                        Spacer()
                    }
                    if !p.ok {
                        Text(p.j["reason"].string).font(T.ui(11)).foregroundStyle(T.orange).lineLimit(2)
                    } else if p.windows.isEmpty {
                        Text(p.j["local"]["week"]["acu"].double > 0 ? String(format: "%.2f ACUs this week through Bridge", p.j["local"]["week"]["acu"].double) : "No plan limits published").font(T.ui(11)).foregroundStyle(T.text3)
                    }
                    ForEach(p.windows) { w in
                        HStack(spacing: 8) {
                            Text(w.label).font(T.ui(11)).foregroundStyle(T.text2).frame(width: 110, alignment: .leading).lineLimit(1)
                            UsageBar(window: w).frame(width: 120)
                            Text(verbatim: "\(Int((w.used ?? 0).rounded()))%").font(T.ui(11, .medium)).monospacedDigit().frame(width: 32, alignment: .trailing)
                            Text(Countdown.until(w.resetsAt)).font(T.ui(11)).foregroundStyle(T.text3).frame(width: 50, alignment: .trailing)
                        }
                    }
                }
            }
            Text("Click for details").font(T.ui(10.5)).foregroundStyle(T.text3)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
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
            ScrollView {
                VStack(spacing: 14) {
                    if model.usageProviders.isEmpty { ProgressView().controlSize(.small).padding(40) }
                    ForEach(model.usageProviders) { p in ProviderCard(provider: p) }
                    Text("Read with each agent's own login on this Mac (Claude Code, Codex, Cursor). Bridge never refreshes or stores those tokens.")
                        .font(T.ui(11.5)).foregroundStyle(T.text3).padding(.top, 4)
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { Task { await model.loadUsage() } }
    }
}

struct ProviderCard: View {
    let provider: UsageProvider

    var body: some View {
        let p = provider
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AgentMark(agent: p.agent, size: 18)
                Text(p.agent.label).font(T.ui(13.5, .semibold))
                if !p.j["plan"].string.isEmpty { Chip(text: p.j["plan"].string) }
                Spacer()
                if !p.ok { HStack(spacing: 5) { Circle().fill(T.text3).frame(width: 6, height: 6); Text("Unavailable").font(T.ui(11.5)).foregroundStyle(T.text3) } }
                else if let stale = p.j["stale"].nonEmpty { Text(stale).font(T.ui(11)).foregroundStyle(T.orange).lineLimit(1) }
            }
            if !p.ok {
                Text(p.j["reason"].string).font(T.ui(12)).foregroundStyle(T.red.opacity(0.9))
            }
            ForEach(p.windows) { w in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(w.label).font(T.ui(12.5, .medium))
                        Spacer()
                        Text(w.used.map { "\(Int($0.rounded()))% used" } ?? "—").font(T.ui(12)).foregroundStyle(T.text2).monospacedDigit()
                    }
                    UsageBar(window: w, height: 6)
                    HStack(spacing: 6) {
                        if let r = w.resetsAt { Text("resets in \(Countdown.until(r)) · \(Countdown.clock(r))") }
                        if let out = w.runsOut { Text("· runs out \(Countdown.clock(out))").foregroundStyle(T.orange) }
                    }
                    .font(T.ui(11)).foregroundStyle(T.text3)
                }
            }
            ForEach(Array(p.j["details"].array.enumerated()), id: \.offset) { _, d in
                HStack { Text(d["label"].string).font(T.ui(12)).foregroundStyle(T.text2); Spacer(); Text(d["value"].string).font(T.ui(12)).foregroundStyle(T.text).multilineTextAlignment(.trailing) }
            }
            if !p.j["account"].string.isEmpty { Text(p.j["account"].string).font(T.ui(11.5)).foregroundStyle(T.text3) }
            if !p.j["local"].isNull {
                Hairline()
                HStack(spacing: 0) {
                    LocalStat(title: "Through Bridge · 7 days", b: p.j["local"]["week"], acu: p.agent == .devin)
                    LocalStat(title: "30 days", b: p.j["local"]["month"], acu: p.agent == .devin)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
    }
}

struct LocalStat: View {
    let title: String
    let b: JSON
    let acu: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(T.ui(11)).foregroundStyle(T.text3)
            HStack(spacing: 10) {
                Text(verbatim: "\(b["turns"].int) turns")
                Text(verbatim: "\(Fmt.tokens(b["tokens"].int)) tokens")
                if acu { Text(String(format: "%.2f ACUs", b["acu"].double)) } else if b["cost"].double > 0 { Text(Fmt.money(b["cost"].double)) }
            }
            .font(T.ui(12, .medium)).foregroundStyle(T.text2).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
