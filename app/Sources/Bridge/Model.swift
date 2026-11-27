import Foundation
import Observation
import SwiftUI
import UserNotifications

// MARK: - Typed views over the payloads

struct Session: Identifiable, Hashable {
    let j: JSON
    var id: String { j["runId"].string }
    var kind: String { j["kind"].string }
    var isTask: Bool { kind == "task" }
    var isOrchestrator: Bool { kind == "orchestrator" }
    var task: JSON { j["task"] }
    var taskStatus: String { task["status"].string }
    var branch: String { task["branch"].string }
    var title: String { (isTask ? task["title"].nonEmpty : nil) ?? j["who"].nonEmpty ?? "Session" }
    var who: String { j["who"].string }
    var channel: String { j["channel"].string }
    var text: String { j["text"].string }
    var lastText: String { j["lastText"].string }
    var action: String { j["action"].string }
    var prUrl: String { j["prUrl"].string }
    var linearUrl: String { j["linearUrl"].string }
    var permalink: String { j["permalink"].string }
    var boardPin: String { j["board"].string }
    var pinned: Bool { j["pinned"].bool }
    var archived: Bool { j["archived"].bool }
    var archivedAt: Double { j["archivedAt"].double }
    var project: String { j["project"].string }
    var updatedAt: Double { j["updatedAt"].double }
    var createdAt: Double { j["createdAt"].double }
    var worked: Bool { j["worked"].bool }
    var unread: Bool { j["unread"].bool }
    var askedFor: String { j["askedFor"].string }
    var statusLine: String { task["declared"]["text"].nonEmpty ?? task["phase"].string }
    var worktree: String { task["worktree"].nonEmpty ?? j["workdir"].string }
    var prNumber: String {
        guard let r = prUrl.range(of: #"/pull/(\d+)"#, options: .regularExpression) else { return "" }
        return String(prUrl[r].dropFirst(6))
    }
    var snippet: String {
        let s = isTask ? (lastText.isEmpty ? text : lastText) : text
        return Session.plain(Session.withoutFiles(s))
    }

    /// Text without the attachment lines the composer adds or a pasted file path
    /// on its own line: a preview shows the words, never a saved file's path.
    static func withoutFiles(_ s: String) -> String {
        guard s.contains("/") else { return s }
        return Memo.string(Memo.plain, "files:" + s) {
            s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[Attached ") || t.hasPrefix("[Referenced session ") { return false }
                return t.range(of: #"^["']?(file://|~/|/)\S.*\.[A-Za-z0-9]{1,5}["']?$"#, options: .regularExpression) == nil
            }.joined(separator: "\n")
        }
    }

    /// The Linear key this session is about: its ticket link, branch or title.
    /// Memoised on its inputs: the board, sidebar and details ask for it per
    /// session on every render, and it's two regex scans.
    var issueKey: String {
        let hay = [linearUrl, branch.uppercased(), title, text].joined(separator: " ")
        return Memo.string(Memo.issueKeys, hay) {
            if let r = hay.range(of: #"/issue/[A-Za-z][A-Za-z0-9]{1,9}-\d+"#, options: .regularExpression) {
                return String(hay[r].dropFirst(7)).uppercased()
            }
            if let r = hay.range(of: #"\b[A-Z][A-Z0-9]{1,9}-\d+\b"#, options: .regularExpression) { return String(hay[r]) }
            return ""
        }
    }

    /// Slack mrkdwn to plain text: `<url|label>` to label, `<@U123>` dropped.
    /// Five regex passes, memoised: every sidebar row and card calls it per render.
    static func plain(_ s: String) -> String {
        Memo.string(Memo.plain, s) {
            var t = s.replacingOccurrences(of: #"<([^|>]+)\|([^>]+)>"#, with: "$2", options: .regularExpression)
            t = t.replacingOccurrences(of: #"<[@#!][^>]+>"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
            return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Small string-to-string caches for derived text that's pure in its input.
enum Memo {
    static let plain = make()
    static let issueKeys = make()
    static let urls = make()

    private static func make() -> NSCache<NSString, NSString> {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 5000
        return c
    }

    static func string(_ cache: NSCache<NSString, NSString>, _ key: String, _ make: () -> String) -> String {
        let k = key as NSString
        if let hit = cache.object(forKey: k) { return hit as String }
        let v = make()
        cache.setObject(v as NSString, forKey: k)
        return v
    }
}

struct Project: Identifiable, Hashable {
    let j: JSON
    var id: String { j["id"].string }
    var name: String { j["name"].nonEmpty ?? id }
    var path: String { j["path"].string }
    /// Default: not a repo, the root folder general sessions run in.
    var root: Bool { j["root"].bool }
    var shortPath: String { path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path }
}

struct Mention: Identifiable, Hashable {
    let j: JSON
    var id: String { j["ts"].string + j["channelId"].string }
    var who: String { j["who"].string }
    var avatar: String { j["avatar"].string }
    var channel: String { j["channel"].string }
    var text: String { j["text"].string }
    var permalink: String { j["permalink"].string }
    var user: String { j["user"].string }
    var threadTs: String { j["threadTs"].string }
    var ts: Double { j["ts"].double }
}

struct PullRequest: Identifiable, Hashable {
    let j: JSON
    var id: String { url }
    var url: String { j["url"].string }
    var number: Int { j["number"].int }
    var title: String { j["title"].string }
    var repo: String { j["repo"].string }
    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var author: String { j["author"].string }
    var avatar: String { j["avatar"].string }
    var draft: Bool { j["draft"].bool }
    var state: String { j["state"].string }
    var review: String { j["review"].string }
    var checks: String { j["checks"].string }
    var mergeable: String { j["mergeable"].string }
    var branch: String { j["branch"].string }
    var additions: Int { j["additions"].int }
    var deletions: Int { j["deletions"].int }
    var comments: Int { j["comments"].int }
    var updatedAt: Double { Fmt.iso(j["mergedAt"].nonEmpty ?? j["updatedAt"].string) }
    var issueKey: String { j["issueKey"].string }
    var open: Bool { state == "OPEN" }
    var failing: Bool { checks == "FAILURE" || checks == "ERROR" }
    var running: Bool { checks == "PENDING" || checks == "EXPECTED" }
    var passCount: Int { j["checkCounts"]["pass"].int }
    var failCount: Int { j["checkCounts"]["fail"].int }
    var pendingCount: Int { j["checkCounts"]["pending"].int }
    var skippedCount: Int { j["checkCounts"]["skipped"].int }
    var stateLabel: String { state == "MERGED" ? "Merged" : state == "CLOSED" ? "Closed" : draft ? "Draft" : "Open" }
    var needsAttention: Bool { open && (failing || review == "CHANGES_REQUESTED" || mergeable == "CONFLICTING") }
}

struct ChildIssue: Identifiable, Hashable {
    let j: JSON
    var id: String { key }
    var key: String { j["key"].string }
    var title: String { j["title"].string }
    var url: String { j["url"].string }
    var priority: Int { j["priority"].int }
    var state: String { j["state"].string }
    var stateType: String { j["stateType"].string }
    var stateColor: String { j["stateColor"].string }
    var assignee: String { j["assignee"].string }
    var assigneeAvatar: String { j["assigneeAvatar"].string }
    var mine: Bool { j["mine"].bool }
    var status: StatusKind { StatusKind.linear(type: stateType, name: state) }
}

struct Issue: Identifiable, Hashable {
    let j: JSON
    var id: String { key }
    var key: String { j["key"].string }
    var title: String { j["title"].string }
    var url: String { j["url"].string }
    var priority: Int { j["priority"].int }
    var priorityLabel: String { j["priorityLabel"].string }
    var branch: String { j["branch"].string }
    var state: String { j["state"].string }
    var stateType: String { j["stateType"].string }
    var stateColor: String { j["stateColor"].string }
    var statePos: Double { j["statePos"].double }
    /// The Slack thread the issue came from (an attachment or a link in its description).
    var slackUrl: String { j["slackUrl"].string }
    var team: String { j["team"].string }
    var project: String { j["project"].string }
    var cycle: Int? { j["cycle"].isNull ? nil : j["cycle"].int }
    var labels: [(String, String)] { j["labels"].array.map { ($0["name"].string, $0["color"].string) } }
    var description: String { j["description"].string }
    var updatedAt: Double { Fmt.iso(j["updatedAt"].string) }
    var assignee: String { j["assignee"].string }
    var assigneeAvatar: String { j["assigneeAvatar"].string }
    var parentKey: String { j["parent"]["key"].string }
    var parentTitle: String { j["parent"]["title"].string }
    var children: [ChildIssue] { j["children"].array.map(ChildIssue.init) }
    var childrenDone: Int { children.filter { $0.stateType == "completed" || $0.stateType == "canceled" }.count }
    var status: StatusKind { StatusKind.linear(type: stateType, name: state) }
    var active: Bool { stateType != "completed" && stateType != "canceled" }
}

struct DevServer: Identifiable, Hashable {
    let j: JSON
    var id: Int { j["pid"].int }
    var command: String { j["command"].string }
    var cwd: String { j["cwd"].string }
    var ports: [Int] { j["ports"].array.map(\.int) }
    var folder: String { cwd.split(separator: "/").suffix(3).joined(separator: "/") }
}

// MARK: - Board columns

enum Column: String, CaseIterable, Identifiable {
    case backlog, doing, needs, review, done
    var id: String { rawValue }
    init(linear kind: StatusKind) {
        switch kind {
        case .triage, .backlog, .todo: self = .backlog
        case .progress: self = .doing
        case .review: self = .review
        case .done, .canceled: self = .done
        case .attention: self = .needs
        }
    }
    var label: String {
        switch self {
        case .backlog: return "Backlog"
        case .doing: return "In Progress"
        case .needs: return "Needs You"
        case .review: return "In Review"
        case .done: return "Done"
        }
    }
    var status: StatusKind {
        switch self {
        case .backlog: return .backlog
        case .doing: return .progress
        case .needs: return .attention
        case .review: return .review
        case .done: return .done
        }
    }
}

let needsStatuses: Set<String> = ["needs-input", "blocked", "worker-stalled", "worker-gone", "usage-limit", "idle-without-report"]

let statusLabels: [String: String] = [
    "ready-for-review": "Ready", "needs-input": "Needs input", "blocked": "Blocked", "pushed-follow-up": "Pushed",
    "idle-without-report": "No report", "worker-stalled": "Stalled", "worker-gone": "Lost", "usage-limit": "Usage limit",
    "working": "Working", "cleaned": "Cleaned up", "stopped": "Stopped", "idle": "Replied",
]

// MARK: - Routes

enum Route: Hashable {
    case home, inbox, slack, board, sessions, pulls, linear, vercel, incidents, granola, datadog, models, memory, usage, settings
    /// New task: the composer as its own page, like a fresh chat.
    case compose
    case session(String)

    var title: String {
        switch self {
        case .home: return "Home"
        case .inbox: return "Inbox"
        case .slack: return "Slack"
        case .usage: return "Usage"
        case .board: return "Board"
        case .sessions: return "Sessions"
        case .pulls: return "GitHub"
        case .linear: return "Linear"
        case .vercel: return "Vercel"
        case .incidents: return "Incidents"
        case .granola: return "Granola"
        case .datadog: return "Datadog"
        case .models: return "Models"
        case .memory: return "Memory"
        case .settings: return "Settings"
        case .compose: return "New task"
        case .session: return "Session"
        }
    }
}

// MARK: - App state

@MainActor
@Observable
final class AppModel {
    var route: Route = .home {
        didSet {
            guard route != oldValue else { return }
            // The New task page isn't history: Back from its session skips it.
            if !travelling && oldValue != .compose {
                backStack.append(oldValue)
                if backStack.count > 60 { backStack.removeFirst() }
                forwardStack.removeAll()
            }
            if route == .board || route == .sessions {
                sessionsRoute = route
                UserDefaults.standard.set(route == .board ? "board" : "list", forKey: "sessions.layout")
            }
        }
    }
    var backStack: [Route] = []
    var forwardStack: [Route] = []
    @ObservationIgnored private var travelling = false
    var sessionsRoute: Route = UserDefaults.standard.string(forKey: "sessions.layout") == "list" ? .sessions : .board
    var connected = false
    var everConnected = false

    var config: JSON = .null
    var running: Set<String> = []
    var awaiting: Set<String> = []
    var defaultWorkdir = ""
    var bridgeRoot = ""
    var projects: [Project] = []
    /// The project the Board and Sessions show; nil is every project.
    var projectFilter: String? = nil
    /// The Sessions list shows archived chats instead of the live ones.
    var showArchived = false
    var composeProject: String? = nil

    var usage: JSON = .null
    /// Settings: the open section, and whether saved .env edits wait on a server restart.
    var settingsPane = "general"
    /// A search for the Settings page to apply when it shows (⌘K's Settings results); it clears it.
    var settingsQuery = ""
    /// Settings › Customize: "mcp", "skills" or "plugins" (Customize.swift).
    var customizeTab = "mcp"
    /// Snapshot runs only: open the first skill in the editor.
    var snapshotSkillEdit = false
    var envNeedsRestart = false
    var notifyAsks = UserDefaults.standard.object(forKey: "notify.asks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyAsks, forKey: "notify.asks") }
    }
    var notifyOutcomes = UserDefaults.standard.object(forKey: "notify.outcomes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOutcomes, forKey: "notify.outcomes") }
    }
    var notifyMentions = UserDefaults.standard.object(forKey: "notify.mentions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyMentions, forKey: "notify.mentions") }
    }
    var showBadge = UserDefaults.standard.object(forKey: "notify.badge") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showBadge, forKey: "notify.badge"); updateBadge() }
    }
    var agentCatalog: JSON = .null
    var commands: [JSON] = []
    /// The chat page's side-by-side panes (Panes.swift). One pane is today's
    /// single chat; the focused one is the route's session and `chatTab`.
    var panes: [Pane] = [Pane(run: "")]
    var focusedPane = 0
    /// The orchestrator pinned to the right of the chat page (`PinnedDock` in
    /// Panes.swift): its run id, "" once unpinned; its share of the page's
    /// width, and whether it's folded to a strip. All kept across launches.
    var pinnedRun = UserDefaults.standard.string(forKey: "pin.run") ?? "orchestrator" {
        didSet { UserDefaults.standard.set(pinnedRun, forKey: "pin.run") }
    }
    var pinnedShare: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "pin.share")
        return v > 0 ? min(max(CGFloat(v), pinShareRange.lowerBound), pinShareRange.upperBound) : 0.35
    }() {
        didSet { UserDefaults.standard.set(Double(pinnedShare), forKey: "pin.share") }
    }
    var pinnedCollapsed = UserDefaults.standard.bool(forKey: "pin.collapsed") {
        didSet { UserDefaults.standard.set(pinnedCollapsed, forKey: "pin.collapsed") }
    }
    /// A session or tab is being dragged: panes show their drop zones.
    var paneDragActive = false
    /// The pane and edge a drag would land on, for the highlight.
    var dropZone: DropZone? = nil
    /// The focused pane's tab: "chat", "changes", "term" or "web-<id>".
    var chatTab: String {
        get { panes.indices.contains(focusedPane) ? panes[focusedPane].tab : "chat" }
        set { if panes.indices.contains(focusedPane) { panes[focusedPane].tab = newValue } }
    }
    /// Runs with an open Terminal tab; the processes live in `terms`.
    var terminalTabs: Set<String> = []
    @ObservationIgnored let terms = TermStore()
    var slack: JSON = .null
    /// What the server worked out (server/identity.js): GitHub, Slack and Linear
    /// identities, the pipeline repo, and `derived` values for each overridable key.
    var identity: JSON = .null
    func loadIdentity(refresh: Bool = false) async {
        if let out = try? await (refresh ? API.post("/api/identity/refresh") : API.get("/api/identity")) { identity = out }
    }
    var mentions: [Mention] = []
    /// The newest mention shown on the Slack page; persists so a relaunch doesn't relight them.
    var slackSeen = UserDefaults.standard.double(forKey: "slack.seen") {
        didSet { UserDefaults.standard.set(slackSeen, forKey: "slack.seen") }
    }
    /// The server's Slack watcher (server/watch.js): mode, last poll, last error.
    var slackWatch: JSON = .null
    var slackUnread: Int { mentions.filter { $0.ts > slackSeen && $0.user != slack["userId"].string }.count }
    var slackThread: JSON = .null
    var slackSelected = ""
    var sessions: [Session] = []
    var inbox: JSON = .null

    /// The PR and Linear feeds, with their rows decoded and indexed once per
    /// fetch: every card's column, status and links look a PR up by URL and an
    /// issue up by key, many times a render.
    var pulls: JSON = .null {
        didSet {
            openPulls = pulls["mine"].array.map(PullRequest.init)
            reviewPulls = pulls["review"].array.map(PullRequest.init)
            mergedPulls = pulls["merged"].array.map(PullRequest.init)
            var byURL: [String: PullRequest] = [:]
            for p in openPulls + reviewPulls + mergedPulls where byURL[norm(p.url)] == nil { byURL[norm(p.url)] = p }
            pullsByURL = byURL
        }
    }
    var linear: JSON = .null {
        didSet {
            issues = linear["issues"].array.map(Issue.init)
            var byKey: [String: Issue] = [:]
            for i in issues where byKey[i.key] == nil { byKey[i.key] = i }
            issuesByKey = byKey
        }
    }
    private(set) var openPulls: [PullRequest] = []
    private(set) var reviewPulls: [PullRequest] = []
    private(set) var mergedPulls: [PullRequest] = []
    private(set) var issues: [Issue] = []
    @ObservationIgnored private var pullsByURL: [String: PullRequest] = [:]
    @ObservationIgnored private(set) var issuesByKey: [String: Issue] = [:]
    var ports: JSON = .null
    /// Vercel deployments, incident.io incidents, Granola notes, Datadog monitors and errors (Feeds.swift).
    var vercel: JSON = .null
    var incidents: JSON = .null
    var granola: JSON = .null
    var datadog: JSON = .null
    /// Model providers on their own keys: OpenRouter, Anthropic (Feeds.swift `ModelsView`).
    var models: JSON = .null
    /// Sources hidden from the sidebar (Settings › Integrations).
    var hiddenSources = Sources.hidden
    var loading: Set<String> = []
    /// Sources a refresh button asked for; background polls never spin a button.
    var refreshing: Set<String> = []
    var errors: [String: String] = [:]

    var openRun: JSON = .null
    /// Every loaded run by id: the open one and the ones shown in other panes.
    var runs: [String: JSON] = [:]
    func runData(_ id: String) -> JSON { id == openId ? openRun : runs[id] ?? .null }
    /// Loaded task records (report, worktree) by id: the open one and the
    /// ones whose pane shows its details.
    var taskCache: [String: JSON] = [:]
    /// Each on-screen transcript's message navigation, by run (Messages.swift).
    @ObservationIgnored var messageNavs: [String: MessageNav] = [:]
    func taskData(_ id: String) -> JSON { id == openId ? openTask : taskCache[id] ?? .null }

    /// "system", "light" or "dark" (Settings › General › Appearance).
    var appearance = Appearance.current {
        didSet { Appearance.save(appearance) }
    }
    var sidebarHidden = UserDefaults.standard.bool(forKey: "sidebar.hidden") {
        didSet { UserDefaults.standard.set(sidebarHidden, forKey: "sidebar.hidden") }
    }
    var inspectorShown = !UserDefaults.standard.bool(forKey: "inspector.hidden") {
        didSet { UserDefaults.standard.set(!inspectorShown, forKey: "inspector.hidden") }
    }
    /// Width of the details column, dragged from its leading edge (`DetailsResizer`).
    static let detailsRange: ClosedRange<CGFloat> = 260...560
    var detailsWidth: CGFloat = {
        let w = UserDefaults.standard.double(forKey: "details.width")
        return w > 0 ? min(max(CGFloat(w), detailsRange.lowerBound), detailsRange.upperBound) : 312
    }() {
        didSet { UserDefaults.standard.set(Double(detailsWidth), forKey: "details.width") }
    }
    /// GET /api/runs/:id/pr, by PR URL: review state, checks, comments.
    var prActivity: [String: JSON] = [:]

    func toggleSidebar() { withAnimation(M.snappy) { sidebarHidden.toggle() } }

    func navigate(_ r: Route) {
        if r == .sessions || r == .board { showArchived = false }
        if case .session(let id) = r { open(id) } else { route = r == .sessions ? sessionsRoute : r }
    }

    func back() {
        guard let r = backStack.popLast() else { return }
        travelling = true
        forwardStack.append(route)
        if case .session(let id) = r { open(id) } else { route = r }
        travelling = false
    }

    func forward() {
        guard let r = forwardStack.popLast() else { return }
        travelling = true
        backStack.append(route)
        if case .session(let id) = r { open(id) } else { route = r }
        travelling = false
    }

    // MARK: chat order, drafts, browser tabs

    /// A project's chats in three groups, newest first within each: waiting on
    /// you (an ask, or the board's Needs You), then in progress or in review,
    /// then done (PR merged or closed, cleaned up) at the bottom.
    func sidebarSessions(in projectId: String) -> [Session] {
        sessions(in: projectId).filter { !$0.pinned }
            .map { ($0, attentionRank($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.updatedAt > $1.0.updatedAt }
            .map(\.0)
    }

    /// 0 needs you, 1 pending, 2 done. A live ask beats a merged PR.
    func attentionRank(_ s: Session) -> Int {
        if isAwaiting(s) { return 0 }
        switch column(of: s) {
        case .needs: return 0
        case .done: return 2
        default: return 1
        }
    }

    var chatOrder: [String] {
        var ids = boardSessions.filter(\.pinned).sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
        for p in projects {
            let o = orchestratorId(p.id)
            if sessions.contains(where: { $0.id == o }) { ids.append(o) }
            ids += sidebarSessions(in: p.id).map(\.id)
        }
        let seen = Set(ids)
        ids += boardSessions.filter { !seen.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
        return ids
    }

    func stepChat(_ delta: Int) {
        // Stepping chats never lands on the pinned orchestrator: it's already beside them.
        let order = chatOrder.filter { $0 != pinnedRun || route == .session($0) }
        guard !order.isEmpty else { return }
        guard case .session(let id) = route, let i = order.firstIndex(of: id) else { return open(order[0]) }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        open(order[j])
    }

    var drafts: [String: String] = [:]
    var attachments: [String: [Attachment]] = [:]
    /// Messages you queued behind a chat's running turn (server jobs.queueOf).
    var queues: [String: [JSON]] = [:]
    var browserTabs: [String: [BrowserTab]] = [:]
    /// Subagents and background commands open as tabs: task ids by run (Tasks.swift).
    var taskTabs: [String: [String]] = [:]
    @ObservationIgnored let web = WebStore()

    func openBrowser(_ runId: String, url: String) {
        let tab = BrowserTab(url: url)
        withAnimation(M.snappy) {
            browserTabs[runId, default: []].append(tab)
            chatTab = "web-\(tab.id)"
        }
    }

    func closeBrowser(_ runId: String, _ tabId: String) {
        withAnimation(M.snappy) {
            browserTabs[runId]?.removeAll { $0.id == tabId }
            vacate(runId, "web-\(tabId)")
        }
        web.drop(tabId)
    }

    func quoteIntoComposer(_ text: String) {
        guard case .session(let id) = route else { return }
        let quoted = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        guard !quoted.isEmpty else { return }
        let cur = drafts[id] ?? ""
        drafts[id] = (cur.isEmpty ? "" : cur.hasSuffix("\n") ? cur : cur + "\n\n") + quoted + "\n\n"
        showTab("chat", of: id)
        focusComposer += 1
    }

    var focusComposer = 0
    var openTask: JSON = .null
    var openId = ""

    var paletteOpen = false
    /// The New task page is open (setting false leaves it for the previous page).
    var composeOpen: Bool {
        get { route == .compose }
        set {
            if newValue { if route != .compose { route = .compose } }
            else if route == .compose { if backStack.isEmpty { route = .home } else { back() } }
        }
    }
    /// The Import a chat sheet (Import.swift), and the project it imports into.
    var importOpen = false
    var importProject = AppModel.rootId
    /// Whose memory the Memory page shows ("" until first opened: then the
    /// filtered project, the open chat's, else Default's).
    var memoryProject = ""
    func openMemory(_ project: String? = nil) {
        var fromChat: String? = nil
        if case .session(let id) = route { fromChat = sessions.first { $0.id == id }?.project }
        memoryProject = project ?? projectFilter ?? fromChat ?? AppModel.rootId
        navigate(.memory)
    }
    func openImport(into project: String? = nil) {
        importProject = project ?? (route == .compose ? composeProject : nil) ?? projectFilter ?? AppModel.rootId
        importOpen = true
    }
    /// The MCP editor or tools list, floating over the window (Servers.swift).
    var mcpSheet: MCPSheet? = nil
    /// The archive dialog over the window (Archive.swift).
    var archiveAsk: ArchiveAsk? = nil
    var composeText = ""
    /// Whether the New Task sheet was on "Start a worker now" when it closed.
    var composeDirect = false
    var toast: String? = nil
    var toastBad = false

    private let events = EventStream()
    private var refreshPending = false
    private var startedServer = false
    private var lastStartAttempt = Date.distantPast
    var serverError = ""

    // MARK: derived

    var boardSessions: [Session] { sessions.filter { !$0.isOrchestrator && !$0.archived } }
    var archivedSessions: [Session] { sessions.filter { $0.archived }.sorted { $0.archivedAt > $1.archivedAt } }
    var orchestrator: Session? { sessions.first { $0.isOrchestrator } }
    var servers: [DevServer] { ports["servers"].array.map(DevServer.init) }
    var decisions: [JSON] { inbox["decisions"].array }
    var todos: [JSON] { inbox["todos"].array }
    var needsCount: Int { boardSessions.filter { column(of: $0) == .needs }.count + decisions.count }

    var liveCount: Int { boardSessions.filter { isLive($0) }.count }

    func isLive(_ s: Session) -> Bool { running.contains(s.id) || s.action == "running" || s.j["live"].bool }
    func isAwaiting(_ s: Session) -> Bool { awaiting.contains(s.id) || s.j["awaiting"].bool }

    /// A URL without its query or fragment, trailing slashes or case.
    func norm(_ u: String) -> String {
        Memo.string(Memo.urls, u) {
            let cut = u.firstIndex(where: { $0 == "#" || $0 == "?" }).map { String(u[..<$0]) } ?? u
            return cut.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
    }

    func pr(for url: String) -> PullRequest? {
        guard !url.isEmpty else { return nil }
        _ = pulls // observe the feed: the index itself isn't tracked
        return pullsByURL[norm(url)]
    }

    func autoColumn(_ s: Session) -> Column {
        let st = s.taskStatus
        let p = pr(for: s.prUrl)
        if let p, !p.open { return .done }
        if isAwaiting(s) || needsStatuses.contains(st) { return .needs }
        if isLive(s) || st == "working" { return .doing }
        // A linked Linear issue is the source of truth for where the work
        // stands, once nothing live says otherwise (a manual move still wins).
        if let issue = linkedIssue(s) { return Column(linear: issue.status) }
        if st == "cleaned" || st == "stopped" { return .done }
        // Brought in from an agent's own history: nothing has run here yet.
        if st == "imported" && !isLive(s) { return .backlog }
        // A PR missing from the feed is unknown, not closed: the feed holds only
        // your PRs and reviews asked of you, so stay in review until it's seen.
        // Past the feed's 14-day merged window, an unseen PR is taken as landed.
        if !s.prUrl.isEmpty { return Date().timeIntervalSince1970 - s.updatedAt > 14 * 86400 ? .done : .review }
        // "idle": it answered and stopped without code to report.
        if st == "ready-for-review" || st == "pushed-follow-up" || st == "idle" { return .review }
        if ["acted", "skipped", "error"].contains(s.action) { return .done }
        if !s.worked || s.j["messages"].int == 0 { return .backlog }
        return .needs
    }

    func column(of s: Session) -> Column { Column(rawValue: s.boardPin) ?? autoColumn(s) }

    // MARK: projects

    /// Default: the root folder for sessions that aren't in any project. Always first.
    static let rootId = "default"
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }
    func inFilter(_ s: Session) -> Bool { projectFilter == nil || s.project == projectFilter }
    func sessions(in projectId: String) -> [Session] { boardSessions.filter { $0.project == projectId } }
    func orchestratorId(_ projectId: String?) -> String {
        guard let p = projectId, p != AppModel.rootId, !p.isEmpty else { return "orchestrator" }
        return "orchestrator-\(p)"
    }

    func openOrchestrator(_ projectId: String?) {
        let pid = projectId ?? AppModel.rootId
        let id = orchestratorId(pid)
        if sessions.contains(where: { $0.id == id }) || pid.isEmpty { return open(id) }
        Task {
            await act {
                let out = try await API.post("/api/projects/\(API.q(pid))/orchestrator")
                self.open(out["runId"].string)
            }
        }
    }

    func addProject() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Add project"
        p.message = "Choose a git checkout"
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await addProject(path: u.path) }
    }

    @discardableResult
    func addProject(path: String, name: String = "") async -> String? {
        var id: String? = nil
        await act {
            var body: [String: Any] = ["path": path]
            if !name.isEmpty { body["name"] = name }
            let out = try await API.post("/api/projects", body)
            id = out["project"]["id"].string
            self.say("Added \(out["project"]["name"].string)")
        }
        return id
    }

    func updateProject(_ id: String, _ patch: [String: Any]) async { await act { try await API.post("/api/projects/\(API.q(id))", patch) } }
    /// Move a project to `index` in the sidebar; shown at once, then saved.
    /// Default stays first: indexes here count it, the server's don't.
    func moveProject(_ id: String, to index: Int) async {
        let first = projects.first?.root == true ? 1 : 0
        guard let from = projects.firstIndex(where: { $0.id == id }), !projects[from].root, index >= first, index < projects.count, index != from else { return }
        var next = projects
        next.insert(next.remove(at: from), at: index)
        withAnimation(M.snappy) { projects = next }
        await updateProject(id, ["index": index - first])
    }
    func renameProject(_ p: Project) {
        let a = NSAlert()
        a.messageText = "Rename \(p.name)"
        if p.root { a.informativeText = "Default is where sessions that aren't in a project run. Leave the name empty to go back to “Default”." }
        let f = NSTextField(string: p.name)
        f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard p.root || !name.isEmpty else { return }
        Task { await updateProject(p.id, ["name": name]) }
    }

    /// Point Default at another folder (any folder; it needn't be a repo).
    func chooseRootFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Use Folder"
        p.message = "Sessions that aren't in a project run in this folder"
        if let root = projects.first(where: \.root) { p.directoryURL = URL(fileURLWithPath: root.path) }
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await updateProject(AppModel.rootId, ["path": u.path]) }
    }

    func confirmRemoveProject(_ p: Project) {
        let a = NSAlert()
        a.messageText = "Remove \(p.name) from Bridge?"
        a.informativeText = "Its sessions and files stay; it just leaves the sidebar."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { Task { await removeProject(p.id) } }
    }

    func removeProject(_ id: String) async {
        await act { try await API.delete("/api/projects/\(API.q(id))") }
        if projectFilter == id { projectFilter = nil }
    }

    func setProject(_ sessionId: String, _ projectId: String) async {
        if let i = sessions.firstIndex(where: { $0.id == sessionId }) {
            var o = sessions[i].j.object
            o["project"] = .str(projectId)
            withAnimation(M.snappy) { sessions[i] = Session(j: .obj(o)) }
        }
        await act { try await API.post("/api/runs/\(API.q(sessionId))/project", ["project": projectId]) }
    }

    func setPinned(_ id: String, _ on: Bool) async {
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            var o = sessions[i].j.object
            o["pinned"] = .bool(on)
            withAnimation(M.snappy) { sessions[i] = Session(j: .obj(o)) }
        }
        await act { try await API.post("/api/runs/\(API.q(id))/pin", ["pinned": on]) }
    }

    func compose(in projectId: String?) {
        composeProject = projectId
        withAnimation(M.page) { composeOpen = true }
    }

    // MARK: Slack

    /// `quiet` is the background poll: a failure there waits for the next one.
    func loadSlack(quiet: Bool = false) async {
        slack = (try? await API.get("/api/slack/status")) ?? .null
        guard slack["configured"].bool else { return }
        do { mentions = try await API.get("/api/slack/mentions")["mentions"].array.map(Mention.init) } catch {
            if !quiet { say(error.localizedDescription, bad: true) }
            return
        }
        if let w = try? await API.get("/api/slack/watch") { slackWatch = w["status"] }
        let newest = mentions.map(\.ts).max() ?? 0
        if slackSeen == 0 || (route == .slack && NSApp.isActive) { slackSeen = max(slackSeen, newest) }
    }

    /// What the watcher found this poll: new Inbox items, and replies filed into chats.
    private func slackFound(_ d: JSON) {
        slackWatch = d["status"]
        let fresh = d["fresh"].array, replies = d["followups"].array
        if !fresh.isEmpty { Task { await loadSlack(quiet: true) } }
        guard notifyMentions else { return }
        if let m = fresh.first, !(NSApp.isActive && (route == .slack || route == .inbox)) {
            let title = fresh.count == 1 ? "\(m["who"].string) in \(m["channel"].nonEmpty ?? "Slack")" : "\(fresh.count) new on Slack"
            let body = fresh.count == 1 ? Session.plain(m["text"].string) : fresh.prefix(3).map { "\($0["who"].string): \(Session.plain($0["text"].string))" }.joined(separator: "\n")
            notify(title: title, body: body, runId: "", slack: m["permalink"].string)
        }
        for r in replies.prefix(3) {
            notify(title: "\(r["who"].string) replied in Slack", body: "\(r["title"].string)\n\(Session.plain(r["text"].string))", runId: r["runId"].string)
        }
    }

    var slackItems: [JSON] { inbox["slack"].array }
    /// The Inbox page's tab: decisions, slack, todos, tasks or activity.
    var inboxTab = "decisions"
    var slackOpenCount: Int { inbox["counts"]["slack"].int }

    func slackItem(_ id: String, _ action: String, _ extra: [String: Any] = [:]) async {
        await act {
            let out = try await API.post("/api/slack/watch/\(API.q(id))", extra.merging(["action": action]) { a, _ in a })
            if action == "start", let run = out["runId"].nonEmpty {
                self.say("Started the pipeline")
                self.open(run)
            }
        }
    }

    func slackCheckNow() async {
        await act {
            let out = try await API.post("/api/slack/watch/poll")
            self.slackWatch = out["status"]
            if let e = out["error"].nonEmpty { self.say(e, bad: true) } else { self.say(out["fresh"].int + out["followups"].int > 0 ? "Found \(out["fresh"].int) new, \(out["followups"].int) in chats" : "Nothing new on Slack") }
        }
    }

    func openThread(_ permalink: String) {
        slackSelected = permalink
        slackThread = .null
        route = .slack
        Task {
            do { slackThread = try await API.get("/api/slack/thread?url=\(API.q(permalink))") } catch { say(error.localizedDescription, bad: true) }
        }
    }

    func replyInThread(_ text: String) async -> Bool {
        var ok = false
        let link = slackSelected
        await act {
            try await API.post("/api/slack/reply", ["url": link, "text": text])
            ok = true
            self.say("Replied in the thread")
            self.slackThread = try await API.get("/api/slack/thread?url=\(API.q(link))")
        }
        return ok
    }

    func session(forPermalink link: String) -> Session? {
        var ts = ""
        if let r = link.range(of: #"thread_ts=\d+\.\d+"#, options: .regularExpression) {
            ts = String(link[r].dropFirst(10))
        } else if let r = link.range(of: #"/p\d{16}"#, options: .regularExpression) {
            let d = String(link[r].dropFirst(2))
            ts = d.prefix(10) + "." + d.suffix(6)
        }
        return ts.isEmpty ? nil : sessions.first { $0.id == ts }
    }

    func runPipeline(_ permalink: String, project: String? = nil) async {
        await act {
            var body: [String: Any] = ["url": permalink, "start": true]
            if let project { body["project"] = project }
            let out = try await API.post("/api/runs", body)
            self.open(out["runId"].string)
        }
    }

    // MARK: environment + self-development

    func saveEnv(_ values: [String: String], restart: Bool) async -> Bool {
        var ok = false
        await act {
            try await API.post("/api/env", ["values": values])
            if restart {
                try? await API.post("/api/restart")
                self.envNeedsRestart = false
                self.say("Saved. The server is restarting")
            } else {
                self.envNeedsRestart = true
                self.say("Saved to .env. Restart the server to apply it")
            }
            ok = true
        }
        return ok
    }

    func restartServer() async {
        _ = try? await API.post("/api/restart")
        envNeedsRestart = false
        say("The server is restarting")
    }

    var building = false

    /// Rebuild Bridge.app from its own source, then swap it in and relaunch.
    func rebuildApp() {
        guard !bridgeRoot.isEmpty, !building else { return }
        building = true
        let root = bridgeRoot
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "cd \"$BRIDGE_ROOT\" && ./scripts/build.sh 2>&1"]
            p.environment = ProcessInfo.processInfo.environment.merging(["BRIDGE_ROOT": root]) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            await MainActor.run {
                self.building = false
                guard ok else {
                    let a = NSAlert()
                    a.messageText = "The build failed"
                    a.informativeText = out.split(separator: "\n").suffix(12).joined(separator: "\n")
                    a.alertStyle = .warning
                    a.runModal()
                    return
                }
                let swap = Process()
                swap.executableURL = URL(fileURLWithPath: "/bin/sh")
                swap.arguments = ["-c", "sleep 1; rm -rf \"$HOME/Applications/Bridge.app\" && mkdir -p \"$HOME/Applications\" && cp -R \"$BRIDGE_ROOT/dist/Bridge.app\" \"$HOME/Applications/\" && open \"$HOME/Applications/Bridge.app\""]
                swap.environment = ProcessInfo.processInfo.environment.merging(["BRIDGE_ROOT": root]) { $1 }
                try? swap.run()
                NSApp.terminate(nil)
            }
        }
    }


    func session(forPR p: PullRequest) -> Session? {
        let n = norm(p.url)
        return boardSessions.first { !$0.prUrl.isEmpty && norm($0.prUrl) == n } ?? boardSessions.first { !$0.branch.isEmpty && $0.branch == p.branch }
    }

    func session(forIssue key: String) -> Session? { boardSessions.first { $0.issueKey == key } }

    func pulls(forIssue key: String) -> [PullRequest] { (openPulls + mergedPulls).filter { $0.issueKey == key } }

    func servers(for s: Session) -> [DevServer] {
        let dir = s.task["worktree"].nonEmpty ?? (s.j["workdir"].string != defaultWorkdir ? s.j["workdir"].string : "")
        guard !dir.isEmpty else { return [] }
        return servers.filter { $0.cwd == dir || $0.cwd.hasPrefix(dir + "/") }
    }

    func servers(forBranch branch: String) -> [DevServer] {
        guard !branch.isEmpty else { return [] }
        let tail = branch.split(separator: "/").last.map(String.init) ?? branch
        let flat = branch.replacingOccurrences(of: "/", with: "-")
        return servers.filter { $0.cwd.contains("/" + flat) || $0.cwd.contains("/" + tail + "/") || $0.cwd.hasSuffix("/" + tail) }
    }

    /// Pids being stopped right now (their stop buttons spin).
    var stoppingServers: Set<Int> = []

    /// Stop a dev server (SIGTERM, then SIGKILL on the server) and refresh the list. Asks first.
    func stopServer(_ sv: DevServer) async {
        guard !stoppingServers.contains(sv.id) else { return }
        let label = sv.ports.first.map { ":\($0)" } ?? sv.command
        let a = NSAlert()
        a.messageText = "Stop the dev server on \(sv.ports.map { ":\($0)" }.joined(separator: ", "))?"
        a.informativeText = "\(sv.command) (pid \(sv.id)) in \(sv.folder) gets SIGTERM, then SIGKILL if it's still running after 4 seconds."
        a.addButton(withTitle: "Stop Server")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        stoppingServers.insert(sv.id)
        defer { stoppingServers.remove(sv.id) }
        do {
            try await API.post("/api/servers/\(sv.id)/stop")
            say("Stopped \(label)")
        } catch {
            say("Couldn't stop \(label): \(error.localizedDescription)", bad: true)
        }
        await load("ports")
    }

    // MARK: lifecycle

    func boot() {
        requestNotifications()
        events.start({ [weak self] name, data in self?.handle(name, data) }, onConnect: { [weak self] up in
            guard let self else { return }
            self.connected = up
            if up {
                self.everConnected = true
                self.startedServer = false
                self.serverError = ""
                Task { await self.loadAll() }
            } else if !self.startedServer && Date().timeIntervalSince(self.lastStartAttempt) > 15 {
                self.startedServer = true
                self.lastStartAttempt = Date()
                self.startServer()
            }
        })
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await loadSources(refresh: false)
            }
        }
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await load("ports")
            }
        }
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 150_000_000_000)
                await loadUsage()
            }
        }
    }

    /// Same path as `npm start`: launchd owns the server, so it outlives the app.
    private func startServer() {
        guard !API.root.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "cd \"$BRIDGE_ROOT\" && ./scripts/install.sh start"]
        p.environment = ProcessInfo.processInfo.environment.merging(["BRIDGE_ROOT": API.root]) { $1 }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // A failed start allows another attempt (after a pause) instead of
        // leaving the app on "Starting Bridge…" for good.
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                if status != 0 {
                    self.startedServer = false
                    self.serverError = "npm start failed (exit \(status)). See \(API.root)/logs/dashboard.err.log"
                }
            }
        }
        do { try p.run() } catch {
            startedServer = false
            serverError = "Couldn't run npm start: \(error.localizedDescription)"
        }
    }

    func loadAll() async {
        if let s = try? await API.get("/api/state") { applyState(s) }
        Task { await loadSlack() }
        Task { await loadUsage() }
        Task { if let c = try? await API.get("/api/agents") { agentCatalog = c } }
        if let r = try? await API.get("/api/runs") { sessions = r["runs"].array.map(Session.init) }
        if let i = try? await API.get("/api/inbox") { inbox = i }
        await loadSources(refresh: false)
        if !openId.isEmpty { await refreshOpen() }
        await refreshPanes(all: true)
        updateBadge()
    }

    func loadSources(refresh: Bool) async {
        async let a: Void = load("pulls", refresh: refresh)
        async let b: Void = load("linear", refresh: refresh)
        async let c: Void = load("ports")
        async let d: Void = sourceShown(.vercel) ? load("vercel", refresh: refresh) : ()
        async let e: Void = sourceShown(.incidents) ? load("incidents", refresh: refresh) : ()
        async let f: Void = sourceShown(.granola) ? load("granola", refresh: refresh) : ()
        async let g: Void = sourceShown(.datadog) ? load("datadog", refresh: refresh) : ()
        async let h: Void = sourceShown(.models) ? load("models", refresh: refresh) : ()
        _ = await (a, b, c, d, e, f, g, h)
    }

    func load(_ name: String, refresh: Bool = false) async {
        if loading.contains(name) { return }
        loading.insert(name)
        if refresh { refreshing.insert(name) }
        defer { loading.remove(name); refreshing.remove(name) }
        do {
            let out = try await API.get("/api/sources/\(name)\(refresh ? "?refresh=1" : "")")
            switch name {
            case "pulls": pulls = out
            case "linear": linear = out
            case "vercel": vercel = out
            case "incidents": incidents = out
            case "granola": granola = out
            case "datadog": datadog = out
            case "models": models = out
            default: ports = out
            }
            errors[name] = out["stale"].nonEmpty
        } catch {
            errors[name] = error.localizedDescription
        }
    }

    private func applyState(_ s: JSON) {
        config = s["config"]
        running = Set(s["jobs"]["running"].array.map(\.string))
        awaiting = Set(s["jobs"]["awaiting"].array.map(\.string))
        defaultWorkdir = s["meta"]["workdir"].string
        bridgeRoot = s["meta"]["root"].string
        projects = s["meta"]["projects"].array.map(Project.init)
    }

    private func handle(_ name: String, _ d: JSON) {
        switch name {
        case "state": applyState(d)
        case "runs":
            // Animate only when rows come, go or change place; animating every
            // in-place update cross-fades the whole window while sessions stream.
            let next = d["runs"].array.map(Session.init)
            guard next != sessions else { break }
            let place = { (l: [Session]) in l.map { "\($0.id)|\(self.column(of: $0).rawValue)|\($0.pinned)|\($0.project)" } }
            if place(next) == place(sessions) { sessions = next } else { withAnimation(M.snappy) { sessions = next } }
        case "jobs":
            let r = Set(d["running"].array.map(\.string)), a = Set(d["awaiting"].array.map(\.string))
            if r != running || a != awaiting { withAnimation(M.snappy) { running = r; awaiting = a } }
        case "inbox": withAnimation(M.snappy) { inbox = d }
        case "slack": slackFound(d)
        case "projects": projects = d["projects"].array.map(Project.init)
        case "mcp": MCPStore.shared.changed(d["agent"].string, live: paneRuns.union([openId]))
        case "identity": identity = d
        case "queue": withAnimation(M.snappy) { queues[d["runId"].string] = d["queue"].array }
        case "delta":
            // Tokens stream at dozens a second: patched into the chat held
            // here, never a re-fetch, and no badge recount.
            onDelta(d)
            return
        case "message":
            let id = d["runId"].string
            if id == openId || paneRuns.contains(id) {
                appendLocally(id, d["message"])
                scheduleRefresh(id, task: true)
            }
        case "run-updated":
            let id = d["runId"].string
            if id == openId || paneRuns.contains(id) { scheduleRefresh(id, task: true) }
        case "ask" where notifyAsks:
            notify(title: "\(d["who"].nonEmpty ?? "A session") needs you", body: d["summary"].nonEmpty ?? "Claude is waiting on your answer", runId: d["runId"].string)
        case "outcome":
            let st = d["status"].string
            if notifyOutcomes, ["needs-input", "blocked", "ready-for-review", "worker-gone", "usage-limit", "worker-stalled"].contains(st) || d["name"].string != "report" {
                notify(title: d["title"].nonEmpty ?? d["taskId"].string, body: statusLabels[st] ?? d["name"].string.replacingOccurrences(of: "-", with: " "), runId: d["taskId"].string)
            }
            if d["taskId"].string == openId { Task { await refreshOpen() } }
        default: break
        }
        // Only these change what the badge counts.
        if ["state", "runs", "jobs", "inbox"].contains(name) { updateBadge() }
    }

    // MARK: streaming

    /// Deltas received per run since its last snapshot, for replay over a
    /// snapshot fetched mid-stream (one taken before them doesn't hold them).
    @ObservationIgnored private var deltaLog: [String: [JSON]] = [:]
    /// Runs to re-fetch on the next refresh, and whether their task too.
    @ObservationIgnored private var staleRuns: [String: Bool] = [:]

    private func onDelta(_ d: JSON) {
        let id = d["runId"].string
        guard id == openId || paneRuns.contains(id) else { return }
        var log = deltaLog[id] ?? []
        log.append(d)
        if log.count > 6000 { log.removeFirst(log.count - 6000) }
        deltaLog[id] = log
        let cur = runData(id)
        // Not loaded yet: the fetch in flight answers with it, replayed.
        guard !cur.isNull else { return }
        if let next = Delta.apply(d, to: cur) { setRun(id, next) } else { scheduleRefresh(id, task: false) }
    }

    /// A message the server just added (yours, or the reply starting): shown
    /// now rather than after the re-fetch it also triggers.
    private func appendLocally(_ id: String, _ msg: JSON) {
        let cur = runData(id)
        guard case .obj(var r) = cur, !msg["id"].string.isEmpty else { return }
        var msgs = r["messages"]?.array ?? []
        guard !msgs.contains(where: { $0["id"].string == msg["id"].string }) else { return }
        msgs.append(msg)
        r["messages"] = .arr(msgs)
        setRun(id, .obj(r))
    }

    private func setRun(_ id: String, _ run: JSON) {
        if id == openId { openRun = run }
        runs[id] = run
    }

    /// A fetched run (`{run, seq}`), with the deltas that came after it replayed.
    private func adopt(_ id: String, _ r: JSON) {
        var run = r["run"]
        let seq = r["seq"].int
        if var log = deltaLog[id] {
            log.removeAll { $0["seq"].int <= seq }
            for d in log { if let next = Delta.apply(d, to: run) { run = next } }
            deltaLog[id] = log.isEmpty ? nil : log
        }
        setRun(id, run)
        queues[id] = r["queue"].array
        runOrder.removeAll { $0 == id }
        runOrder.append(id)
        trimRunCache()
    }

    /// Chats opened earlier stay cached so switching back is instant; the
    /// oldest beyond a few dozen go (never one on screen).
    private func trimRunCache() {
        guard runs.count > 40 else { return }
        let keep = paneRuns.union([openId])
        for k in runOrder where !keep.contains(k) && runs.count > 30 {
            runs[k] = nil
            deltaLog[k] = nil
            taskCache[k] = nil
        }
        runOrder.removeAll { runs[$0] == nil }
    }
    @ObservationIgnored private var runOrder: [String] = []

    private func scheduleRefresh(_ id: String, task: Bool) {
        staleRuns[id] = (staleRuns[id] ?? false) || task
        guard !refreshPending else { return }
        refreshPending = true
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            refreshPending = false
            let ids = staleRuns
            staleRuns = [:]
            if let task = ids[openId] { await refreshOpen(task: task) }
            for id in ids.keys where id != openId && paneRuns.contains(id) { await fetchRun(id) }
        }
    }

    func fetchRun(_ id: String) async {
        if let r = try? await API.get("/api/runs/\(API.q(id))") { adopt(id, r) }
    }

    /// Hovering a chat in the sidebar loads it, so the click opens it already
    /// drawn (the cache is refreshed again on open).
    func prefetch(_ id: String) {
        guard !id.isEmpty, id != openId, runs[id] == nil, !prefetching.contains(id) else { return }
        prefetching.insert(id)
        Task {
            await fetchRun(id)
            prefetching.remove(id)
        }
    }
    @ObservationIgnored private var prefetching: Set<String> = []

    // MARK: sessions

    func open(_ id: String) {
        // The pinned orchestrator stays on the right: opening it from a chat
        // page unfolds it there rather than taking over the focused pane.
        if !travelling, id == pinnedRun, dockShown {
            if pinnedCollapsed { withAnimation(M.snappy) { pinnedCollapsed = false } }
            return
        }
        placeInPanes(id)
        route = .session(id)
        guard openId != id else { return }
        openId = id
        openRun = runs[id] ?? .null
        openTask = taskCache[id] ?? .null
        Task {
            await refreshOpen()
            try? await API.post("/api/runs/\(API.q(id))/seen")
        }
    }

    /// Every result is checked against the chat that asked for it: switching
    /// chats mid-request must never show one chat's run or report in another.
    func refreshOpen(task: Bool = true) async {
        let id = openId
        guard !id.isEmpty, let r = try? await API.get("/api/runs/\(API.q(id))"), id == openId else { return }
        adopt(id, r)
        await refreshPanes()
        guard task else { return }
        let kind = r["run"]["kind"].string
        guard kind == "task" || kind == "slack" || kind.isEmpty else { return }
        let task = (try? await API.get("/api/tasks/\(API.q(id))")) ?? .null
        if id == openId { openTask = task; taskCache[id] = task }
    }

    @discardableResult
    func send(_ text: String, to id: String, mode: SendMode = .steer) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let orchestrator = sessions.first(where: { $0.id == id })?.isOrchestrator == true
        if t == "/clear", orchestrator { return await clearChat(id) }
        let words = t.split(separator: " ")
        if orchestrator, words.first == "/brief", words.count <= 2 {
            let since = words.count == 2 ? String(words[1]) : "8h"
            if since.range(of: #"^\d{1,3}[mhd]$"#, options: .regularExpression) != nil { await brief(id, since: since); return true }
        }
        let live = sessions.first { $0.id == id }.map(isLive) ?? false
        var ok = false
        await act {
            // Idle: every mode is a plain send (queued if a turn starts first).
            let m = live ? mode.rawValue : "queue"
            let out = try await API.post("/api/runs/\(API.q(id))/followup", ["text": t, "mode": m])
            ok = true
            if live, mode == .steer, out["queued"].bool { self.say("Queued: this agent can't take a message mid-turn") }
        }
        await refreshOpen()
        return ok
    }

    func answer(run: String, askId: String, behavior: String, message: String = "", answers: [String: String]? = nil) async {
        var body: [String: Any] = ["askId": askId, "behavior": behavior, "message": message]
        if let answers { body["answers"] = answers }
        await act { try await API.post("/api/runs/\(API.q(run))/answer", body) }
        await refreshOpen()
    }

    func setOpts(_ id: String, _ patch: [String: Any]) async {
        await act { try await API.post("/api/runs/\(API.q(id))/opts", ["opts": patch]) }
        await refreshOpen()
    }

    func move(_ id: String, to column: Column?) async {
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            var o = sessions[i].j.object
            o["board"] = .str(column?.rawValue ?? "")
            withAnimation(M.snappy) { sessions[i] = Session(j: .obj(o)) }
        }
        await act { try await API.post("/api/runs/\(API.q(id))/board", ["column": column?.rawValue ?? ""]) }
    }

    func stop(_ id: String) async { await act { try await API.post("/api/runs/\(API.q(id))/stop") } }
    func start(_ id: String) async { await act { try await API.post("/api/runs/\(API.q(id))/start") } }
    func relaunch(_ id: String) async { await act { try await API.post("/api/tasks/\(API.q(id))/relaunch") } }
    func cleanup(_ id: String, force: Bool = false) async {
        await act { try await API.post("/api/tasks/\(API.q(id))/cleanup", ["force": force]) }
        await refreshOpen()
    }

    /// Every Archive goes through the dialog: it asks the server what the
    /// chat's worktree holds, then offers to delete it along with archiving.
    func confirmArchive(_ id: String) {
        archiveAsk = ArchiveAsk(id: id, title: sessions.first { $0.id == id }?.title ?? "Session")
        Task {
            let w = (try? await API.get("/api/runs/\(API.q(id))/archive"))?["worktree"] ?? JSON.null
            guard archiveAsk?.id == id else { return }
            archiveAsk?.fill(w)
        }
    }

    /// Archive a chat (its open questions and to-dos are dismissed; the chat
    /// is kept), optionally deleting the worktree Bridge made for it, or bring
    /// it back. Use `confirmArchive` to archive from the UI.
    func setArchived(_ id: String, _ on: Bool, deleteWorktree: Bool = false, force: Bool = false) async {
        let title = sessions.first { $0.id == id }?.title ?? "Session"
        await act {
            let out = try await API.post("/api/runs/\(API.q(id))/archive", ["archived": on, "deleteWorktree": deleteWorktree, "force": force])
            if let i = self.sessions.firstIndex(where: { $0.id == id }) {
                var o = self.sessions[i].j.object
                o["archived"] = .bool(on)
                o["archivedAt"] = .num(on ? Date().timeIntervalSince1970 : 0)
                withAnimation(M.snappy) { self.sessions[i] = Session(j: .obj(o)) }
            }
            if on {
                // Off the archived chat only; the board stays the board.
                if case .session(let r) = self.route, r == id { self.navigate(.sessions) }
                if self.openId == id { self.openId = "" }
                self.forgetPanes(of: id)
                let gone = out["worktree"]["removed"].bool ? " and deleted its worktree" : ""
                self.say("Archived \u{201C}\(title.count > 40 ? String(title.prefix(39)) + "…" : title)\u{201D}\(gone). Find it under Sessions › Archived")
            } else {
                self.say("Unarchived \u{201C}\(title.count > 40 ? String(title.prefix(39)) + "…" : title)\u{201D}")
            }
        }
    }

    /// The server gathers the catch-up and hands it to the orchestrator in one turn.
    func brief(_ orchestrator: String = "orchestrator", since: String = "8h") async {
        await act {
            let out = try await API.post("/api/brief", ["since": since, "orchestrator": orchestrator])
            self.open(out["runId"].nonEmpty ?? orchestrator)
            if out["queued"].bool { self.say("Queued: the orchestrator briefs you when its current turn ends") }
            await self.refreshOpen()
        }
    }

    /// Start an orchestrator over: its transcript and agent session go, the
    /// chat stays. Asks first; there's no undo. A Terminal tab resuming the
    /// old session closes with it.
    @discardableResult
    func clearChat(_ id: String) async -> Bool {
        let a = NSAlert()
        a.messageText = "Clear the orchestrator's chat?"
        a.informativeText = "Every message goes and its next turn starts a fresh session. Workers and their tasks aren't touched."
        a.addButton(withTitle: "Clear Chat")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        var ok = false
        await act {
            try await API.post("/api/runs/\(API.q(id))/clear")
            ok = true
            if self.terminalTabs.contains(id) { self.closeTerminalTab(id) }
            self.say("Cleared the orchestrator's chat")
        }
        await refreshOpen()
        return ok
    }

    // MARK: creating work

    /// The one box work starts from: a Slack thread link opens a chat and runs
    /// the pipeline; anything else becomes a task, written up either by the
    /// orchestrator or handed straight to a worker.
    func create(_ text: String, direct: Bool, project: String?) async -> Bool {
        let repo = project.flatMap { self.project($0)?.path } ?? ""
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        var ok = false
        await act {
            if t.range(of: #"^https://[^/]*slack\.com/archives/"#, options: .regularExpression) != nil {
                var body: [String: Any] = ["url": t, "start": true]
                if let project { body["project"] = project }
                let out = try await API.post("/api/runs", body)
                self.open(out["runId"].string)
            } else if direct {
                var body: [String: Any] = ["brief": t]
                if !repo.isEmpty { body["repo"] = repo }
                let out = try await API.post("/api/tasks", body)
                self.say("Worker started on \(out["branch"].string)")
                self.open(out["taskId"].string)
            } else {
                var orch = self.orchestratorId(project)
                if !self.sessions.contains(where: { $0.id == orch }), let pid = project {
                    orch = try await API.post("/api/projects/\(API.q(pid))/orchestrator")["runId"].string
                }
                try await API.post("/api/runs/\(API.q(orch))/followup", ["text": t, "queue": true])
                self.open(orch)
            }
            ok = true
        }
        return ok
    }

    func askOrchestrator(_ text: String) async {
        await act {
            try await API.post("/api/runs/orchestrator/followup", ["text": text, "queue": true])
            self.say("Sent to the orchestrator")
        }
    }

    func startIssue(_ issue: Issue, branch: String? = nil, agent: AgentKind? = nil) async {
        let brief = [
            "Linear issue \(issue.key): \(issue.title)", issue.url, "",
            issue.description.isEmpty ? "(no description)" : issue.description, "",
            "Read the issue and its comments through the Linear connector before starting. Build it, verify it, and open a PR that references the issue key.",
        ].joined(separator: "\n")
        var body: [String: Any] = ["title": "\(issue.key) \(issue.title)", "brief": brief]
        let br = branch ?? issue.branch
        if !br.isEmpty { body["branch"] = br }
        if let agent, agent != .claude { body["opts"] = ["agent": agent.rawValue] }
        do {
            let out = try await API.post("/api/tasks", body)
            say("Worker started on \(out["branch"].string)")
            open(out["taskId"].string)
        } catch {
            // Linear's branch already exists here: let the server name one.
            if error.localizedDescription.contains("already exists"), branch == nil, !issue.branch.isEmpty {
                await startIssue(issue, branch: "", agent: agent)
            } else {
                say(error.localizedDescription, bad: true)
            }
        }
    }

    // MARK: inbox + settings

    func decide(_ id: String, action: String, answer: String = "") async {
        await act { try await API.post("/api/decisions/\(API.q(id))", ["action": action, "answer": answer]) }
    }

    func todoDone(_ key: String) async { await act { try await API.post("/api/todos/done", ["key": key]) } }

    func setMode(_ mode: String) async { await act { try await API.post("/api/mode", ["mode": mode]) } }

    func saveConfig(_ patch: [String: Any]) async {
        await act {
            try await API.post("/api/config", patch)
            if let s = try? await API.get("/api/state") { self.applyState(s) }
        }
    }

    // MARK: feedback

    func act(_ work: @escaping () async throws -> Void) async {
        do { try await work() } catch { say(error.localizedDescription, bad: true) }
    }

    func say(_ text: String, bad: Bool = false) {
        toast = text
        toastBad = bad
        Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if toast == text { toast = nil }
        }
    }

    // MARK: notifications + badge

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    private func requestNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// `slack` is a mention's permalink: clicking opens that thread instead of a chat.
    private func notify(title: String, body: String, runId: String, slack: String = "") {
        guard canNotify else { return }
        if NSApp.isActive, !runId.isEmpty, openId == runId { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = ["runId": runId, "slack": slack]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: slack.isEmpty ? "ask-\(runId)" : "slack-\(slack)", content: c, trigger: nil))
    }

    @ObservationIgnored private var badgeShown: Int? = nil

    func updateBadge() {
        let n = showBadge ? needsCount : 0
        guard n != badgeShown else { return }
        badgeShown = n
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}
