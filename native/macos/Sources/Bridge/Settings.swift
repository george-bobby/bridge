import AppKit
import SwiftUI

// The Settings page: a section sub-nav on the left, grouped cards on the
// right (label and description, control on the trailing edge), a search
// that filters every section at once, and `.env` edits collected into one
// save bar. Secrets are write-only: the server only says whether one is set.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, agents, integrations, projects, notifications, advanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General"
        case .agents: return "Agents & models"
        case .integrations: return "Integrations"
        case .projects: return "Projects"
        case .notifications: return "Notifications"
        case .advanced: return "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .agents: return "cpu"
        case .integrations: return "square.stack.3d.up"
        case .projects: return "folder"
        case .notifications: return "bell"
        case .advanced: return "slider.horizontal.3"
        }
    }
    var blurb: String {
        switch self {
        case .general: return "The server, how outcomes reach you, and what the Slack pipeline may do."
        case .agents: return "Which agent and model new sessions start with, and how many workers run at once."
        case .integrations: return "Slack, GitHub and Linear. Tokens are stored in .env and never shown again."
        case .projects: return "The repositories in the sidebar, each with its own orchestrator."
        case .notifications: return "When Bridge interrupts you, on this Mac."
        case .advanced: return "Every .env key, the server runtime, and developing Bridge with Bridge."
        }
    }
}

// MARK: - .env state

/// The `.env` schema and the pending edits, shared by every section.
@MainActor
final class EnvStore: ObservableObject {
    @Published var entries: [JSON] = []
    @Published var edits: [String: String] = [:]
    /// Secrets whose "Replace" was clicked: their field is open.
    @Published var replacing: Set<String> = []
    @Published var file = ""
    @Published var loaded = false

    func load() async {
        let out = (try? await API.get("/api/env")) ?? .null
        entries = out["entries"].array
        file = out["file"].string
        loaded = true
    }

    func entry(_ key: String) -> JSON? { entries.first { $0["key"].string == key } }

    /// The entries for `keys`, in that order, that exist and match the search.
    func rows(_ keys: [String], _ q: String) -> [JSON] {
        keys.compactMap { entry($0) }.filter { Prefs.hit(q, EnvField.title($0["key"].string), $0["hint"].string, $0["key"].string) }
    }

    func discard() {
        edits = [:]
        replacing = []
    }
}

enum Prefs {
    /// Every word of the query appears somewhere in the row's text.
    static func hit(_ q: String, _ parts: String...) -> Bool {
        let words = q.lowercased().split(separator: " ")
        if words.isEmpty { return true }
        let hay = parts.joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    static let slackKeys = ["SLACK_USER_TOKEN", "SLACK_USER_ID", "SLACK_USER_NAME", "SLACK_PRODUCT_TEAM", "SLACK_ENGINEER_TEAM"]
    static let githubKeys = ["GITHUB_LOGIN", "GITHUB_REPO"]
    static let linearKeys = ["LINEAR_API_KEY", "LINEAR_WORKSPACE", "LINEAR_TEAM", "LINEAR_ISSUE_PREFIX", "LINEAR_PROJECT"]
    static let repoKeys = ["TARGET_REPO", "TARGET_SCOPE", "WORKTREE_ROOT", "BRANCH_PREFIX"]
    static let productKeys = ["PRODUCT_NAME", "PRODUCT_URL"]
    static let agentKeys = ["PIPELINE_MODEL", "EXTRA_PATH"]
    /// Keys with a home in a friendlier section; Advanced lists the rest.
    static var placed: Set<String> { Set(slackKeys + githubKeys + linearKeys + repoKeys + productKeys + agentKeys) }
}

// MARK: - Page

struct SettingsView: View {
    @Environment(AppModel.self) var model
    @StateObject private var env = EnvStore()
    @StateObject private var query = Box("")
    @Namespace private var ns

    var pane: SettingsPane { SettingsPane(rawValue: model.settingsPane) ?? .general }
    var searching: Bool { !query.v.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings", icon: "gearshape") {
                SearchField(placeholder: "Search settings", text: $query.v).frame(width: 240)
            }
            HStack(spacing: 0) {
                nav
                Rectangle().fill(T.line).frame(width: 1)
                ZStack(alignment: .bottom) {
                    ScrollView { content }
                        .scrollIndicators(.never)
                    if !env.edits.isEmpty {
                        SaveBar(env: env).padding(16).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(M.snappy, value: env.edits.isEmpty)
            }
        }
        .onAppear {
            // Dev aid: BRIDGE_SNAPSHOT_SETTINGS_QUERY=token snapshots the search.
            if let q = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_SETTINGS_QUERY"], ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_DIR"] != nil { query.v = q }
            Task { await env.load() }
        }
    }

    var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { p in
                SettingsNavItem(pane: p, on: !searching && p == pane, ns: ns) {
                    query.v = ""
                    withAnimation(M.snappy) { model.settingsPane = p.rawValue }
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.connected ? T.green : T.red).frame(width: 6, height: 6)
                Text(API.base.host.map { "\($0):\(API.base.port ?? 80)" } ?? API.base.absoluteString).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
        }
        .padding(10)
        .frame(width: 212)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(T.bg.opacity(0.25))
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.envNeedsRestart { RestartBanner().padding(.bottom, 24) }
            if searching {
                Text("Results for “\(query.v.trimmingCharacters(in: .whitespaces))”").font(T.ui(13)).foregroundStyle(T.text3).padding(.bottom, 20)
                ForEach(SettingsPane.allCases) { p in
                    paneBody(p).environment(\.settingsPrefix, p.label)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pane.label).font(T.ui(20, .semibold)).foregroundStyle(T.text)
                    Text(pane.blurb).font(T.ui(12.5)).foregroundStyle(T.text3)
                }
                .padding(.bottom, 28)
                paneBody(pane)
            }
        }
        .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, env.edits.isEmpty ? 8 : 72)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .id(searching ? "search" : pane.rawValue)
        .transition(.page)
    }

    @ViewBuilder func paneBody(_ p: SettingsPane) -> some View {
        let q = searching ? query.v : ""
        switch p {
        case .general: GeneralSettings(q: q)
        case .agents: AgentSettings(env: env, q: q)
        case .integrations: IntegrationSettings(env: env, q: q)
        case .projects: ProjectSettings(env: env, q: q)
        case .notifications: NotificationSettings(q: q)
        case .advanced: AdvancedSettings(env: env, q: q)
        }
    }
}

struct SettingsNavItem: View {
    let pane: SettingsPane
    let on: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.icon).font(.system(size: 12.5, weight: .medium)).frame(width: 18)
                    .foregroundStyle(on ? T.text : T.text2)
                Text(pane.label).font(T.ui(13, on ? .medium : .regular)).foregroundStyle(on ? T.text : T.text2)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.v && !on ? T.sideHover : .clear)
                    if on { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.sideSelected).matchedGeometryEffect(id: "settings-nav", in: ns) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
        .hoverBox(hover)
    }
}

private struct SettingsPrefixKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    /// While searching, sections are titled "Pane · Section".
    var settingsPrefix: String {
        get { self[SettingsPrefixKey.self] }
        set { self[SettingsPrefixKey.self] = newValue }
    }
}

// MARK: - Building blocks

/// A titled card of rows with hairlines between them. Hides itself when
/// the search leaves it no rows.
struct SSection<Content: View, Trailing: View>: View {
    @Environment(\.settingsPrefix) private var prefix
    let title: String
    var detail = ""
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Group(subviews: content) { rows in
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prefix.isEmpty ? title : "\(prefix) · \(title)").font(T.ui(13, .semibold)).foregroundStyle(T.text)
                            if !detail.isEmpty { Text(detail).font(T.ui(12)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer()
                        trailing()
                    }
                    .padding(.horizontal, 2)
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { Hairline() }
                            row
                        }
                    }
                    .card(radius: 10)
                }
                .padding(.bottom, 28)
            }
        }
    }
}

extension SSection where Trailing == EmptyView {
    init(title: String, detail: String = "", @ViewBuilder content: () -> Content) {
        self.init(title: title, detail: detail, content: content) { EmptyView() }
    }
}

/// Label and description on the left, the control on the right.
struct SRow<Control: View>: View {
    let title: String
    var detail = ""
    var key = ""
    var modified = false
    var icon: AnyView? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon { icon }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(T.ui(13, .medium)).foregroundStyle(T.text)
                    if modified { Circle().fill(T.accent).frame(width: 6, height: 6).help("Unsaved") }
                }
                if !detail.isEmpty {
                    Text(detail).font(T.ui(12)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
                }
                if !key.isEmpty { Text(key).font(T.mono(10.5)).foregroundStyle(T.text3.opacity(0.85)).textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 56)
    }
}

struct SToggle: View {
    @Binding var on: Bool
    var body: some View {
        Toggle("", isOn: $on).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(T.accent)
    }
}

/// A pop-up menu that looks like the header pills.
struct SSelect: View {
    let value: String
    let choices: [(String, String)]
    let pick: (String) -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let label = choices.first { $0.0 == value }?.1 ?? (value.isEmpty ? "Default" : value)
        Menu {
            ForEach(choices, id: \.0) { c in
                Button { pick(c.0) } label: {
                    if c.0 == value { Label(c.1, systemImage: "checkmark") } else { Text(c.1) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label).font(T.ui(12.5, .medium)).foregroundStyle(T.text).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text3)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.v ? T.hover : T.raised))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverBox(hover)
    }
}

/// − value + in one bordered capsule.
struct SStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", value - step >= range.lowerBound) { set(max(range.lowerBound, value - step)) }
            Text(verbatim: unit.isEmpty ? "\(value)" : "\(value) \(unit)").font(T.ui(12.5, .medium)).monospacedDigit()
                .foregroundStyle(T.text).frame(minWidth: 52).contentTransition(.numericText())
            button("plus", value + step <= range.upperBound) { set(min(range.upperBound, value + step)) }
        }
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.line, lineWidth: 1))
        .animation(M.snappy, value: value)
    }

    func button(_ icon: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(enabled ? T.text2 : T.text3.opacity(0.5))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.85))
        .disabled(!enabled)
    }
}

/// A bordered text input with Linear's focus ring; secure for secrets.
struct SInput: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var width: CGFloat = 260
    var mono = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(mono ? T.mono(12) : T.ui(12.5))
        .focused($focused)
        .padding(.horizontal, 9)
        .frame(width: width, height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.bg.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(focused ? T.accent.opacity(0.7) : T.line, lineWidth: 1))
        .shadow(color: T.accent.opacity(focused ? 0.25 : 0), radius: 4)
        .animation(M.hover, value: focused)
    }
}

/// A row bound to one `.env` key: plain values edit in place, secrets show
/// Set / Replace / Remove and never their value.
struct EnvField: View {
    @ObservedObject var env: EnvStore
    let e: JSON

    static let titles: [String: String] = [
        "SLACK_USER_TOKEN": "User OAuth token", "SLACK_USER_ID": "Member ID", "SLACK_USER_NAME": "Display name",
        "SLACK_PRODUCT_TEAM": "Product team", "SLACK_ENGINEER_TEAM": "Engineering team",
        "GITHUB_LOGIN": "GitHub login", "GITHUB_REPO": "Pull request repository",
        "LINEAR_API_KEY": "Personal API key", "LINEAR_WORKSPACE": "Workspace", "LINEAR_TEAM": "Team",
        "LINEAR_ISSUE_PREFIX": "Issue prefix", "LINEAR_PROJECT": "Project",
        "TARGET_REPO": "Default repository", "TARGET_SCOPE": "Subdirectory scope", "WORKTREE_ROOT": "Worktree folder", "BRANCH_PREFIX": "Branch prefix",
        "PRODUCT_NAME": "Product name", "PRODUCT_URL": "Product URL",
        "BRIDGE_PORT": "Server port", "LAUNCHD_LABEL": "launchd label", "PIPELINE_MODEL": "Pipeline model",
        "EXTRA_PATH": "Extra PATH", "MCP_READ_PREFIXES": "Read-only MCP prefixes",
    ]
    static let details: [String: String] = [
        "SLACK_PRODUCT_TEAM": "Ticket hints, as Name:MemberID,Name:MemberID",
        "SLACK_ENGINEER_TEAM": "Ticket hints, as Name:MemberID,Name:MemberID",
        "SLACK_USER_NAME": "How the pipeline refers to you",
        "PRODUCT_NAME": "Named in the skill the pipeline renders",
    ]
    static func title(_ key: String) -> String { titles[key] ?? key }

    var key: String { e["key"].string }
    var detail: String {
        let d = e["hint"].nonEmpty ?? EnvField.details[key] ?? ""
        return d.prefix(1).uppercased() + d.dropFirst()
    }

    var body: some View {
        SRow(title: EnvField.title(key), detail: detail, key: EnvField.titles[key] == nil ? "" : key, modified: env.edits[key] != nil) {
            if e["secret"].bool { secret } else {
                SInput(placeholder: e["example"].nonEmpty ?? "Not set", text: Binding(get: { env.edits[key] ?? e["value"].string }, set: { v in
                    if v == e["value"].string { env.edits.removeValue(forKey: key) } else { env.edits[key] = v }
                }), mono: key.contains("PATH") || key.contains("REPO") || key.contains("ROOT"))
            }
        }
    }

    @ViewBuilder var secret: some View {
        let set = e["set"].bool
        if set && env.edits[key] == "" {
            HStack(spacing: 8) {
                Chip(text: "Will be removed", tint: T.red)
                Button("Undo") { env.edits.removeValue(forKey: key) }.buttonStyle(LButton())
            }
        } else if set && !env.replacing.contains(key) {
            HStack(spacing: 8) {
                Chip(text: "Set", dot: T.green)
                Button("Replace") { withAnimation(M.snappy) { _ = env.replacing.insert(key) } }.buttonStyle(LButton())
                Button { env.edits[key] = "" } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(LButton(danger: true)).help("Remove from .env")
            }
        } else {
            HStack(spacing: 8) {
                SInput(placeholder: set ? "Paste the new value" : "Not set", text: Binding(get: { env.edits[key] ?? "" }, set: { v in
                    if v.isEmpty { env.edits.removeValue(forKey: key) } else { env.edits[key] = v }
                }), secure: true, width: set ? 200 : 260)
                if set {
                    Button("Cancel") { withAnimation(M.snappy) { env.replacing.remove(key); env.edits.removeValue(forKey: key) } }.buttonStyle(LButton())
                }
            }
        }
    }
}

/// The pending `.env` edits, floating over the bottom of the page.
struct SaveBar: View {
    @Environment(AppModel.self) var model
    @ObservedObject var env: EnvStore

    init(env: EnvStore) { self.env = env }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle.fill").font(.system(size: 14)).foregroundStyle(T.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(env.edits.count == 1 ? "1 unsaved change" : "\(env.edits.count) unsaved changes").font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                Text(".env changes apply when the server restarts").font(T.ui(11)).foregroundStyle(T.text3)
            }
            Spacer()
            Button("Discard") { withAnimation(M.snappy) { env.discard() } }.buttonStyle(LButton())
            Button("Save") { save(restart: false) }.buttonStyle(LButton())
            Button("Save & Restart") { save(restart: true) }.buttonStyle(LButton(primary: true)).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 688)
        .floatingPanel(radius: 12)
    }

    func save(restart: Bool) {
        let values = env.edits
        Task {
            if await model.saveEnv(values, restart: restart) {
                env.discard()
                if restart { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                await env.load()
            }
        }
    }
}

struct RestartBanner: View {
    @Environment(AppModel.self) var model
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.orange)
                .frame(width: 28, height: 28).background(Circle().fill(T.orange.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart the server to apply your changes").font(T.ui(13, .medium)).foregroundStyle(T.text)
                Text(".env is saved, but the running server still uses the old values. Running workers restart with it.").font(T.ui(12)).foregroundStyle(T.text2)
            }
            Spacer()
            Button("Later") { withAnimation(M.snappy) { model.envNeedsRestart = false } }.buttonStyle(LButton())
            Button("Restart now") { Task { await model.restartServer() } }.buttonStyle(LButton(primary: true))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.orange.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.orange.opacity(0.3), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct StatusChip: View {
    let on: Bool
    var onText = "Connected"
    var offText = "Not connected"
    var body: some View { Chip(text: on ? onText : offText, dot: on ? T.green : T.text3) }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SSection(title: "Server") {
                if Prefs.hit(q, "server status connected offline address") {
                    SRow(title: "Status", detail: model.connected ? "Bridge's server is running at \(API.base.absoluteString)" : "Can't reach \(API.base.absoluteString)") {
                        StatusChip(on: model.connected, onText: "Connected", offText: "Offline")
                    }
                }
                if Prefs.hit(q, "restart server reload") {
                    SRow(title: "Restart the server", detail: "Reloads lib/, .env and the skill templates. Running workers restart with it.") {
                        Button("Restart") { Task { await model.restartServer() } }.buttonStyle(LButton())
                    }
                }
                if Prefs.hit(q, "legacy web ui browser") {
                    SRow(title: "Legacy web UI", detail: "The original dashboard, in your browser") {
                        Button { openURL(API.base.absoluteString) } label: { Label("Open", systemImage: "arrow.up.right") }.buttonStyle(LButton())
                    }
                }
            }
            SSection(title: "Inbox", detail: "How worker outcomes reach the orchestrator") {
                if Prefs.hit(q, "relay mode normal quiet away inbox") {
                    SRow(title: "Relay mode", detail: "Normal relays everything; quiet only what needs you; away holds it all for one catch-up") {
                        SlidingTabs(tabs: [
                            .init(id: "normal", label: "Normal", icon: "bell"),
                            .init(id: "quiet", label: "Quiet", icon: "moon"),
                            .init(id: "away", label: "Away", icon: "airplane"),
                        ], selection: Binding(get: { model.inbox["mode"].nonEmpty ?? model.config["harness"]["mode"].nonEmpty ?? "normal" }, set: { m in Task { await model.setMode(m) } }))
                    }
                }
            }
            PipelineSettings(q: q)
        }
    }
}

struct PipelineSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var body: some View {
        SSection(title: "Slack pipeline", detail: "What a run started from a Slack thread may prepare for you") {
            toggle("Draft the reply in the thread", "reply", "Posted only after you approve it")
            toggle("Offer a Linear ticket", "createLinearIssue", "Created only after you approve it")
            toggle("Wait for bot review, then resolve", "botReview", "After the PR opens, wait for the review bots, then run /resolve")
            toggle("Propose memories", "saveToMemory", "Nothing is saved without your approval")
        }
    }

    @ViewBuilder func toggle(_ title: String, _ key: String, _ hint: String) -> some View {
        if Prefs.hit(q, title, hint, "pipeline slack") {
            SRow(title: title, detail: hint) {
                SToggle(on: Binding(get: { model.config[key].bool }, set: { v in Task { await model.saveConfig([key: v]) } }))
            }
        }
    }
}

// MARK: - Agents & models

struct AgentSettings: View {
    @Environment(AppModel.self) var model
    @ObservedObject var env: EnvStore
    let q: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SSection(title: "Installed agents", detail: "Found on this Mac's PATH") {
                ForEach(AgentKind.allCases.filter { Prefs.hit(q, $0.label, $0.hint, "agent installed version") }) { a in
                    SRow(title: a.label, detail: a.hint, icon: AnyView(AgentMark(agent: a, size: 24))) { agentStatus(a) }
                }
            }
            DefaultsSettings(q: q)
            WorkerSettings(q: q)
            SSection(title: "Pipeline runtime", detail: "Stored in .env") {
                ForEach(env.rows(Prefs.agentKeys, q), id: \.self) { EnvField(env: env, e: $0) }
            }
        }
    }

    @ViewBuilder func agentStatus(_ a: AgentKind) -> some View {
        let j = model.agentCatalog["agents"].array.first { $0["id"].string == a.rawValue }
        if let j, j["installed"].bool {
            VStack(alignment: .trailing, spacing: 3) {
                Chip(text: "Installed", dot: T.green)
                if !j["version"].string.isEmpty { Text(j["version"].string).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1) }
            }
        } else if j == nil {
            Chip(text: "Checking…")
        } else {
            Chip(text: "Not installed", dot: T.text3)
        }
    }
}

struct DefaultsSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var agent: AgentKind { AgentKind.of(model.config["followup"]["agent"].nonEmpty ?? "claude") }

    var body: some View {
        SSection(title: "New sessions start with", detail: "A chat tuned in its composer keeps its own choices") {
            if Prefs.hit(q, "default agent new sessions") {
                SRow(title: "Agent") {
                    SSelect(value: agent.rawValue, choices: AgentKind.allCases.map { ($0.rawValue, $0.label) }) { save(["agent": $0]) }
                }
            }
            if Prefs.hit(q, "default model new sessions") {
                SRow(title: "Model", detail: agent == .claude ? "Claude Code model or alias" : "\(agent.label)'s model; Default lets the CLI choose") {
                    let key = agent == .claude ? "model" : "agentModel"
                    SSelect(value: model.config["followup"][key].string, choices: modelChoices) { save([key: $0]) }
                }
            }
            ForEach(JobOption.all.filter { $0.key != "model" && Prefs.hit(q, $0.label, "default permission thinking effort mode") }, id: \.key) { opt in
                SRow(title: opt.key == "permissionMode" ? "Permissions" : opt.label, detail: opt.key == "permissionMode" ? "How much a session may do unattended" : "Reasoning effort, where the model supports it") {
                    SSelect(value: model.config["followup"][opt.key].string, choices: opt.choices) { save([opt.key: $0]) }
                }
            }
            if Prefs.hit(q, "repository workdir folder default") {
                SRow(title: "Repository", detail: model.config["followup"]["workdir"].nonEmpty ?? "Not set") {
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { save(["workdir": u.path]) }
                    }
                    .buttonStyle(LButton())
                }
            }
        }
    }

    var modelChoices: [(String, String)] {
        let catalog = model.models(for: agent).map { ($0["id"].string, $0["label"].nonEmpty ?? $0["id"].string) }
        if agent == .claude { return catalog.isEmpty ? JobOption.all.first { $0.key == "model" }?.choices ?? [] : catalog }
        return [("", "Default")] + catalog
    }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(["followup": patch]) } }
}

struct WorkerSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var h: JSON { model.config["harness"] }

    var body: some View {
        SSection(title: "Workers", detail: "Sessions the orchestrator spawns") {
            if Prefs.hit(q, "relay outcomes orchestrator workers") {
                SRow(title: "Relay outcomes to the orchestrator", detail: "A finished, blocked or stalled worker starts a turn in the orchestrator chat") {
                    SToggle(on: Binding(get: { h["relay"].bool }, set: { v in save(["relay": v]) }))
                }
            }
            if Prefs.hit(q, "max workers at once limit") {
                SRow(title: "Workers at once", detail: "Past the cap a new task is queued") {
                    SStepper(value: h["maxWorkers"].int, range: 1...12) { save(["maxWorkers": $0]) }
                }
            }
            if Prefs.hit(q, "per repo workers limit") {
                SRow(title: "Per repository", detail: "Working workers in the same repo") {
                    SStepper(value: h["maxPerRepo"].int, range: 1...12) { save(["maxPerRepo": $0]) }
                }
            }
            if Prefs.hit(q, "stalled silence minutes stall") {
                SRow(title: "Stalled after", detail: "Silence before a working worker is flagged") {
                    SStepper(value: h["stallMinutes"].int, range: 5...120, step: 5, unit: "min") { save(["stallMinutes": $0]) }
                }
            }
        }
    }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(["harness": patch]) } }
}

// MARK: - Integrations

struct IntegrationSettings: View {
    @Environment(AppModel.self) var model
    @ObservedObject var env: EnvStore
    let q: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SSection(title: "Slack", detail: "Read as you with a user token: no bot to invite, nothing to add to channels") {
                ForEach(env.rows(Prefs.slackKeys, q), id: \.self) { EnvField(env: env, e: $0) }
                if Prefs.hit(q, "slack app manifest guide setup") {
                    SRow(title: "Set up the Slack app", detail: "Create it from the manifest once, install it to yourself, and paste its xoxp- token above") {
                        HStack(spacing: 8) {
                            Button { openURL("https://github.com/george-bobby/bridge/blob/main/docs/slack.md") } label: { Label("Guide", systemImage: "book") }.buttonStyle(LButton())
                            Button { openURL("https://api.slack.com/apps?new_app=1") } label: { Label("Create app", systemImage: "arrow.up.right") }.buttonStyle(LButton())
                        }
                    }
                }
            } trailing: {
                StatusChip(on: model.slack["configured"].bool, onText: model.slack["team"].nonEmpty.map { "Connected · \($0)" } ?? "Connected")
            }
            SSection(title: "GitHub", detail: "Pull requests go through the gh CLI's own login") {
                ForEach(env.rows(Prefs.githubKeys, q), id: \.self) { EnvField(env: env, e: $0) }
            } trailing: {
                StatusChip(on: !model.pulls["login"].string.isEmpty, onText: "@\(model.pulls["login"].string)", offText: "gh not signed in")
            }
            SSection(title: "Linear", detail: "The API key powers the Linear view; sessions never inherit it") {
                ForEach(env.rows(Prefs.linearKeys, q), id: \.self) { EnvField(env: env, e: $0) }
            } trailing: {
                StatusChip(on: model.linear["configured"].bool, onText: model.linear["viewer"].nonEmpty.map { "Connected · \($0)" } ?? "Connected")
            }
        }
    }
}

// MARK: - Projects

struct ProjectSettings: View {
    @Environment(AppModel.self) var model
    @ObservedObject var env: EnvStore
    let q: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SSection(title: "Projects", detail: "Repositories in the sidebar; each gets its own orchestrator") {
                ForEach(model.projects.filter { Prefs.hit(q, $0.name, $0.path, "project repository") }) { p in ProjectRow(project: p) }
                if model.projects.isEmpty && Prefs.hit(q, "project add") {
                    SRow(title: "No projects yet", detail: "Add a git checkout to start sessions in it") { EmptyView() }
                }
            } trailing: {
                Button { model.addProject() } label: { Label("Add project", systemImage: "plus") }.buttonStyle(LButton())
            }
            SSection(title: "Default repository", detail: "Where the Slack pipeline and the default orchestrator work. Stored in .env") {
                ForEach(env.rows(Prefs.repoKeys, q), id: \.self) { EnvField(env: env, e: $0) }
            }
            SSection(title: "Product", detail: "Named in the skill the pipeline renders") {
                ForEach(env.rows(Prefs.productKeys, q), id: \.self) { EnvField(env: env, e: $0) }
            }
        }
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) var model
    let project: Project

    var body: some View {
        SRow(title: project.name, detail: project.path, icon: AnyView(
            Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(T.accent)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(T.accentSoft))
        )) {
            HStack(spacing: 6) {
                Button("Orchestrator") { model.openOrchestrator(project.id) }.buttonStyle(LButton())
                Menu {
                    Button("New Task…") { model.compose(in: project.id) }
                    Button("Reveal in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
                    Divider()
                    Button("Remove Project…", role: .destructive) { remove() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(T.text2)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.raised))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.line, lineWidth: 1))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    func remove() {
        let a = NSAlert()
        a.messageText = "Remove \(project.name) from Bridge?"
        a.informativeText = "Its sessions and files stay; it just leaves the sidebar."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { Task { await model.removeProject(project.id) } }
    }
}

// MARK: - Notifications

struct NotificationSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 0) {
            SSection(title: "Alerts", detail: "macOS notifications from the Bridge app") {
                if Prefs.hit(q, "notify session needs you question ask") {
                    SRow(title: "When a session needs you", detail: "A question, a plan to approve, or a permission card") { SToggle(on: $m.notifyAsks) }
                }
                if Prefs.hit(q, "notify worker outcome finished blocked stalled review") {
                    SRow(title: "When a worker reports", detail: "Ready for review, blocked, stalled, gone or out of usage") { SToggle(on: $m.notifyOutcomes) }
                }
                if Prefs.hit(q, "dock badge count") {
                    SRow(title: "Dock badge", detail: "Count what's waiting on you on the Dock icon") { SToggle(on: $m.showBadge) }
                }
            }
            SSection(title: "System") {
                if Prefs.hit(q, "system notification settings sound banner") {
                    SRow(title: "Banners and sounds", detail: Bundle.main.bundlePath.hasSuffix(".app") ? "Style and sound are set in System Settings" : "Notifications need the packaged app (npm run app)") {
                        Button { openURL("x-apple.systempreferences:com.apple.Notifications-Settings.extension") } label: { Label("System Settings", systemImage: "arrow.up.right") }
                            .buttonStyle(LButton())
                    }
                }
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    @Environment(AppModel.self) var model
    @ObservedObject var env: EnvStore
    let q: String

    var rest: [JSON] { env.entries.filter { !Prefs.placed.contains($0["key"].string) } }
    var sections: [String] {
        var seen: [String] = []
        for e in rest where !seen.contains(e["section"].string) { seen.append(e["section"].string) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.self) { s in
                SSection(title: s == "Runtime" ? "Runtime" : s, detail: s == "Runtime" ? "How the server runs under launchd" : "") {
                    ForEach(env.rows(rest.filter { $0["section"].string == s }.map { $0["key"].string }, q), id: \.self) { EnvField(env: env, e: $0) }
                }
            }
            SSection(title: "Environment file") {
                if Prefs.hit(q, ".env file environment reveal") {
                    SRow(title: ".env", detail: env.file.isEmpty ? "Not found" : env.file) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: env.file)]) } label: { Label("Reveal", systemImage: "folder") }
                            .buttonStyle(LButton()).disabled(env.file.isEmpty)
                    }
                }
            }
            DevelopSettings(q: q)
        }
    }
}

/// Bridge can work on itself: add its repo as a project, then rebuild.
struct DevelopSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var body: some View {
        let root = model.bridgeRoot
        let bridgeProject = model.projects.first { $0.path == root }
        SSection(title: "Develop Bridge with Bridge", detail: "Add Bridge's own repo as a project, start sessions on it, then rebuild here") {
            if Prefs.hit(q, "bridge source repository develop") {
                SRow(title: "Bridge's source", detail: root.isEmpty ? "Unknown" : root) {
                    HStack(spacing: 6) {
                        if let p = bridgeProject {
                            Button("New Task") { model.compose(in: p.id) }.buttonStyle(LButton())
                            Button("Orchestrator") { model.openOrchestrator(p.id) }.buttonStyle(LButton())
                        } else {
                            Button("Add as Project") { Task { await model.addProject(path: root, name: "bridge") } }.buttonStyle(LButton()).disabled(root.isEmpty)
                        }
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: root)) } label: { Image(systemName: "folder") }.buttonStyle(LButton()).disabled(root.isEmpty).help("Reveal in Finder")
                    }
                }
            }
            if Prefs.hit(q, "rebuild relaunch app build") {
                SRow(title: "Rebuild and relaunch", detail: "Compiles native/macos, swaps the app in ~/Applications and reopens it") {
                    HStack(spacing: 8) {
                        if model.building { ProgressView().controlSize(.small) }
                        Button(model.building ? "Building…" : "Rebuild") { model.rebuildApp() }.buttonStyle(LButton()).disabled(model.building || root.isEmpty)
                    }
                }
            }
            if !model.buildLog.isEmpty && Prefs.hit(q, "build log rebuild") {
                Text(model.buildLog).font(T.mono(11)).foregroundStyle(T.text2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(T.bg.opacity(0.4))
            }
        }
    }
}
