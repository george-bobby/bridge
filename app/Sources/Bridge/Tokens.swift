import SwiftUI
import AppKit

// Settings › Tokens: what the agents on this Mac spent (CodeBurn reads their
// local session logs and prices them), and the token savers that can be
// switched on for them (RTK, Caveman, Ponytail). Server: server/tokens.js.

struct TokensSettings: View {
    let q: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpendSection(q: q)
            SaversSection(q: q)
        }
    }
}

// MARK: Spend

struct SpendSection: View {
    let q: String
    @StateObject private var data = Box<JSON?>(nil)
    @StateObject private var period = Box("30days")
    @StateObject private var loading = Box(false)

    static let periods = [("today", "Today"), ("week", "7 days"), ("30days", "30 days"), ("month", "This month")]

    var d: JSON { data.v ?? .null }

    var body: some View {
        SSection(title: "Spend", detail: detail) {
            if Prefs.hit(q, "spend cost usage codeburn tokens calls sessions agent model project") {
                if data.v == nil || (loading.v && d["cost"].isNull) {
                    SRow(title: "Reading session logs…", detail: "CodeBurn's first run on a long history can take a minute") { ProgressView().controlSize(.small) }
                } else if !d["installed"].bool && d["ok"].bool {
                    SRow(title: "CodeBurn isn't installed", detail: "It reads each agent's local session logs and prices them", key: d["install"].string) { EmptyView() }
                } else if !d["ok"].bool {
                    SRow(title: "CodeBurn failed", detail: d["error"].string) { EmptyView() }
                } else {
                    SpendHeadline(d: d)
                    SpendTokens(d: d)
                    Breakdown(title: "By agent", rows: d["providers"].array, unit: "calls", count: "calls", currency: d["currency"].string)
                    Breakdown(title: "By model", rows: d["models"].array, unit: "calls", count: "calls", currency: d["currency"].string)
                    Breakdown(title: "By project", rows: d["projects"].array, unit: "sessions", count: "sessions", currency: d["currency"].string)
                    Breakdown(title: "By activity", rows: d["activities"].array, unit: "turns", count: "turns", currency: d["currency"].string)
                }
            }
        } trailing: {
            HStack(spacing: 6) {
                SSelect(value: period.v, choices: Self.periods) { p in period.v = p; load() }
                IconButton(icon: "arrow.clockwise", help: "Read the logs again", spinning: loading.v, size: B.small) { load(refresh: true) }
                    .disabled(loading.v)
            }
        }
        .task { load() }
    }

    var detail: String {
        var s = "From CodeBurn, which reads each agent's session logs on this Mac and prices them at list rates"
        if d["installed"].bool, let v = d["version"].nonEmpty { s += " (v\(v))" }
        return s
    }

    func load(refresh: Bool = false) {
        loading.v = true
        let p = period.v
        Task {
            var j: JSON
            do { j = try await API.request("GET", "/api/tokens/codeburn?period=\(p)\(refresh ? "&refresh=1" : "")", timeout: 330) }
            catch { j = .obj(["ok": .bool(false), "installed": .bool(true), "error": .str(error.localizedDescription)]) }
            if period.v == p { data.v = j }
            loading.v = false
        }
    }
}

enum Burn {
    static func money(_ v: Double, _ sym: String = "$") -> String {
        let s = sym.isEmpty ? "$" : sym
        if v >= 1000 { return s + String(format: "%.0f", v).grouped }
        return s + String(format: "%.2f", v)
    }
    static func count(_ v: Int) -> String {
        let d = Double(v)
        if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e4 { return String(format: "%.0fK", d / 1e3) }
        return String(v).grouped
    }
}

private extension String {
    /// 12345 → 12,345 without the locale (Text(verbatim:) everywhere here).
    var grouped: String {
        var out = ""
        for (i, c) in reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return String(out.reversed())
    }
}

struct SpendHeadline: View {
    let d: JSON
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: Burn.money(d["cost"].double, d["currency"].string)).font(T.ui(26, .semibold)).foregroundStyle(T.text).monospacedDigit()
                Text(verbatim: "\(d["label"].string) · \(Burn.count(d["calls"].int)) calls · \(Burn.count(d["sessions"].int)) sessions")
                    .font(T.ui(12)).foregroundStyle(T.text3)
            }
            Spacer()
            HStack(spacing: 18) {
                ForEach(SpendSection.periods, id: \.0) { p in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(p.1).font(T.ui(11)).foregroundStyle(T.text3)
                        Text(verbatim: Burn.money(d["totals"][p.0]["cost"].double, d["currency"].string)).font(T.ui(13, .medium)).foregroundStyle(T.text2).monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

struct SpendTokens: View {
    let d: JSON
    var body: some View {
        let t = d["tokens"]
        HStack(spacing: 0) {
            stat("Input", Burn.count(t["input"].int))
            stat("Output", Burn.count(t["output"].int))
            stat("Cache read", Burn.count(t["cacheRead"].int))
            stat("Cache write", Burn.count(t["cacheWrite"].int))
            stat("Cache hit", "\(d["cacheHit"].int)%")
            stat("One-shot edits", "\(d["oneShot"].int)%")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(T.ui(11)).foregroundStyle(T.text3)
            Text(verbatim: value).font(T.ui(13, .medium)).foregroundStyle(T.text).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One group (agents, models…): name, a bar scaled to the top row, cost.
struct Breakdown: View {
    let title: String
    let rows: [JSON]
    let unit: String
    let count: String
    let currency: String

    var body: some View {
        let peak = max(rows.map { $0["cost"].double }.max() ?? 0, 0.01)
        HStack(alignment: .top, spacing: 16) {
            Text(title).font(T.ui(13, .medium)).foregroundStyle(T.text).frame(width: 96, alignment: .leading)
            VStack(spacing: 7) {
                if rows.isEmpty { Text("Nothing in this period").font(T.ui(12)).foregroundStyle(T.text3).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 10) {
                        Text(r["name"].string).font(T.ui(12)).foregroundStyle(T.text2).lineLimit(1).frame(width: 130, alignment: .leading)
                        GeometryReader { g in
                            Capsule().fill(T.accent.opacity(0.55)).frame(width: max(3, g.size.width * r["cost"].double / peak), height: 6)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 14)
                        Text(verbatim: "\(Burn.count(r[count].int)) \(unit)").font(T.ui(11)).foregroundStyle(T.text3).monospacedDigit().frame(width: 92, alignment: .trailing)
                        Text(verbatim: Burn.money(r["cost"].double, currency)).font(T.ui(12, .medium)).foregroundStyle(T.text).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: Token savers

struct SaversSection: View {
    let q: String
    @Environment(AppModel.self) var model
    @StateObject private var savers = Box<[JSON]>([])
    @StateObject private var busy = Box("")

    var body: some View {
        SSection(title: "Token savers", detail: "Off unless you turn them on. Each switch runs the commands its project documents, shown to you first; new sessions pick up the change") {
            ForEach(savers.v, id: \.self["id"].string) { s in
                if Prefs.hit(q, "token savers reduce", s["name"].string, s["blurb"].string) { row(s) }
            }
        }
        .task { await load() }
    }

    func row(_ s: JSON) -> some View {
        let id = s["id"].string
        var detail = s["blurb"].string
        if let stats = s["stats"].nonEmpty { detail += "\n\(stats)" }
        return SRow(title: s["name"].string, detail: detail) {
            HStack(spacing: 10) {
                ForEach(s["agents"].array, id: \.self["agent"].string) { a in
                    Chip(text: a["agent"].string, dot: a["on"].bool ? T.green : T.text3.opacity(0.4))
                }
                Chip(text: s["installed"].bool ? "Installed" : "Not installed")
                if let u = URL(string: s["url"].string) {
                    IconButton(icon: "arrow.up.right.square", help: s["url"].string, size: B.small) { NSWorkspace.shared.open(u) }
                }
                if busy.v == id { ProgressView().controlSize(.small) }
                SToggle(on: Binding(get: { s["enabled"].bool }, set: { on in flip(s, on) }))
                    .disabled(!busy.v.isEmpty)
            }
        }
    }

    func load() async {
        if let j = try? await API.get("/api/tokens/savers") { savers.v = j["savers"].array }
    }

    /// Shows the exact commands and what they touch, then runs them.
    func flip(_ s: JSON, _ on: Bool) {
        let cmds = s[on ? "enable" : "disable"].array.map { $0.array.map(\.string).joined(separator: " ") }
        let a = NSAlert()
        a.messageText = "\(on ? "Turn on" : "Turn off") \(s["name"].string)?"
        a.informativeText = "Bridge will run:\n\n" + cmds.joined(separator: "\n") + "\n\n" + s["changes"].string
        a.addButton(withTitle: on ? "Turn On" : "Turn Off")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let id = s["id"].string
        busy.v = id
        Task {
            await model.act {
                _ = try await API.request("POST", "/api/tokens/savers", ["id": id, "on": on], timeout: 900)
                model.say("\(s["name"].string) \(on ? "on" : "off") for new sessions")
            }
            await load()
            busy.v = ""
        }
    }
}
