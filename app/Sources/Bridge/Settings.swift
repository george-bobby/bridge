import AppKit
import SwiftUI

// The Settings page: a section sub-nav on the left, grouped cards on the
// right (label and description, control on the trailing edge), a search
// that filters every section at once, and `.env` edits collected into one
// save bar. Secrets are write-only: the server only says whether one is set.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, agents, rules, pipeline, mcp, plugins, tokens, integrations, projects, notifications, advanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General"
        case .agents: return "Agents"
        case .rules: return "Rules"
        case .pipeline: return "Pipeline"
        case .mcp: return "Customize"
        case .plugins: return "Plugins"
        case .tokens: return "Tokens"
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
        case .rules: return "checklist"
        case .pipeline: return "arrow.triangle.branch"
        case .mcp: return "wrench.and.screwdriver"
        case .plugins: return "puzzlepiece.extension"
        case .tokens: return "flame"
        case .integrations: return "square.stack.3d.up"
        case .projects: return "folder"
        case .notifications: return "bell"
        case .advanced: return "slider.horizontal.3"
        }
    }
    var blurb: String {
        switch self {
        case .general: return "The server, how outcomes reach you, and what the Slack pipeline may do."
        case .agents: return "The agents on this Mac, and what a new session starts with."
        case .rules: return "House rules every session follows, in every repo: added to each worker's and orchestrator's instructions."
        case .pipeline: return "How every new session works its task: gather context, check it isn't built, plan or build, verify, open the PR and see it through review and CI."
        case .mcp: return "What each agent loads: MCP servers and skills. Changes go into the agent's own folders and config."
        case .plugins: return "Plugins for every agent on this Mac, by agent. Changes go through each agent's own CLI."
        case .tokens: return "What the agents on this Mac spent, from CodeBurn, and the token savers you can switch on for them."
        case .integrations: return "Connect your tools. Bridge works out who you are and which repo from each connection; nothing else to type. Keys are stored in .env and never shown again."
        case .projects: return "Default and your repositories, each with its own orchestrator, and what workers in each may do on their own."
        case .notifications: return "When Bridge interrupts you, on this Mac."
        case .advanced: return "Every key set in your .env. Values stay hidden until you reveal them; secrets can only be replaced."
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
    @Published var loaded = false

    func load() async {
        let out = (try? await API.get("/api/env")) ?? .null
        entries = out["entries"].array
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

    /// The connection keys: edited in Integrations. Everything else in .env is
    /// an override for something Bridge works out itself, under Advanced.
    static let connectionKeys = ["SLACK_USER_TOKEN", "LINEAR_API_KEY", "VERCEL_TOKEN", "INCIDENT_API_KEY", "GRANOLA_API_KEY", "DD_API_KEY", "DD_APP_KEY", "DD_SITE", "MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"]
    static var placed: Set<String> { Set(connectionKeys) }
}

extension AppModel {
    /// Settings on `pane` with its search set to `query` ("" clears a search left open).
    func openSettings(_ pane: SettingsPane, query: String = "") {
        settingsPane = pane.rawValue
        settingsQuery = query.isEmpty ? " " : query
        navigate(.settings)
    }
}

/// A setting ⌘K can find: its pane, title, the words it's found by (its
/// row's `Prefs.hit` words), and the Settings search that shows it on a pick.
struct SettingEntry {
    let pane: SettingsPane
    let title: String
    let words: String
    let query: String

    static let all: [SettingEntry] = [
        .init(pane: .general, title: "Theme", words: "appearance theme light dark mode system color", query: "theme"),
        .init(pane: .general, title: "Restart the server", words: "restart server reload", query: "restart server"),
        .init(pane: .general, title: "Relay mode", words: "relay mode normal quiet away off inbox outcomes orchestrator workers", query: "relay mode"),
        .init(pane: .agents, title: "Installed agents", words: "agent installed version claude codex cursor devin", query: "agent installed"),
        .init(pane: .agents, title: "Default agent", words: "default agent new sessions", query: "default agent"),
        .init(pane: .agents, title: "Default model", words: "default model new sessions", query: "default model"),
        .init(pane: .agents, title: "Default permissions and thinking", words: "default permission thinking effort mode", query: "default permission"),
        .init(pane: .agents, title: "Automatic failover", words: "automatic failover claude usage threshold preference order", query: "automatic failover"),
        .init(pane: .agents, title: "Opening skill", words: "opening skill worker skill fetch new session", query: "opening skill"),
        .init(pane: .agents, title: "Stalled after", words: "stalled silence minutes stall", query: "stalled"),
        .init(pane: .agents, title: "Auto-archive merged chats", words: "auto archive merged days pr", query: "auto archive"),
        .init(pane: .projects, title: "Projects", words: "project projects repository default add orchestrator", query: ""),
        .init(pane: .projects, title: "Automation", words: "automation auto merge review resolve rebase decide workers project github account linear team", query: "automation"),
        .init(pane: .rules, title: "Common rules", words: "common rules house rules instructions prompt worktree rebase branch pr markdown edit", query: "common rules"),
        .init(pane: .mcp, title: "MCP servers", words: "mcp server tools customize", query: ""),
        .init(pane: .plugins, title: "Plugins", words: "plugins plugin claude code codex cursor devin marketplace install remove", query: ""),
        .init(pane: .integrations, title: "GitHub", words: "github pull requests gh login checks", query: "github"),
        .init(pane: .integrations, title: "Linear", words: "linear issues api key team tickets", query: "linear"),
        .init(pane: .integrations, title: "Slack", words: "slack token mentions channels threads", query: "slack"),
        .init(pane: .integrations, title: "Slack watch", words: "slack watch mentions mode off triage poll interval check every minutes watched channels", query: "slack watch"),
        .init(pane: .integrations, title: "Slack pipeline", words: "slack pipeline works in model reply linear ticket bot review memories", query: "slack pipeline"),
        .init(pane: .integrations, title: "Vercel", words: "vercel deployments token", query: "vercel"),
        .init(pane: .integrations, title: "incident.io", words: "incident.io incidents api key", query: "incidents"),
        .init(pane: .integrations, title: "Granola", words: "granola meeting notes api key", query: "granola"),
        .init(pane: .integrations, title: "Modal", words: "modal apps containers gpu inference billing spend token", query: "modal"),
        .init(pane: .integrations, title: "Only my Granola notes", words: "granola only my notes private shared public hide", query: "granola"),
        .init(pane: .notifications, title: "When a session needs you", words: "notify session needs you question ask", query: "notify ask"),
        .init(pane: .notifications, title: "When a worker reports", words: "notify worker outcome finished blocked stalled review", query: "notify worker"),
        .init(pane: .notifications, title: "When something new reaches you on Slack", words: "notify slack mention message", query: "notify slack"),
        .init(pane: .notifications, title: "Dock badge", words: "dock badge count", query: "dock badge"),
        .init(pane: .notifications, title: "Banners and sounds", words: "system notification settings sound banner", query: "sound banner"),
        .init(pane: .advanced, title: ".env keys", words: ".env environment keys overrides add key", query: ""),
        .init(pane: .advanced, title: "Rebuild and relaunch", words: "rebuild relaunch app build bridge", query: ""),
    ]
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
        .onChange(of: model.settingsQuery, initial: true) { takeQuery() }
    }

    /// A search handed over by ⌘K: shown here, then cleared so the next one lands too.
    func takeQuery() {
        guard !model.settingsQuery.isEmpty else { return }
        query.v = model.settingsQuery.trimmingCharacters(in: .whitespaces)
        model.settingsQuery = ""
    }

    var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { p in
                SettingsNavItem(pane: p, on: !searching && p == pane, ns: ns) {
                    query.v = ""
                    withAnimation(M.snappy) { model.settingsPane = p.rawValue }
                }
            }
            RebuildButton().padding(.top, 10)
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
        case .rules: CommonRulesSettings(q: q)
        case .pipeline: PipelineSettings(q: q)
        case .mcp: CustomizeSettings(q: q)
        case .plugins: PluginsSettings(q: q)
        case .tokens: TokensSettings(q: q)
        case .integrations: IntegrationSettings(env: env, q: q)
        case .projects: ProjectSettings(q: q)
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

/// Rebuild Bridge.app from its own checkout and relaunch it, after a confirmation.
struct RebuildButton: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Button(action: confirm) {
            HStack(spacing: 6) {
                if model.building { ProgressView().controlSize(.mini) } else { Image(systemName: "hammer") }
                Text(model.building ? "Building…" : "Rebuild and Relaunch")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LButton())
        .disabled(model.building || model.bridgeRoot.isEmpty)
        .help(model.bridgeRoot.isEmpty ? "Bridge's source folder is unknown" : "Builds \(model.bridgeRoot), swaps the app in ~/Applications and reopens it")
    }

    func confirm() {
        let a = NSAlert()
        a.messageText = "Rebuild and relaunch Bridge?"
        a.informativeText = "Builds the app from \(model.bridgeRoot), replaces Bridge in ~/Applications and reopens it. The window closes while it relaunches; the server and running sessions keep going."
        a.addButton(withTitle: "Rebuild")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { model.rebuildApp() }
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
                    if !title.isEmpty || !detail.isEmpty {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prefix.isEmpty ? title : "\(prefix) · \(title)").font(T.ui(13, .semibold)).foregroundStyle(T.text)
                            if !detail.isEmpty { Text(detail).font(T.ui(12)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer()
                        trailing()
                    }
                    .padding(.horizontal, 2)
                    }
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
        .frame(width: width == .infinity ? nil : width, height: 28)
        .frame(maxWidth: width == .infinity ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.bg.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(focused ? T.accent.opacity(0.7) : T.line, lineWidth: 1))
        .shadow(color: T.accent.opacity(focused ? 0.25 : 0), radius: 4)
        .animation(M.hover, value: focused)
    }
}

/// A row bound to one `.env` key: plain values edit in place, secrets show
/// Set / Replace / Remove and never their value. `masked` hides a plain
/// value behind dots until its eye is clicked.
struct EnvField: View {
    @ObservedObject var env: EnvStore
    let e: JSON
    /// What Bridge works out when the key is empty (server/identity.js), shown as the placeholder.
    var derived = ""
    var masked = false
    @StateObject private var shown = Box(false)

    static let titles: [String: String] = [
        "SLACK_USER_TOKEN": "User OAuth token", "SLACK_USER_ID": "Member ID", "SLACK_USER_NAME": "Display name",
        "SLACK_PRODUCT_TEAM": "Product team", "SLACK_ENGINEER_TEAM": "Engineering team",
        "GITHUB_LOGIN": "GitHub login", "GITHUB_REPO": "Pull request repository",
        "LINEAR_API_KEY": "Personal API key", "LINEAR_WORKSPACE": "Workspace", "LINEAR_TEAM": "Team",
        "LINEAR_ISSUE_PREFIX": "Issue prefix", "LINEAR_PROJECT": "Project",
        "TARGET_REPO": "Pipeline repository", "TARGET_SCOPE": "Subdirectory scope", "WORKTREE_ROOT": "Worktree folder", "BRANCH_PREFIX": "Branch prefix",
        "PRODUCT_NAME": "Product name", "PRODUCT_URL": "Product URL",
        "BRIDGE_PORT": "Server port", "LAUNCHD_LABEL": "launchd label", "PIPELINE_MODEL": "Pipeline model",
        "EXTRA_PATH": "Extra PATH", "MCP_READ_PREFIXES": "Read-only MCP prefixes",
        "VERCEL_TOKEN": "Access token", "VERCEL_TEAM_ID": "Vercel team", "INCIDENT_API_KEY": "API key", "GRANOLA_API_KEY": "API key",
        "DD_API_KEY": "API key", "DD_APP_KEY": "Application key", "DD_SITE": "Site",
        "MODAL_TOKEN_ID": "Token ID", "MODAL_TOKEN_SECRET": "Token secret",
        "DEFAULT_DIR": "Default folder",
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
            if e["secret"].bool { secret } else if masked && e["set"].bool { revealable } else { input }
        }
    }

    var input: some View {
        SInput(placeholder: derived.isEmpty ? (e["example"].nonEmpty ?? "Not set") : derived, text: Binding(get: { env.edits[key] ?? e["value"].string }, set: { v in
            if v == e["value"].string { env.edits.removeValue(forKey: key) } else { env.edits[key] = v }
        }), mono: key.contains("PATH") || key.contains("REPO") || key.contains("ROOT"))
    }

    /// Dots until revealed; an unsaved edit stays visible.
    var revealable: some View {
        let open = shown.v || env.edits[key] != nil
        return HStack(spacing: 6) {
            if open { input } else { Dots() }
            IconButton(icon: open ? "eye.slash" : "eye", help: open ? "Hide the value" : "Show and edit the value", size: B.small) {
                withAnimation(M.snappy) { shown.v = !open }
            }
            .disabled(env.edits[key] != nil)
        }
    }

    @ViewBuilder var secret: some View {
        let set = e["set"].bool
        if masked && set && env.edits[key] == nil && !env.replacing.contains(key) {
            HStack(spacing: 8) {
                Dots(width: 160)
                Button("Replace") { withAnimation(M.snappy) { _ = env.replacing.insert(key) } }.buttonStyle(LButton())
                Button { env.edits[key] = "" } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(LButton(danger: true, square: true)).help("Remove from .env")
            }
        } else if set && env.edits[key] == "" {
            HStack(spacing: 8) {
                Chip(text: "Will be removed", tint: T.red)
                Button("Undo") { env.edits.removeValue(forKey: key) }.buttonStyle(LButton())
            }
        } else if set && !env.replacing.contains(key) {
            HStack(spacing: 8) {
                Chip(text: "Set", dot: T.green)
                Button("Replace") { withAnimation(M.snappy) { _ = env.replacing.insert(key) } }.buttonStyle(LButton())
                Button { env.edits[key] = "" } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(LButton(danger: true, square: true)).help("Remove from .env")
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

/// A hidden value: the same box as `SInput`, filled with dots.
struct Dots: View {
    var width: CGFloat = 260
    var body: some View {
        Text(verbatim: "••••••••••")
            .font(T.mono(12)).foregroundStyle(T.text3)
            .padding(.horizontal, 9)
            .frame(width: width, height: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.bg.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.line, lineWidth: 1))
            .accessibilityLabel("Hidden value")
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
                Text(".env is saved, but the running server still uses the old values. Running sessions restart with it.").font(T.ui(12)).foregroundStyle(T.text2)
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
            SSection(title: "Appearance") {
                if Prefs.hit(q, "appearance theme light dark mode system color") {
                    SRow(title: "Theme", detail: "Light, dark, or follow macOS") {
                        SlidingTabs(tabs: [
                            .init(id: "system", label: "System", icon: "circle.lefthalf.filled"),
                            .init(id: "light", label: "Light", icon: "sun.max"),
                            .init(id: "dark", label: "Dark", icon: "moon"),
                        ], selection: Binding(get: { model.appearance }, set: { v in model.appearance = v }))
                    }
                }
            }
            SSection(title: "Server") {
                if Prefs.hit(q, "restart server reload") {
                    SRow(title: "Restart the server", detail: "Reloads server/, .env and the skills. Running sessions restart with it.") {
                        Button("Restart") { Task { await model.restartServer() } }.buttonStyle(LButton())
                    }
                }
            }
            SSection(title: "Inbox", detail: "How much Bridge asks you, and how much the orchestrator does on its own") {
                if Prefs.hit(q, "relay mode normal quiet away off inbox outcomes orchestrator workers") {
                    SRow(title: "Relay mode", detail: "Normal: you decide everything. Quiet: routine approvals take the recommended option; risky or outward ones still ask. Away: the orchestrator runs things and leaves one digest. Off relays nothing") {
                        SlidingTabs(tabs: [
                            .init(id: "off", label: "Off", icon: "bell.slash"),
                            .init(id: "normal", label: "Normal", icon: "bell"),
                            .init(id: "quiet", label: "Quiet", icon: "moon"),
                            .init(id: "away", label: "Away", icon: "airplane"),
                        ], selection: Binding(
                            get: { model.config["harness"]["relay"].bool ? (model.inbox["mode"].nonEmpty ?? model.config["harness"]["mode"].nonEmpty ?? "normal") : "off" },
                            set: { v in Task {
                                let on = v != "off"
                                if on != model.config["harness"]["relay"].bool { await model.saveConfig(["harness": ["relay": on]]) }
                                if on { await model.setMode(v) }
                            } }))
                    }
                }
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
            FailoverSettings(q: q)
            WorkerSettings(q: q)
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

struct FailoverSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var h: JSON { model.config["harness"] }
    var order: [String] {
        let saved = h["failoverOrder"].array.map(\.string)
        return saved.count == 3 ? saved : ["devin", "codex", "cursor"]
    }
    let choices = [("devin", "Devin"), ("codex", "Codex"), ("cursor", "Cursor")]

    var body: some View {
        SSection(title: "Automatic failover", detail: "Move Claude workers on their next turn when plan usage is tight") {
            if Prefs.hit(q, "automatic failover claude usage threshold preference order") {
                SRow(title: "Fail over workers", detail: "The orchestrator stays on Claude until a limit reaches 100%") {
                    SToggle(on: Binding(get: { h["failover"].bool }, set: { save(["failover": $0]) }))
                }
                if h["failover"].bool {
                    SRow(title: "Claude threshold", detail: "Either the 5-hour or weekly window") {
                        SStepper(value: h["failoverThreshold"].int == 0 ? 95 : h["failoverThreshold"].int, range: 50...100, step: 5, unit: "%") { save(["failoverThreshold": $0]) }
                    }
                    ForEach(Array(order.enumerated()), id: \.offset) { i, agent in
                        SRow(title: i == 0 ? "First choice" : i == 1 ? "Second choice" : "Third choice") {
                            SSelect(value: agent, choices: choices) { pick($0, at: i) }
                        }
                    }
                }
            }
        }
    }

    func pick(_ agent: String, at index: Int) {
        var next = order
        guard let old = next.firstIndex(of: agent) else { return }
        next.swapAt(index, old)
        save(["failoverOrder": next])
    }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(["harness": patch]) } }
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
        }
    }

    var modelChoices: [(String, String)] {
        let catalog = model.models(for: agent).map { ($0["id"].string, $0["label"].nonEmpty ?? $0["id"].string) }
        if agent == .claude { return catalog.isEmpty ? JobOption.all.first { $0.key == "model" }?.choices ?? [] : catalog }
        return [("", "Default")] + catalog
    }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(["followup": patch]) } }
}

/// House rules added to every session's instructions (server/rules.js):
/// prompts/rules.md until edited here, then data/rules.md.
struct CommonRulesSettings: View {
    let q: String
    @StateObject private var text = Box("")
    @StateObject private var saved = Box("")
    @StateObject private var custom = Box(false)
    @StateObject private var loaded = Box(false)
    @Environment(AppModel.self) var model

    var dirty: Bool { text.v != saved.v }

    var body: some View {
        SSection(title: "Common rules", detail: "Markdown. {{USER}} becomes your name; a repo's own CLAUDE.md or AGENTS.md still applies on top. Clear it to turn the rules off") {
            if Prefs.hit(q, "common rules house rules instructions prompt worktree rebase branch pr") { editor }
        } trailing: {
            actions
        }
        .task { apply(try? await API.get("/api/rules")) }
    }

    var editor: some View {
        MarkdownEditor(text: $text.v, enabled: loaded.v)
            .frame(minHeight: 560)
            .padding(8)
            .opacity(loaded.v ? 1 : 0.5)
    }

    var actions: some View {
        HStack(spacing: 8) {
            if dirty { Button("Revert") { text.v = saved.v }.buttonStyle(LButton(small: true)) }
            else if custom.v { Button("Reset to Default") { post(["reset": true], done: "Common rules reset") }.buttonStyle(LButton(small: true)) }
            Button("Save") { post(["text": text.v], done: "Common rules saved") }
                .buttonStyle(LButton(primary: true, small: true)).keyboardShortcut("s").disabled(!dirty)
        }
    }

    func apply(_ j: JSON?) {
        guard let j else { return }
        text.v = j["text"].string
        saved.v = text.v
        custom.v = j["custom"].bool
        loaded.v = true
    }

    func post(_ body: [String: Any], done: String) {
        Task {
            await model.act {
                self.apply(try await API.post("/api/rules", body))
                self.model.say(done)
            }
        }
    }
}

struct WorkerSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var h: JSON { model.config["harness"] }
    /// The days field as typed; nil shows the saved value.
    @StateObject private var archiveDays = Box<String?>(nil)

    var body: some View {
        SSection(title: "Sessions", detail: "Workers run in parallel, with no cap") {
            if Prefs.hit(q, "stalled silence minutes stall") {
                SRow(title: "Stalled after", detail: "Silence before a working worker is flagged") {
                    SStepper(value: h["stallMinutes"].int, range: 5...120, step: 5, unit: "min") { save(["stallMinutes": $0]) }
                }
            }
            if Prefs.hit(q, "auto archive merged days pr") {
                let days = h["autoArchiveDays"].int
                SRow(title: "Auto-archive merged chats", detail: days == 0 ? "Off: merged chats stay in the sidebar" : "Archived once the PR has been merged this long (up to 14 days); the worktree stays") {
                    HStack(spacing: 8) {
                        SInput(placeholder: "0", text: Binding(get: { archiveDays.v ?? "\(days)" }, set: { v in
                            archiveDays.v = v
                            if let n = Int(v.trimmingCharacters(in: .whitespaces)), (0...14).contains(n), n != days { save(["autoArchiveDays": n]) }
                        }), width: 52)
                        Text(days == 1 ? "day" : "days").font(T.ui(12.5)).foregroundStyle(T.text2)
                        SToggle(on: Binding(get: { days > 0 }, set: { on in archiveDays.v = nil; save(["autoArchiveDays": on ? 1 : 0]) }))
                    }
                }
            }
        }
    }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(["harness": patch]) } }
}

// MARK: - Integrations
//
// One group per service: a header with its status and "In sidebar" switch,
// then only what that service needs. Identities, teams and repos are worked
// out by the server (server/identity.js); pickers replace typed .env values,
// and the raw keys live under Advanced as overrides.

/// A service's header: icon, name, what it powers, status, and the sidebar switch.
struct IntegrationHeader: View {
    @Environment(AppModel.self) var model
    let kind: SourceKind
    let title: String
    let detail: String
    let connected: Bool
    var status = ""

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: kind.icon).font(.system(size: 15, weight: .medium)).foregroundStyle(connected ? T.accent : T.text2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(connected ? T.accentSoft : T.raised))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.line, lineWidth: connected ? 0 : 1))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(T.ui(15, .semibold)).foregroundStyle(T.text)
                    StatusChip(on: connected, onText: status.isEmpty ? "Connected" : status)
                }
                Text(detail).font(T.ui(12)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Text("In sidebar").font(T.ui(12)).foregroundStyle(T.text2)
                SToggle(on: Binding(get: { model.sourceShown(kind) }, set: { model.setSource(kind, shown: $0) }))
            }
            .help("Show \(kind.label) in the sidebar's Sources. Hidden, it's still in ⌘K")
        }
        .padding(.bottom, 12)
    }
}

struct IntegrationSettings: View {
    @Environment(AppModel.self) var model
    @ObservedObject var env: EnvStore
    let q: String

    var id: JSON { model.identity }
    func show(_ words: String...) -> Bool { Prefs.hit(q, words.joined(separator: " ")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if show("github pull requests gh login checks") { github }
            if show("linear issues api key team tickets") { linear }
            if show("slack token watch mentions channels pipeline threads triage") { slack }
            if show("vercel deployments token") { vercel }
            if show("incident.io incidents api key") { incidents }
            if show("granola meeting notes api key only my private shared public") { granola }
            if show("datadog monitors errors error tracking api application key site") { datadog }
            if show("modal apps containers gpu inference billing spend token") { modal }
        }
        .task { await model.loadIdentity() }
    }

    var github: some View {
        let login = model.pulls["login"].nonEmpty ?? id["github"]["login"].nonEmpty
        return VStack(alignment: .leading, spacing: 0) {
            IntegrationHeader(kind: .github, title: "GitHub", detail: "Your pull requests, checks and reviews, through the gh CLI's login. Each project's repo comes from its own git remote.", connected: login != nil, status: login.map { "@\($0)" } ?? "")
            SSection(title: "") {
                SRow(title: login == nil ? "Not signed in" : "Signed in with gh", detail: login == nil ? "Run gh auth login in a terminal, then refresh" : "Bridge reads and opens PRs as @\(login!); branches start with \(id["derived"]["BRANCH_PREFIX"].nonEmpty ?? login!)/") {
                    if login == nil {
                        Button { ConsoleStore.shared.add(NSHomeDirectory()); ConsoleStore.shared.show() } label: { Label("Open Terminal", systemImage: "terminal") }.buttonStyle(LButton())
                    } else {
                        IconButton(icon: "arrow.clockwise", help: "Check again", size: B.small) { Task { await model.load("pulls", refresh: true); await model.loadIdentity(refresh: true) } }
                    }
                }
            }
        }
    }

    var linear: some View {
        let teams = id["linear"]["teams"].array
        let on = model.linear["configured"].bool
        return VStack(alignment: .leading, spacing: 0) {
            IntegrationHeader(kind: .linear, title: "Linear", detail: "Issues assigned to you, cross-linked to the sessions working on them. Sessions never see the key.", connected: on, status: id["linear"]["org"].nonEmpty ?? model.linear["viewer"].nonEmpty ?? "")
            SSection(title: "") {
                ForEach(env.rows(["LINEAR_API_KEY"], ""), id: \.self) { EnvField(env: env, e: $0) }
                if on && !teams.isEmpty {
                    SRow(title: "Team", detail: "Where the Slack pipeline files tickets; their keys start with its prefix") {
                        SSelect(value: model.config["harness"]["linearTeam"].nonEmpty ?? teams.first?["key"].string ?? "",
                                choices: teams.map { ($0["key"].string, "\($0["name"].string) · \($0["key"].string)") }) { save(["linearTeam": $0]) }
                    }
                }
            }
        }
    }

    var slack: some View {
        let on = model.slack["configured"].bool
        let me = id["slack"]
        return VStack(alignment: .leading, spacing: 0) {
            IntegrationHeader(kind: .slack, title: "Slack", detail: "Mentions, watched channels and threads, read as you with a user token: no bot to invite.", connected: on, status: model.slack["team"].nonEmpty ?? "")
            SSection(title: "") {
                ForEach(env.rows(["SLACK_USER_TOKEN"], ""), id: \.self) { EnvField(env: env, e: $0) }
                if on, let name = me["name"].nonEmpty {
                    SRow(title: "Signed in as \(name)", detail: [me["team"].string, me["userId"].string].filter { !$0.isEmpty }.joined(separator: " · ")) { EmptyView() }
                }
                if !on {
                    SRow(title: "Set up the Slack app", detail: "Create it from the manifest once, install it to yourself, and paste its xoxp- token above") {
                        HStack(spacing: 8) {
                            Button { openURL("https://github.com/george-bobby/bridge/blob/main/docs/slack.md") } label: { Label("Guide", systemImage: "book") }.buttonStyle(LButton())
                            Button { openURL("https://api.slack.com/apps?new_app=1") } label: { Label("Create app", systemImage: "arrow.up.right") }.buttonStyle(LButton())
                        }
                    }
                }
            }
            if on {
                SlackWatchSettings(q: "")
                SlackPipelineSettings()
            }
        }
    }

    func keyGroup(_ kind: SourceKind, _ title: String, _ detail: String, _ keys: [String], on: Bool, status: String = "", link: (String, String)?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            IntegrationHeader(kind: kind, title: title, detail: detail, connected: on, status: status)
            SSection(title: "") {
                ForEach(env.rows(keys, ""), id: \.self) { EnvField(env: env, e: $0) }
                if !on, let link {
                    SRow(title: "Get a key", detail: link.0) {
                        Button { openURL(link.1) } label: { Label("Open", systemImage: "arrow.up.right") }.buttonStyle(LButton())
                    }
                }
            }
        }
    }

    var vercel: some View {
        keyGroup(.vercel, "Vercel", "Deployments across your account and teams; a preview opens next to the session on its branch.", ["VERCEL_TOKEN"],
                 on: model.vercel["configured"].bool, status: model.vercel["user"].nonEmpty.map { "@\($0)" } ?? "",
                 link: ("Account Settings › Tokens. A team that enforces SAML needs a token scoped to it: add one per team, comma-separated", "https://vercel.com/account/settings/tokens"))
    }

    var incidents: some View {
        keyGroup(.incidents, "incident.io", "Live and recent incidents. An admin creates the key under Settings › API keys.", ["INCIDENT_API_KEY"],
                 on: model.incidents["configured"].bool, link: ("Settings › API keys in incident.io (admins), read access to incidents", "https://app.incident.io/settings/api-keys"))
    }

    var granola: some View {
        let on = model.granola["configured"].bool
        return VStack(alignment: .leading, spacing: 0) {
            keyGroup(.granola, "Granola", "Your meeting notes with their summaries and attendees.", ["GRANOLA_API_KEY"],
                     on: on, link: ("In the Granola app: Settings › Connectors › API keys (Business and Enterprise)", "https://docs.granola.ai"))
            if on { GranolaPrivacy() }
        }
    }

    var datadog: some View {
        keyGroup(.datadog, "Datadog", "Monitors that are alerting, warning or without data, and the last day's open Error Tracking issues. Read-only.", ["DD_API_KEY", "DD_APP_KEY", "DD_SITE"],
                 on: model.datadog["configured"].bool, status: model.datadog["site"].string,
                 link: ("An API key (Organization Settings) and an application key with monitors_read and error_tracking_read (Personal Settings)", "https://app.datadoghq.com/personal-settings/application-keys"))
    }

    var modal: some View {
        keyGroup(.modal, "Modal", "Apps per environment with their functions and web endpoints, live containers, GPU spend and this month's bill, through the modal CLI. Leave the token blank to use the CLI's own login (~/.modal.toml). Read-only.", ["MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"],
                 on: model.modal["configured"].bool, status: model.modal["workspace"].string,
                 link: ("A token pair from modal.com › Settings › API Tokens, or run `modal setup` once", "https://modal.com/settings/tokens"))
    }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(["harness": patch]); await model.loadIdentity() } }
}

/// Granola's API has no visibility flag and notes are private until shared, so
/// "yours" (owner = git's user.email) is the one reliable private/public line.
struct GranolaPrivacy: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let me = model.granola["me"].string
        let notes = model.granola["notes"].array
        let mine = notes.filter { $0["mine"].bool }.count
        SSection(title: "Notes") {
            SRow(title: "Only my notes", detail: me.isEmpty
                 ? "Hides notes others shared with you or posted to the workspace. Bridge matches note owners to git's user.email, which isn't set"
                 : "Hides notes others shared with you or posted to the workspace: \(mine) of the last \(notes.count) are yours (\(me))") {
                SToggle(on: Binding(get: { model.config["harness"]["granolaMine"].bool }, set: { v in Task { await model.saveConfig(["harness": ["granolaMine": v]]) } }))
            }
        }
    }
}

/// Where a run started from a Slack thread works, with which model, and what it may prepare.
struct SlackPipelineSettings: View {
    @Environment(AppModel.self) var model

    var h: JSON { model.config["harness"] }
    var repo: JSON { model.identity["repo"] }

    var body: some View {
        SSection(title: "Slack pipeline", detail: "What a run started from a Slack thread works on, and may prepare for you") {
            let real = model.projects.filter { !$0.root }
            if !real.isEmpty {
                SRow(title: "Works in", detail: repo["github"].nonEmpty.map { "Opens pull requests on \($0)" } ?? "The project Slack threads are worked in") {
                    SSelect(value: h["pipelineProject"].nonEmpty ?? repo["project"].nonEmpty ?? real.first?.id ?? "", choices: real.map { ($0.id, $0.name) }) { save(["pipelineProject": $0]) }
                }
            }
            SRow(title: "Model", detail: "The Claude model the pipeline runs on") {
                let catalog = model.models(for: .claude).map { ($0["id"].string, $0["label"].nonEmpty ?? $0["id"].string) }
                SSelect(value: h["pipelineModel"].nonEmpty ?? model.identity["derived"]["PIPELINE_MODEL"].nonEmpty ?? "opus",
                        choices: catalog.isEmpty ? [("opus", "Opus"), ("sonnet", "Sonnet")] : catalog) { save(["pipelineModel": $0]) }
            }
            toggle("Draft the reply in the thread", "reply", "Posted only after you approve it")
            toggle("Offer a Linear ticket", "createLinearIssue", "Created only after you approve it")
            toggle("Wait for bot review, then resolve", "botReview", "After the PR opens, wait for the review bots, then run /resolve")
            toggle("Propose memories", "saveToMemory", "Nothing is saved without your approval")
        }
    }

    func toggle(_ title: String, _ key: String, _ hint: String) -> some View {
        SRow(title: title, detail: hint) {
            SToggle(on: Binding(get: { model.config[key].bool }, set: { v in Task { await model.saveConfig([key: v]) } }))
        }
    }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(["harness": patch]); await model.loadIdentity() } }
}

/// server/watch.js: what Bridge reads from Slack on its own, and how often.
struct SlackWatchSettings: View {
    @Environment(AppModel.self) var model
    let q: String
    @StateObject private var channels = Box(JSON.null)
    @StateObject private var channelsError = Box("")

    var h: JSON { model.config["harness"] }
    var watched: [String] { h["slackChannels"].array.map(\.string) }

    var body: some View {
        SSection(title: "Slack watch", detail: "Mentions, watched channels and replies in threads that have a chat, read on a timer with your token. No agent runs unless you start one, or triage is on") {
            if Prefs.hit(q, "slack watch mentions mode off triage orchestrator") {
                SRow(title: "Watch", detail: "Off; Watch files them in the Inbox; Triage also lets the orchestrator start the real work and skip the rest") {
                    SlidingTabs(tabs: [
                        .init(id: "off", label: "Off", icon: "pause"),
                        .init(id: "watch", label: "Watch", icon: "eye"),
                        .init(id: "triage", label: "Triage", icon: "sparkles"),
                    ], selection: Binding(get: { h["slackWatch"].nonEmpty ?? "watch" }, set: { v in save(["slackWatch": v]) }))
                }
            }
            if Prefs.hit(q, "slack poll interval check every minutes") {
                SRow(title: "Check every", detail: Fmt.checked(model.slackWatch["lastPollAt"].double)) {
                    SStepper(value: max(1, (h["slackPollSec"].int == 0 ? 120 : h["slackPollSec"].int) / 60), range: 1...60, unit: "min") { save(["slackPollSec": $0 * 60]) }
                }
            }
            if Prefs.hit(q, "slack watched channels channel posts") {
                SRow(title: "Watched channels", detail: watched.isEmpty ? "New top-level posts in these land in the Inbox too" : watched.map(name).joined(separator: ", ")) {
                    channelMenu
                }
            }
        }
        .task(id: model.slack["configured"].bool) { await loadChannels() }
    }

    /// Keyed to the connection: connecting Slack while this page is open loads them then.
    func loadChannels() async {
        guard model.slack["configured"].bool else { return }
        channelsError.v = ""
        do { channels.v = try await API.get("/api/slack/channels") } catch { channelsError.v = error.localizedDescription }
    }

    var channelMenu: some View {
        Menu {
            let list = channels.v["channels"].array
            if !model.slack["configured"].bool {
                Text("Connect Slack first")
            } else if !channelsError.v.isEmpty {
                Text("Couldn't load channels: \(channelsError.v)")
                Button("Retry") { Task { await loadChannels() } }
            } else if channels.v.isNull {
                Text("Loading channels…")
            } else if list.isEmpty {
                Text("You aren't in any channels")
            }
            ForEach(list, id: \.self) { c in
                let id = c["id"].string, on = watched.contains(id)
                Button { save(["slackChannels": on ? watched.filter { $0 != id } : watched + [id]]) } label: {
                    if on { Label(c["name"].string, systemImage: "checkmark") } else { Text(c["name"].string) }
                }
            }
        } label: { Label(watched.isEmpty ? "Choose" : "\(watched.count) watched", systemImage: "number") }
        .menuStyle(.button).buttonStyle(LButton()).fixedSize()
    }

    func name(_ id: String) -> String { channels.v["channels"].array.first { $0["id"].string == id }?["name"].string ?? id }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(["harness": patch]) } }
}

// MARK: - Projects

/// One row per project (its ⋯ is the sidebar's `ProjectMenu`), then each
/// project's own settings below the list.
struct ProjectSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SSection(title: "Projects", detail: "Default holds sessions outside any repo") {
                ForEach(model.projects.filter { Prefs.hit(q, $0.name, $0.path, "project projects repository default orchestrator") }) { p in
                    SRow(title: p.name, detail: p.path, icon: AnyView(ProjectBadge(project: p, size: 24))) {
                        HStack(spacing: 6) {
                            Button("Orchestrator") { model.openOrchestrator(p.id) }.buttonStyle(LButton(small: true))
                            MoreMenu(size: B.small) { ProjectMenu(project: p) }
                        }
                    }
                }
            } trailing: {
                if q.isEmpty { Button { model.addProject() } label: { Label("Add project", systemImage: "plus") }.buttonStyle(LButton(small: true)) }
            }
            // Per-project settings: pick the project in the section's header.
            ProjectAutomation(q: q)
        }
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
                if Prefs.hit(q, "notify slack mention message") {
                    SRow(title: "When something new reaches you on Slack", detail: "New mentions and watched-channel posts, and replies in threads you have a chat on") { SToggle(on: $m.notifyMentions) }
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

/// The keys set in `.env`, by `.env.example` section: plain values hidden
/// until revealed, secrets write-only. Unset documented keys can be added.
struct AdvancedSettings: View {
    @Environment(AppModel.self) var model
    @ObservedObject var env: EnvStore
    let q: String
    /// Keys picked from "Add key" this visit: shown with an empty field until saved.
    @StateObject private var adding = Box([String]())

    var shown: [JSON] { env.entries.filter { $0["set"].bool || adding.v.contains($0["key"].string) } }
    var unset: [JSON] { env.entries.filter { !$0["set"].bool && !adding.v.contains($0["key"].string) } }
    var sections: [String] {
        var seen: [String] = []
        for e in shown where !seen.contains(e["section"].string) { seen.append(e["section"].string) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).task { await model.loadIdentity() }
            if env.loaded && shown.isEmpty && Prefs.hit(q, ".env environment keys empty") {
                SSection(title: "") {
                    SRow(title: "Nothing set in .env", detail: "Bridge works out the rest itself. Add a key to override it") { addMenu }
                }
            }
            ForEach(sections, id: \.self) { s in
                SSection(title: s) {
                    ForEach(env.rows(shown.filter { $0["section"].string == s }.map { $0["key"].string }, q), id: \.self) {
                        EnvField(env: env, e: $0, derived: model.identity["derived"][$0["key"].string].string, masked: true)
                    }
                } trailing: {
                    if s == sections.first { addMenu }
                }
            }
        }
    }

    /// Documented keys that aren't set yet, by section.
    var addMenu: some View {
        Menu {
            let groups = Dictionary(grouping: unset) { $0["section"].string }
            ForEach(Array(groups.keys).sorted(), id: \.self) { s in
                Section(s) {
                    ForEach(groups[s] ?? [], id: \.self) { e in
                        Button("\(EnvField.title(e["key"].string)) · \(e["key"].string)") { withAnimation(M.snappy) { adding.v.append(e["key"].string) } }
                    }
                }
            }
            if unset.isEmpty { Text("Every documented key is set") }
        } label: { Label("Add key", systemImage: "plus") }
        .menuStyle(.button).buttonStyle(LButton(small: true)).fixedSize()
    }
}
