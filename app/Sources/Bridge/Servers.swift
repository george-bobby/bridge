import AppKit
import SwiftUI

// MCP servers for the four agents (server/mcp.js): the Settings pane, the
// editor and tools sheets, and the composer's MCP menu. Every change is
// written by the server into the agent's own config; env and header values
// never come back, so an edit that leaves one blank keeps it.

// MARK: - Data

struct MCPServer: Identifiable, Hashable {
    let j: JSON
    var id: String { "\(agent.rawValue)|\(name)" }
    var name: String { j["name"].string }
    var agent: AgentKind { AgentKind.of(j["agent"].string) }
    var type: String { j["type"].string }
    var remote: Bool { type != "stdio" }
    var command: String { j["command"].string }
    var args: [String] { j["args"].array.map(\.string) }
    var url: String { j["url"].string }
    var envKeys: [String] { j["envKeys"].array.map(\.string) }
    var headerKeys: [String] { j["headerKeys"].array.map(\.string) }
    var bearerEnv: String { j["bearerEnv"].string }
    var scope: String { j["scope"].string }
    var source: String { j["source"].string }
    var enabled: Bool { j["enabled"].bool }
    var editable: Bool { j["editable"].bool }
    var removable: Bool { j["removable"].bool }
    var toggleable: Bool { j["toggleable"].bool }
    var sharedWith: [AgentKind] { j["sharedWith"].array.map { AgentKind.of($0.string) } }
    var note: String { j["note"].string }
    var status: String { j["status"].string }
    var error: String { j["error"].string }
    var toolCount: Int? { j["toolCount"].isNull ? nil : j["toolCount"].int }
    var toolNames: [String] { j["tools"].array.map { $0["name"].string } }

    /// The command line or URL, the way you'd type it.
    var line: String {
        if remote { return url }
        return ([command] + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }).joined(separator: " ")
    }

    var group: String {
        switch scope {
        case "project": return "In this project"
        case "plugin": return "From plugins"
        case "claudeai": return "claude.ai connectors"
        default: return "Yours"
        }
    }
}

enum MCPStatus {
    static func tone(_ s: String) -> Color {
        switch s {
        case "connected", "signed-in": return T.green
        case "needs-auth": return T.orange
        case "failed": return T.red
        case "pending", "checking": return T.yellow
        default: return T.text3
        }
    }

    static func label(_ s: MCPServer, checking: Bool) -> String {
        switch s.status {
        case "connected": return s.toolCount.map { $0 == 1 ? "Connected · 1 tool" : "Connected · \($0) tools" } ?? "Connected"
        case "signed-in": return s.toolCount.map { "Signed in · \($0) tools" } ?? "Signed in"
        case "needs-auth": return "Needs sign-in"
        case "oauth": return s.toolCount.map { "Signs in through \(s.agent.label) · \($0) tools" } ?? "Signs in through \(s.agent.label)"
        case "failed": return "Can't connect"
        case "disabled": return "Off"
        case "pending": return "Starting…"
        default: return checking ? "Checking…" : "Not checked"
        }
    }
}

@MainActor
final class MCPStore: ObservableObject {
    static let shared = MCPStore()

    /// By agent (Settings, the default repo) or "agent|run" (a chat's worktree).
    @Published var lists: [String: JSON] = [:]
    @Published var loading: Set<String> = []
    @Published var busy: Set<String> = []
    @Published var tools: [String: JSON] = [:]
    @Published var selected = UserDefaults.standard.string(forKey: "mcp.agent") ?? "claude" {
        didSet { UserDefaults.standard.set(selected, forKey: "mcp.agent") }
    }

    static func key(_ agent: AgentKind, _ run: String?) -> String { run.map { "\(agent.rawValue)|\($0)" } ?? agent.rawValue }
    static func query(_ run: String?, refresh: Bool = false) -> String {
        var q: [String] = []
        if let run { q.append("run=\(API.q(run))") }
        if refresh { q.append("refresh=1") }
        return q.isEmpty ? "" : "?" + q.joined(separator: "&")
    }

    func list(_ agent: AgentKind, run: String? = nil) -> JSON { lists[Self.key(agent, run)] ?? .null }
    func servers(_ agent: AgentKind, run: String? = nil) -> [MCPServer] { list(agent, run: run)["servers"].array.map(MCPServer.init) }
    func checking(_ agent: AgentKind, run: String? = nil) -> Bool { list(agent, run: run)["checking"].bool || loading.contains(Self.key(agent, run)) }

    func load(_ agent: AgentKind, run: String? = nil, refresh: Bool = false) async {
        let k = Self.key(agent, run)
        if refresh { loading.insert(k) }
        defer { if refresh { loading.remove(k) } }
        if let out = try? await API.get("/api/mcp/\(agent.rawValue)\(Self.query(run, refresh: refresh))") {
            if lists[k] != out { withAnimation(M.snappy) { lists[k] = out } }
        }
    }

    func loadAll(refresh: Bool = false) async {
        await withTaskGroup(of: Void.self) { g in
            for a in AgentKind.allCases { g.addTask { await self.load(a, refresh: refresh) } }
        }
    }

    /// The server's `mcp` event: a check finished or a config changed.
    func changed(_ agent: String) {
        let a = AgentKind.of(agent)
        for k in lists.keys where k == a.rawValue || k.hasPrefix("\(a.rawValue)|") {
            let run = k.contains("|") ? String(k.split(separator: "|", maxSplits: 1)[1]) : nil
            Task { await load(a, run: run) }
        }
        tools = tools.filter { !$0.key.hasPrefix("\(a.rawValue)|") }
    }

    func setEnabled(_ s: MCPServer, _ on: Bool, run: String?, model: AppModel) async {
        busy.insert(s.id)
        defer { busy.remove(s.id) }
        // Optimistic: the switch moves now; a refusal puts it back.
        let k = Self.key(s.agent, run)
        if var o = lists[k]?.object, var arr = o["servers"]?.array, let i = arr.firstIndex(where: { $0["name"].string == s.name }) {
            var row = arr[i].object
            row["enabled"] = .bool(on)
            row["status"] = .str(on ? "unknown" : "disabled")
            arr[i] = .obj(row)
            o["servers"] = .arr(arr)
            withAnimation(M.snappy) { lists[k] = .obj(o) }
        }
        await model.act {
            try await API.post("/api/mcp/\(s.agent.rawValue)/\(API.q(s.name))/enabled\(Self.query(run))", ["enabled": on])
            model.say(on ? "Turned on \(s.name) for \(s.agent.label)" : "Turned off \(s.name) for \(s.agent.label)")
        }
        await load(s.agent, run: run)
        if run != nil { await load(s.agent) }
    }

    func remove(_ s: MCPServer, model: AppModel) async {
        let a = NSAlert()
        a.messageText = "Remove \(s.name) from \(s.agent.label)?"
        a.informativeText = s.sharedWith.isEmpty ? "It's deleted from \(s.source)." : "It's deleted from \(s.source), which \(s.sharedWith.map(\.label).joined(separator: " and ")) loads too."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy.insert(s.id)
        defer { busy.remove(s.id) }
        await model.act {
            try await API.delete("/api/mcp/\(s.agent.rawValue)/\(API.q(s.name))")
            model.say("Removed \(s.name) from \(s.agent.label)")
        }
        await load(s.agent)
    }

    func login(_ s: MCPServer, model: AppModel) async {
        await model.act {
            try await API.post("/api/mcp/\(s.agent.rawValue)/\(API.q(s.name))/login")
            model.say("\(s.agent.label) opened the sign-in for \(s.name) in your browser")
        }
    }

    func loadTools(_ s: MCPServer, run: String?, refresh: Bool = false) async {
        if tools[s.id] != nil && !refresh { return }
        if refresh { tools[s.id] = nil }
        let out = (try? await API.get("/api/mcp/\(s.agent.rawValue)/\(API.q(s.name))/tools\(Self.query(run, refresh: refresh))")) ?? .obj(["error": .str("Couldn't reach the server")])
        tools[s.id] = out
    }
}

extension AppModel {
    func openMCPSettings(_ agent: AgentKind) {
        MCPStore.shared.selected = agent.rawValue
        settingsPane = SettingsPane.mcp.rawValue
        navigate(.settings)
    }
}

/// What the overlay sheet shows: the editor (add or edit) or a tools list.
enum MCPSheet: Equatable {
    case add(AgentKind)
    case edit(MCPServer)
    case tools(MCPServer, run: String?)
}

// MARK: - Shared pieces

/// The transport mark with a status dot on its corner.
struct MCPMark: View {
    let server: MCPServer
    var checking = false
    var size: CGFloat = 30

    var body: some View {
        let tone = server.status == "unknown" && checking ? T.yellow : MCPStatus.tone(server.status)
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(T.raised)
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).stroke(T.line, lineWidth: 1))
            .overlay(Image(systemName: server.scope == "claudeai" ? "cloud" : server.remote ? "globe" : "terminal").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(server.enabled ? T.text2 : T.text3))
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(tone).frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().stroke(T.panel, lineWidth: 2))
                    .offset(x: 2, y: 2)
                    .opacity(server.status == "unknown" && !checking ? 0.6 : 1)
            }
            .frame(width: size, height: size)
            .opacity(server.enabled ? 1 : 0.7)
    }
}

/// "Connected · 12 tools", tinted by health.
struct MCPStatusLine: View {
    let server: MCPServer
    var checking = false

    var body: some View {
        let s = server
        let busy = s.status == "unknown" && checking
        HStack(spacing: 5) {
            Circle().fill(busy ? T.yellow : MCPStatus.tone(s.status)).frame(width: 6, height: 6)
            Text(MCPStatus.label(s, checking: checking)).font(T.ui(11.5, .medium))
                .foregroundStyle(s.status == "failed" ? T.red : s.status == "needs-auth" ? T.orange : T.text3)
                .shimmer(busy)
            if !s.error.isEmpty && s.enabled && s.status != "oauth" {
                Text(s.error).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.tail).help(s.error)
            }
        }
    }
}

struct ScopeChips: View {
    let server: MCPServer
    var body: some View {
        HStack(spacing: 4) {
            if server.scope == "local" { Chip(text: "This project") }
            if server.scope == "project" { Chip(text: "Repo file") }
            if !server.sharedWith.isEmpty {
                Chip(text: "Shared with \(server.sharedWith.map(\.label).joined(separator: ", "))", icon: "link")
                    .help(server.note)
            }
        }
    }
}

// MARK: - Settings pane

struct MCPSettings: View {
    @Environment(AppModel.self) var model
    @ObservedObject var store = MCPStore.shared
    let q: String

    var agent: AgentKind { AgentKind.of(store.selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if q.isEmpty {
                AgentCards(store: store)
                    .padding(.bottom, 24)
                agentHeader
                AgentServers(agent: agent, q: "")
                    .id(agent)
                    .transition(.opacity)
            } else {
                ForEach(AgentKind.allCases) { a in AgentServers(agent: a, q: q) }
            }
        }
        .animation(M.snappy, value: store.selected)
        .task { await store.loadAll() }
    }

    var agentHeader: some View {
        let l = store.list(agent)
        let files = l["files"].array.map(\.string)
        return HStack(alignment: .center, spacing: 10) {
            AgentMark(agent: agent, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.label)'s servers").font(T.ui(13, .semibold)).foregroundStyle(T.text)
                if !files.isEmpty {
                    Text(files.joined(separator: "  ·  ")).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer()
            IconButton(icon: "arrow.clockwise", help: "Check every server again", spinning: store.checking(agent)) {
                Task { await store.load(agent, refresh: true) }
            }
            Button { model.mcpSheet = .add(agent) } label: { Label("Add server", systemImage: "plus") }
                .buttonStyle(LButton(primary: true))
                .disabled(!l["installed"].bool && !l.isNull)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 12)
    }
}

/// The four agents side by side: how many servers each loads and how they're doing.
struct AgentCards: View {
    @ObservedObject var store: MCPStore

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AgentKind.allCases) { a in
                AgentCard(agent: a, list: store.list(a), checking: store.checking(a), on: store.selected == a.rawValue) {
                    store.selected = a.rawValue
                }
            }
        }
    }
}

struct AgentCard: View {
    let agent: AgentKind
    let list: JSON
    let checking: Bool
    let on: Bool
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let servers = list["servers"].array.map(MCPServer.init)
        let enabled = servers.filter(\.enabled)
        let bad = enabled.filter { $0.status == "failed" || $0.status == "needs-auth" }.count
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    AgentMark(agent: agent, size: 20)
                    Text(agent.label).font(T.ui(13, .semibold)).foregroundStyle(T.text)
                    Spacer(minLength: 0)
                    if checking { ProgressView().controlSize(.mini).transition(.opacity) }
                }
                summary(servers: servers, enabled: enabled.count, bad: bad)
                health(enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? T.selected : hover.v ? T.hover : T.raised.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(on ? T.accent.opacity(0.7) : T.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
        .hoverBox(hover)
        .animation(M.snappy, value: on)
    }

    @ViewBuilder func summary(servers: [MCPServer], enabled: Int, bad: Int) -> some View {
        if list.isNull {
            Text("Loading…").font(T.ui(11.5)).foregroundStyle(T.text3).shimmer()
        } else if !list["installed"].bool {
            Text("Not installed").font(T.ui(11.5)).foregroundStyle(T.text3)
        } else {
            HStack(spacing: 4) {
                Text(verbatim: "\(enabled) of \(servers.count) on").foregroundStyle(T.text2)
                Spacer(minLength: 4)
                if bad > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9.5))
                        Text(verbatim: "\(bad)")
                    }
                    .foregroundStyle(T.orange)
                    .help(bad == 1 ? "1 server needs you" : "\(bad) servers need you")
                }
            }
            .font(T.ui(11.5, .medium)).monospacedDigit().lineLimit(1)
        }
    }

    /// One segment per enabled server, coloured by health.
    func health(_ enabled: [MCPServer]) -> some View {
        HStack(spacing: 2) {
            if enabled.isEmpty {
                Capsule().fill(T.line).frame(height: 4)
            } else {
                ForEach(enabled) { s in
                    Capsule().fill(s.status == "unknown" && checking ? T.yellow.opacity(0.5) : MCPStatus.tone(s.status).opacity(s.status == "unknown" ? 0.4 : 0.9)).frame(height: 4)
                }
            }
        }
        .animation(M.snappy, value: enabled.map(\.status))
    }
}

/// One agent's servers, as cards grouped by where they come from.
struct AgentServers: View {
    @Environment(AppModel.self) var model
    @ObservedObject var store = MCPStore.shared
    let agent: AgentKind
    let q: String

    var body: some View {
        let l = store.list(agent)
        let servers = store.servers(agent).filter { Prefs.hit(q, $0.name, $0.line, $0.source, agent.label, "mcp server tools") }
        let groups = ["Yours", "In this project", "From plugins", "claude.ai connectors"]
        VStack(alignment: .leading, spacing: 0) {
            if q.isEmpty && l.isNull {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
            } else if q.isEmpty && !l["installed"].bool {
                notInstalled
            } else if q.isEmpty && servers.isEmpty {
                empty
            }
            ForEach(groups, id: \.self) { g in
                let rows = servers.filter { $0.group == g }
                SSection(title: q.isEmpty ? g : "\(agent.label) · \(g)", detail: q.isEmpty ? blurb(g) : "") {
                    ForEach(rows) { s in MCPRow(server: s, checking: store.checking(agent)) }
                }
            }
        }
    }

    func blurb(_ g: String) -> String {
        switch g {
        case "In this project": return "Checked into the repo; edit the file to change them"
        case "From plugins": return agent == .devin ? "Installed with Devin plugins. Turning one off adds an override to ~/.config/devin/mcp_config.json" : "Installed with \(agent.label) plugins"
        case "claude.ai connectors": return "Connected on claude.ai. On/off applies to this project"
        default: return agent == .claude || agent == .cursor ? "Turning one off moves it out of \(agent.label)'s config until you turn it back on" : ""
        }
    }

    var notInstalled: some View {
        HStack(spacing: 12) {
            AgentMark(agent: agent, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.label) isn't installed").font(T.ui(13, .medium)).foregroundStyle(T.text)
                Text("Install its CLI and it shows up here with the servers it loads.").font(T.ui(12)).foregroundStyle(T.text3)
            }
            Spacer()
        }
        .padding(16).card(radius: 10).padding(.bottom, 28)
    }

    var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 22, weight: .light)).foregroundStyle(T.text3)
                .frame(width: 48, height: 48).background(Circle().fill(T.raised))
            Text("\(agent.label) has no MCP servers").font(T.ui(13, .medium)).foregroundStyle(T.text2)
            Text("Add one to give its sessions more tools: a database, a browser, your issue tracker.").font(T.ui(12)).foregroundStyle(T.text3).multilineTextAlignment(.center)
            Button { model.mcpSheet = .add(agent) } label: { Label("Add server", systemImage: "plus") }.buttonStyle(LButton())
        }
        .frame(maxWidth: .infinity).padding(32).card(radius: 10).padding(.bottom, 28)
    }
}

/// One server: mark, name and command, status, tools, the switch and its menu.
struct MCPRow: View {
    @Environment(AppModel.self) var model
    @ObservedObject var store = MCPStore.shared
    let server: MCPServer
    let checking: Bool
    @StateObject private var hover = Box(false)

    var body: some View {
        let s = server
        HStack(alignment: .center, spacing: 12) {
            MCPMark(server: s, checking: checking)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(s.name).font(T.ui(13, .medium)).foregroundStyle(s.enabled ? T.text : T.text2).lineLimit(1)
                    ScopeChips(server: s)
                }
                Text(s.line.isEmpty ? s.source : s.line).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle).help(s.line)
                MCPStatusLine(server: s, checking: checking)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(hover.v ? T.hover.opacity(0.45) : .clear)
        .contentShape(Rectangle())
        .hoverBox(hover)
        .contextMenu { menuItems }
        .animation(M.snappy, value: s.status)
    }

    @ViewBuilder var trailing: some View {
        let s = server
        HStack(spacing: 8) {
            if s.status == "needs-auth" && s.enabled {
                Button("Sign in") { Task { await store.login(s, model: model) } }.buttonStyle(LButton())
            }
            if let n = s.toolCount, s.enabled {
                Button { model.mcpSheet = .tools(s, run: nil) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver").font(.system(size: 10, weight: .medium))
                        Text(verbatim: "\(n)").monospacedDigit()
                    }
                }
                .buttonStyle(LButton())
                .help("Show its tools")
            }
            if store.busy.contains(s.id) {
                ProgressView().controlSize(.small).frame(width: 38)
            } else {
                SToggle(on: Binding(get: { s.enabled }, set: { v in Task { await store.setEnabled(s, v, run: nil, model: model) } }))
                    .disabled(!s.toggleable)
                    .help(s.toggleable ? (s.enabled ? "Turn off" : "Turn on") : s.note)
            }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(T.text2).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        }
    }

    @ViewBuilder var menuItems: some View {
        let s = server
        Button { model.mcpSheet = .edit(s) } label: { Label("Edit…", systemImage: "pencil") }.disabled(!s.editable)
        Button { model.mcpSheet = .tools(s, run: nil) } label: { Label("Show Tools", systemImage: "wrench.and.screwdriver") }
        if s.remote { Button { Task { await store.login(s, model: model) } } label: { Label("Sign In…", systemImage: "person.badge.key") } }
        Divider()
        if !s.line.isEmpty { Button { copyToPasteboard(s.line) } label: { Label(s.remote ? "Copy URL" : "Copy Command", systemImage: "doc.on.doc") } }
        if !s.note.isEmpty { Text(s.note) }
        Divider()
        Button(role: .destructive) { Task { await store.remove(s, model: model) } } label: { Label("Remove…", systemImage: "trash") }.disabled(!s.removable)
    }
}

// MARK: - Editor

struct KV: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
    /// Set on the server: blank keeps it.
    var stored = false
}

@MainActor
final class MCPForm: ObservableObject {
    @Published var name = ""
    @Published var type = "stdio"
    @Published var command = ""
    @Published var args: [KV] = []
    @Published var env: [KV] = []
    @Published var url = ""
    @Published var headers: [KV] = []
    @Published var bearerEnv = ""
    @Published var targets: Set<AgentKind> = []
    @Published var error = ""
    @Published var saving = false

    func fill(_ s: MCPServer) {
        name = s.name
        type = s.type == "sse" ? "sse" : s.remote ? "http" : "stdio"
        command = s.command
        args = s.args.map { KV(key: $0, value: "") }
        env = s.envKeys.map { KV(key: $0, value: "", stored: true) }
        url = s.url
        headers = s.headerKeys.map { KV(key: $0, value: "", stored: true) }
        bearerEnv = s.bearerEnv
        targets = [s.agent]
    }

    /// `npx -y pkg --flag "a b"` pasted whole into Command: split it up.
    func splitCommand() {
        guard args.isEmpty, command.contains(" ") else { return }
        var parts: [String] = []
        var cur = ""
        var quote: Character? = nil
        for ch in command {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == " " { if !cur.isEmpty { parts.append(cur); cur = "" } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { parts.append(cur) }
        guard parts.count > 1 else { return }
        command = parts[0]
        args = parts.dropFirst().map { KV(key: $0, value: "") }
    }

    var body: [String: Any] {
        var f: [String: Any] = ["type": type]
        if type == "stdio" {
            f["command"] = command.trimmingCharacters(in: .whitespaces)
            f["args"] = args.map(\.key)
            f["env"] = env.filter { !$0.key.isEmpty }.map { ["key": $0.key, "value": $0.value] }
        } else {
            f["url"] = url.trimmingCharacters(in: .whitespaces)
            f["headers"] = headers.filter { !$0.key.isEmpty }.map { ["key": $0.key, "value": $0.value] }
            if !bearerEnv.isEmpty { f["bearerEnv"] = bearerEnv }
        }
        return f
    }
}

struct MCPEditor: View {
    @Environment(AppModel.self) var model
    let sheet: MCPSheet
    @StateObject private var form = MCPForm()

    var editing: MCPServer? { if case .edit(let s) = sheet { return s }; return nil }
    var firstAgent: AgentKind { if case .add(let a) = sheet { return a }; return editing?.agent ?? .claude }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView { fields.padding(20) }
                .scrollIndicators(.never)
                .frame(maxHeight: 520)
            Hairline()
            footer
        }
        .frame(width: 620)
        .floatingPanel()
        .onAppear {
            if let s = editing { form.fill(s) } else { form.targets = [firstAgent] }
        }
        .onKeyPress(.escape) { model.mcpSheet = nil; return .handled }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 13, weight: .medium)).foregroundStyle(T.accent)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.accentSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(editing == nil ? "Add an MCP server" : "Edit \(editing!.name)").font(T.ui(14, .semibold)).foregroundStyle(T.text)
                Text(editing?.source ?? "Written to each agent's own config").font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer()
            IconButton(icon: "xmark", help: "Close (Esc)") { model.mcpSheet = nil }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    var fields: some View {
        VStack(alignment: .leading, spacing: 18) {
            if editing == nil { targetPicker }
            FormField(label: "Name", hint: editing == nil ? "How the agent refers to it: tools show up as mcp__name__tool" : "") {
                SInput(placeholder: "github", text: $form.name, width: .infinity, mono: true).disabled(editing != nil).opacity(editing == nil ? 1 : 0.6)
            }
            FormField(label: "Transport") {
                SlidingTabs(tabs: [
                    .init(id: "stdio", label: "Local command", icon: "terminal"),
                    .init(id: "http", label: "Remote (HTTP)", icon: "globe"),
                    .init(id: "sse", label: "Remote (SSE)", icon: "dot.radiowaves.left.and.right"),
                ], selection: $form.type)
            }
            if form.type == "stdio" { stdioFields.transition(.opacity) } else { remoteFields.transition(.opacity) }
        }
        .animation(M.snappy, value: form.type)
    }

    var targetPicker: some View {
        FormField(label: "Add to", hint: "Pick several to set the same server up for each agent") {
            HStack(spacing: 8) {
                ForEach(AgentKind.allCases) { a in
                    let on = form.targets.contains(a)
                    Button {
                        withAnimation(M.snappy) { if on { if form.targets.count > 1 { form.targets.remove(a) } } else { form.targets.insert(a) } }
                    } label: {
                        HStack(spacing: 6) {
                            AgentMark(agent: a, size: 16)
                            Text(a.label).font(T.ui(12.5, .medium)).foregroundStyle(on ? T.text : T.text2)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 11)).foregroundStyle(on ? T.accent : T.text3)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? T.accentSoft : T.raised))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(on ? T.accent.opacity(0.5) : T.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable(scale: 0.96))
                }
            }
        }
    }

    var stdioFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            FormField(label: "Command", hint: "Paste a whole command line and it's split into arguments") {
                SInput(placeholder: "npx", text: $form.command, width: .infinity, mono: true)
            }
            FormField(label: "Arguments") {
                ListEditor(rows: $form.args, single: true, keyPlaceholder: "-y", addLabel: "Add argument")
            }
            FormField(label: "Environment", hint: editing == nil ? "" : "Values are never shown. Leave one blank to keep it") {
                ListEditor(rows: $form.env, keyPlaceholder: "API_KEY", valuePlaceholder: "value", addLabel: "Add variable")
            }
        }
    }

    var remoteFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            FormField(label: "URL") {
                SInput(placeholder: "https://mcp.example.com/mcp", text: $form.url, width: .infinity, mono: true)
            }
            FormField(label: "Headers", hint: "For servers that take a key. OAuth servers sign in through the agent instead: use Sign In after adding") {
                ListEditor(rows: $form.headers, keyPlaceholder: "Authorization", valuePlaceholder: "Bearer …", addLabel: "Add header")
            }
            if form.targets.contains(.codex) {
                FormField(label: "Bearer token variable", hint: "Codex reads the token from this environment variable") {
                    SInput(placeholder: "GITHUB_TOKEN", text: $form.bearerEnv, width: .infinity, mono: true)
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 10) {
            if !form.error.isEmpty {
                Label(form.error, systemImage: "exclamationmark.triangle.fill").font(T.ui(12)).foregroundStyle(T.red).lineLimit(2)
                    .transition(.opacity)
            } else {
                Text("Takes effect from each session's next turn").font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            Spacer()
            Button("Cancel") { model.mcpSheet = nil }.buttonStyle(LButton())
            Button { save() } label: {
                HStack(spacing: 6) {
                    if form.saving { ProgressView().controlSize(.mini) }
                    Text(editing == nil ? (form.targets.count > 1 ? "Add to \(form.targets.count) agents" : "Add server") : "Save")
                }
            }
            .buttonStyle(LButton(primary: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(form.saving || form.name.trimmingCharacters(in: .whitespaces).isEmpty || (form.type == "stdio" ? form.command.isEmpty : form.url.isEmpty))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(T.panel.opacity(0.35))
        .animation(M.snappy, value: form.error)
    }

    func save() {
        if form.type == "stdio" { form.splitCommand() }
        form.saving = true
        form.error = ""
        let name = form.name.trimmingCharacters(in: .whitespaces)
        let targets = AgentKind.allCases.filter { form.targets.contains($0) }
        let original = editing?.name ?? ""
        let body = form.body
        Task {
            var done: [AgentKind] = []
            for a in targets {
                do {
                    try await API.post("/api/mcp/\(a.rawValue)", ["name": name, "original": original, "form": body])
                    done.append(a)
                } catch {
                    form.error = "\(a.label): \(error.localizedDescription)"
                }
            }
            for a in done { await MCPStore.shared.load(a) }
            form.saving = false
            if form.error.isEmpty {
                model.say(editing != nil ? "Saved \(name)" : "Added \(name) to \(done.map(\.label).joined(separator: ", "))")
                model.mcpSheet = nil
            }
        }
    }
}

struct FormField<Content: View>: View {
    let label: String
    var hint = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(T.ui(12, .semibold)).foregroundStyle(T.text2)
            content()
            if !hint.isEmpty { Text(hint).font(T.ui(11.5)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Rows of one field (arguments) or a key and a value (env, headers).
struct ListEditor: View {
    @Binding var rows: [KV]
    var single = false
    var keyPlaceholder = ""
    var valuePlaceholder = ""
    let addLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    if single {
                        Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(T.text3).frame(width: 14)
                    }
                    SInput(placeholder: keyPlaceholder, text: $row.key, width: single ? .infinity : 200, mono: true)
                    if !single {
                        SInput(placeholder: row.stored ? "•••••• unchanged" : valuePlaceholder, text: $row.value, secure: true, width: .infinity, mono: true)
                    }
                    IconButton(icon: "minus.circle", help: "Remove", size: 24) {
                        withAnimation(M.snappy) { rows.removeAll { $0.id == row.id } }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Button {
                withAnimation(M.snappy) { rows.append(KV(key: "", value: "")) }
            } label: {
                Label(addLabel, systemImage: "plus").font(T.ui(12, .medium)).foregroundStyle(T.text2)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.97))
        }
    }
}

// MARK: - Tools

struct MCPToolsSheet: View {
    @Environment(AppModel.self) var model
    @ObservedObject var store = MCPStore.shared
    let server: MCPServer
    let run: String?
    @StateObject private var query = Box("")
    @StateObject private var open = Box<Set<String>>([])

    var data: JSON? { store.tools[server.id] }
    /// Fits a short list; scrolls past a screenful.
    var height: CGFloat {
        guard let d = data, !d["tools"].array.isEmpty else { return 300 }
        return min(520, max(220, CGFloat(d["tools"].array.count) * 62 + 44))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content.frame(height: height)
            if let note = data?["note"].nonEmpty {
                Hairline()
                Label(note, systemImage: "info.circle").font(T.ui(11.5)).foregroundStyle(T.text3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .frame(width: 640)
        .floatingPanel()
        .task { await store.loadTools(server, run: run) }
        .onKeyPress(.escape) { model.mcpSheet = nil; return .handled }
    }

    var header: some View {
        HStack(spacing: 10) {
            MCPMark(server: server, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.name).font(T.ui(14, .semibold)).foregroundStyle(T.text)
                    AgentMark(agent: server.agent, size: 14)
                    Text(server.agent.label).font(T.ui(12)).foregroundStyle(T.text3)
                }
                Text(server.line).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            SearchField(placeholder: "Filter tools", text: $query.v).frame(width: 180)
            IconButton(icon: "arrow.clockwise", help: "List again", spinning: data == nil) { Task { await store.loadTools(server, run: run, refresh: true) } }
            IconButton(icon: "xmark", help: "Close (Esc)") { model.mcpSheet = nil }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder var content: some View {
        if let d = data {
            let tools = d["tools"].array.filter { Prefs.hit(query.v, $0["name"].string, $0["description"].string, $0["title"].string) }
            if d["tools"].array.isEmpty {
                VStack(spacing: 12) {
                    EmptyState(icon: d["status"].string == "needs-auth" ? "person.badge.key" : "wrench.and.screwdriver", title: d["status"].string == "needs-auth" ? "Sign in to see its tools" : "No tools listed", detail: d["error"].string)
                    if d["status"].string == "needs-auth" || server.remote {
                        Button("Sign in through \(server.agent.label)") { Task { await store.login(server, model: model) } }.buttonStyle(LButton(primary: true)).padding(.bottom, 40)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(verbatim: tools.count == d["tools"].array.count ? "\(tools.count) tools" : "\(tools.count) of \(d["tools"].array.count) tools")
                                .font(T.ui(11.5, .medium)).foregroundStyle(T.text3).monospacedDigit()
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        ForEach(Array(tools.enumerated()), id: \.offset) { i, t in
                            if i > 0 { Hairline().padding(.leading, 16) }
                            ToolRow(tool: t, open: open.v.contains(t["name"].string)) {
                                let n = t["name"].string
                                withAnimation(M.snappy) { if open.v.contains(n) { open.v.remove(n) } else { open.v.insert(n) } }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Asking \(server.name) for its tools…").font(T.ui(12)).foregroundStyle(T.text3).shimmer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ToolRow: View {
    let tool: JSON
    let open: Bool
    let toggle: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let params = tool["params"].array
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(tool["name"].string).font(T.mono(12.5, .medium)).foregroundStyle(T.text).lineLimit(1)
                if tool["readOnly"].bool { Chip(text: "read-only", tint: T.green) }
                if tool["destructive"].bool { Chip(text: "destructive", tint: T.red) }
                Spacer(minLength: 8)
                if !params.isEmpty || tool["description"].string.count > 140 {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            if !tool["description"].string.isEmpty {
                Text(tool["description"].string).font(T.ui(12)).foregroundStyle(T.text2).lineLimit(open ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if open && !params.isEmpty { paramTable(params).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(hover.v ? T.hover.opacity(0.45) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .hoverBox(hover)
    }

    func paramTable(_ params: [JSON]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(params.enumerated()), id: \.offset) { i, p in
                if i > 0 { Hairline() }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(spacing: 2) {
                        Text(p["name"].string).font(T.mono(11.5, .medium)).foregroundStyle(T.text)
                        if p["required"].bool { Text("*").font(T.mono(11.5, .bold)).foregroundStyle(T.orange).help("Required") }
                    }
                    .frame(width: 150, alignment: .leading)
                    Text(p["type"].string).font(T.mono(11)).foregroundStyle(T.purple).frame(width: 60, alignment: .leading)
                    Text(p["description"].string).font(T.ui(11.5)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .card(radius: 7)
    }
}

/// The overlay the editor and tools sheets float in.
struct MCPSheetHost: View {
    @Environment(AppModel.self) var model
    let sheet: MCPSheet

    var body: some View {
        Group {
            switch sheet {
            case .add, .edit: MCPEditor(sheet: sheet)
            case .tools(let s, let run): MCPToolsSheet(server: s, run: run)
            }
        }
        .padding(.top, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Composer menu

/// The chat's MCP servers: the session agent's, as its worktree sees them,
/// switched on and off in place.
struct MCPButton: View {
    @Environment(AppModel.self) var model
    @ObservedObject var store = MCPStore.shared
    @ObservedObject private var data = ComposerData.shared
    let runId: String
    let agent: AgentKind
    @StateObject private var open = Box(false)
    @StateObject private var hover = Box(false)

    var body: some View {
        let servers = store.servers(agent, run: runId)
        let on = servers.filter(\.enabled)
        let bad = on.contains { $0.status == "failed" || $0.status == "needs-auth" }
        Button { open.v.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 11, weight: .medium))
                    .overlay(alignment: .topTrailing) {
                        if bad { Circle().fill(T.orange).frame(width: 5, height: 5).offset(x: 3, y: -2) }
                    }
                if !servers.isEmpty { Text(verbatim: "\(on.count)").font(T.ui(11.5, .medium)).monospacedDigit() }
            }
            .foregroundStyle(open.v || hover.v ? T.text : T.text2)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(open.v ? T.selected : hover.v ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.95))
        .hoverBox(hover)
        .help("\(agent.label)'s MCP servers: \(on.count) on")
        .popover(isPresented: $open.v, arrowEdge: .top) { MCPPanel(runId: runId, agent: agent).environment(model) }
        .task(id: "\(runId)|\(agent.rawValue)") { await store.load(agent, run: runId) }
        .onChange(of: data.snapshotOpen) { if data.snapshotOpen == "mcp" { open.v = true } else if open.v && !data.snapshotOpen.isEmpty { open.v = false } }
    }
}

struct MCPPanel: View {
    @Environment(AppModel.self) var model
    @ObservedObject var store = MCPStore.shared
    let runId: String
    let agent: AgentKind
    @StateObject private var expanded = Box("")

    var body: some View {
        let servers = store.servers(agent, run: runId)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AgentMark(agent: agent, size: 16)
                Text("MCP servers").font(T.ui(13, .semibold))
                Text(agent.label).font(T.ui(12)).foregroundStyle(T.text3)
                Spacer()
                IconButton(icon: "arrow.clockwise", help: "Check again", spinning: store.checking(agent, run: runId), size: 24) {
                    Task { await store.load(agent, run: runId, refresh: true) }
                }
            }
            .padding(.horizontal, 14).frame(height: 42)
            Hairline()
            if store.list(agent, run: runId).isNull {
                ProgressView().controlSize(.small).frame(height: 80)
            } else if servers.isEmpty {
                Text("\(agent.label) has no MCP servers yet").font(T.ui(12)).foregroundStyle(T.text3).frame(height: 70)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(servers) { s in
                            MCPPanelRow(server: s, runId: runId, checking: store.checking(agent, run: runId), expanded: expanded.v == s.id) {
                                withAnimation(M.snappy) { expanded.v = expanded.v == s.id ? "" : s.id }
                            }
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 360)
            }
            Hairline()
            HStack {
                Text("Applies from the next turn").font(T.ui(11)).foregroundStyle(T.text3)
                Spacer()
                Button { model.openMCPSettings(agent) } label: { Label("Manage", systemImage: "gearshape").font(T.ui(12, .medium)) }
                    .buttonStyle(LButton())
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .frame(width: 380)
        .background(T.raised)
    }
}

struct MCPPanelRow: View {
    @Environment(AppModel.self) var model
    @ObservedObject var store = MCPStore.shared
    let server: MCPServer
    let runId: String
    let checking: Bool
    let expanded: Bool
    let toggle: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let s = server
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                MCPMark(server: s, checking: checking, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(s.name).font(T.ui(12.5, .medium)).foregroundStyle(s.enabled ? T.text : T.text2).lineLimit(1)
                        if s.toolCount != nil && s.enabled {
                            Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold)).foregroundStyle(T.text3)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    MCPStatusLine(server: s, checking: checking)
                }
                Spacer(minLength: 6)
                if store.busy.contains(s.id) {
                    ProgressView().controlSize(.mini).frame(width: 38)
                } else {
                    SToggle(on: Binding(get: { s.enabled }, set: { v in Task { await store.setEnabled(s, v, run: runId, model: model) } }))
                        .disabled(!s.toggleable)
                        .help(s.toggleable ? "" : s.note)
                }
            }
            if expanded && !s.toolNames.isEmpty { toolChips.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.v ? T.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if s.toolCount != nil && s.enabled { toggle() } }
        .hoverBox(hover)
    }

    var toolChips: some View {
        let names = server.toolNames
        return VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 4) {
                ForEach(names.prefix(24), id: \.self) { n in
                    Text(n).font(T.mono(10.5)).foregroundStyle(T.text2)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(T.bg.opacity(0.6)))
                }
            }
            Button {
                model.mcpSheet = .tools(server, run: runId)
            } label: {
                Text(names.count > 24 ? "All \(names.count) tools with details…" : "Details…").font(T.ui(11.5, .medium)).foregroundStyle(T.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 34)
    }
}

/// Wraps its children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
