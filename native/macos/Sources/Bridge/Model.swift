import Foundation
import Observation
import SwiftUI
import UserNotifications

// MARK: - Typed views over the payloads

struct Session: Identifiable, Hashable {
    let j: JSON
    var id: String { j["runId"].string }
    var kind: String { j["kind"].nonEmpty ?? "slack" }
    var isTask: Bool { kind == "task" }
    var isOrchestrator: Bool { kind == "orchestrator" || id == "orchestrator" || id.hasPrefix("orchestrator-") }
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
    var project: String { j["project"].string }
    var cost: Double { j["cost"].double }
    var updatedAt: Double { j["updatedAt"].double > 0 ? j["updatedAt"].double : j["createdAt"].double }
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
        return Session.plain(s)
    }

    /// The Linear key this session is about: its ticket link, branch or title.
    var issueKey: String {
        let hay = [linearUrl, branch.uppercased(), title, text].joined(separator: " ")
        if let r = hay.range(of: #"/issue/[A-Za-z][A-Za-z0-9]{1,9}-\d+"#, options: .regularExpression) {
            return String(hay[r].dropFirst(7)).uppercased()
        }
        if let r = hay.range(of: #"\b[A-Z][A-Z0-9]{1,9}-\d+\b"#, options: .regularExpression) { return String(hay[r]) }
        return ""
    }

    /// Slack mrkdwn to plain text: `<url|label>` to label, `<@U123>` dropped.
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<([^|>]+)\|([^>]+)>"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[@#!][^>]+>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

struct Project: Identifiable, Hashable {
    let j: JSON
    var id: String { j["id"].string }
    var name: String { j["name"].nonEmpty ?? id }
    var path: String { j["path"].string }
}

struct Mention: Identifiable, Hashable {
    let j: JSON
    var id: String { j["ts"].string + j["channelId"].string }
    var who: String { j["who"].string }
    var avatar: String { j["avatar"].string }
    var channel: String { j["channel"].string }
    var text: String { j["text"].string }
    var permalink: String { j["permalink"].string }
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
    "queued": "Queued", "working": "Working", "cleaned": "Cleaned up", "stopped": "Stopped",
]

// MARK: - Routes

enum Route: Hashable {
    case home, inbox, slack, board, sessions, pulls, linear, memory, usage
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
        case .memory: return "Memory"
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
            if !travelling {
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
    var cost: JSON = .null
    var running: Set<String> = []
    var awaiting: Set<String> = []
    var defaultWorkdir = ""
    var bridgeRoot = ""
    var projects: [Project] = []
    /// The project the Board and Sessions show; nil is every project.
    var projectFilter: String? = nil
    var composeProject: String? = nil

    var usage: JSON = .null
    var agentCatalog: JSON = .null
    var commands: [JSON] = []
    /// The chat page's side-by-side panes (Panes.swift). One pane is today's
    /// single chat; the focused one is the route's session and `chatTab`.
    var panes: [Pane] = [Pane(run: "")]
    var focusedPane = 0
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
    var mentions: [Mention] = []
    var slackThread: JSON = .null
    var slackSelected = ""
    var sessions: [Session] = []
    var inbox: JSON = .null

    var pulls: JSON = .null
    var linear: JSON = .null
    var ports: JSON = .null
    var loading: Set<String> = []
    var errors: [String: String] = [:]

    var openRun: JSON = .null
    /// Every loaded run by id: the open one and the ones shown in other panes.
    var runs: [String: JSON] = [:]
    func runData(_ id: String) -> JSON { id == openId ? openRun : runs[id] ?? .null }
    @ObservationIgnored private var taskCache: [String: JSON] = [:]

    var sidebarHidden = UserDefaults.standard.bool(forKey: "sidebar.hidden") {
        didSet { UserDefaults.standard.set(sidebarHidden, forKey: "sidebar.hidden") }
    }
    var inspectorShown = !UserDefaults.standard.bool(forKey: "inspector.hidden") {
        didSet { UserDefaults.standard.set(!inspectorShown, forKey: "inspector.hidden") }
    }
    /// With panes side by side the details dock under the focused pane as a
    /// drawer; this is whether that drawer is open or folded to its strip.
    var drawerOpen = !UserDefaults.standard.bool(forKey: "drawer.closed") {
        didSet { UserDefaults.standard.set(!drawerOpen, forKey: "drawer.closed") }
    }
    /// GET /api/runs/:id/pr, by PR URL: review state, checks, comments.
    var prActivity: [String: JSON] = [:]

    func toggleSidebar() { withAnimation(M.snappy) { sidebarHidden.toggle() } }

    func navigate(_ r: Route) {
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

    func sidebarSessions(in projectId: String) -> [Session] {
        sessions(in: projectId).filter { !$0.pinned && column(of: $0) != .done }.sorted { $0.updatedAt > $1.updatedAt }
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
        let order = chatOrder
        guard !order.isEmpty else { return }
        guard case .session(let id) = route, let i = order.firstIndex(of: id) else { return open(order[0]) }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        open(order[j])
    }

    var drafts: [String: String] = [:]
    var attachments: [String: [Attachment]] = [:]
    var browserTabs: [String: [BrowserTab]] = [:]
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
    var composeOpen = false
    var composeText = ""
    var toast: String? = nil
    var toastBad = false

    private let events = EventStream()
    private var refreshPending = false
    private var startedServer = false
    private var lastStartAttempt = Date.distantPast
    var serverError = ""

    // MARK: derived

    var boardSessions: [Session] { sessions.filter { !$0.isOrchestrator } }
    var orchestrator: Session? { sessions.first { $0.isOrchestrator } }
    var openPulls: [PullRequest] { pulls["mine"].array.map(PullRequest.init) }
    var reviewPulls: [PullRequest] { pulls["review"].array.map(PullRequest.init) }
    var mergedPulls: [PullRequest] { pulls["merged"].array.map(PullRequest.init) }
    var issues: [Issue] { linear["issues"].array.map(Issue.init) }
    var servers: [DevServer] { ports["servers"].array.map(DevServer.init) }
    var decisions: [JSON] { inbox["decisions"].array }
    var todos: [JSON] { inbox["todos"].array }
    var needsCount: Int { boardSessions.filter { column(of: $0) == .needs }.count + decisions.count }

    var liveCount: Int { boardSessions.filter { isLive($0) }.count }

    func isLive(_ s: Session) -> Bool { running.contains(s.id) || s.action == "running" || s.j["live"].bool }
    func isAwaiting(_ s: Session) -> Bool { awaiting.contains(s.id) || s.j["awaiting"].bool }

    private func norm(_ u: String) -> String {
        u.replacingOccurrences(of: #"[#?].*$"#, with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    func pr(for url: String) -> PullRequest? {
        guard !url.isEmpty else { return nil }
        let n = norm(url)
        return (openPulls + reviewPulls + mergedPulls).first { norm($0.url) == n }
    }

    func autoColumn(_ s: Session) -> Column {
        let st = s.taskStatus
        let p = pr(for: s.prUrl)
        if let p, !p.open { return .done }
        if isAwaiting(s) || needsStatuses.contains(st) { return .needs }
        if isLive(s) || st == "working" || st == "queued" { return .doing }
        // A linked Linear issue is the source of truth for where the work
        // stands, once nothing live says otherwise (a manual move still wins).
        if let issue = linkedIssue(s) { return Column(linear: issue.status) }
        if st == "cleaned" || st == "stopped" { return .done }
        // A PR missing from the feed is unknown, not closed: the feed holds only
        // your PRs and reviews asked of you, so stay in review until it's seen.
        // Past the feed's 14-day merged window, an unseen PR is taken as landed.
        if !s.prUrl.isEmpty { return Date().timeIntervalSince1970 - s.updatedAt > 14 * 86400 ? .done : .review }
        if st == "ready-for-review" || st == "pushed-follow-up" { return .review }
        if ["acted", "skipped", "error"].contains(s.action) { return .done }
        if !s.worked || s.j["messages"].int == 0 { return .backlog }
        return .needs
    }

    func column(of s: Session) -> Column { Column(rawValue: s.boardPin) ?? autoColumn(s) }

    // MARK: projects

    var defaultProject: Project? { projects.first }
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }
    func inFilter(_ s: Session) -> Bool { projectFilter == nil || s.project == projectFilter }
    func sessions(in projectId: String) -> [Session] { boardSessions.filter { $0.project == projectId } }
    func orchestratorId(_ projectId: String?) -> String {
        guard let p = projectId, p != defaultProject?.id else { return "orchestrator" }
        return "orchestrator-\(p)"
    }

    func openOrchestrator(_ projectId: String?) {
        let pid = projectId ?? defaultProject?.id ?? ""
        let id = orchestratorId(pid)
        if sessions.contains(where: { $0.id == id }) || pid.isEmpty { return open(id) }
        Task {
            await act {
                let out = try await API.post("/api/projects/\(pid)/orchestrator")
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

    func updateProject(_ id: String, _ patch: [String: Any]) async { await act { try await API.post("/api/projects/\(id)", patch) } }
    func removeProject(_ id: String) async {
        await act { try await API.delete("/api/projects/\(id)") }
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
        composeOpen = true
    }

    // MARK: Slack

    func loadSlack() async {
        slack = (try? await API.get("/api/slack/status")) ?? .null
        guard slack["configured"].bool else { return }
        do { mentions = try await API.get("/api/slack/mentions")["mentions"].array.map(Mention.init) } catch { say(error.localizedDescription, bad: true) }
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
                self.say("Saved. The server is restarting")
            } else {
                self.say("Saved to .env. Restart the server to apply it")
            }
            ok = true
        }
        return ok
    }

    func restartServer() async {
        _ = try? await API.post("/api/restart")
        say("The server is restarting")
    }

    var building = false
    var buildLog = ""

    /// Rebuild Bridge.app from its own source, then swap it in and relaunch.
    func rebuildApp() {
        guard !bridgeRoot.isEmpty, !building else { return }
        building = true
        buildLog = "Building…"
        let root = bridgeRoot
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "cd \"$BRIDGE_ROOT\" && ./scripts/build-app.sh 2>&1"]
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
                self.buildLog = out.split(separator: "\n").suffix(12).joined(separator: "\n")
                guard ok else { return self.say("The build failed: see the log in Settings", bad: true) }
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
        return boardSessions.first { norm($0.prUrl) == n } ?? boardSessions.first { !$0.branch.isEmpty && $0.branch == p.branch }
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
        updateBadge()
    }

    func loadSources(refresh: Bool) async {
        async let a: Void = load("pulls", refresh: refresh)
        async let b: Void = load("linear", refresh: refresh)
        async let c: Void = load("ports")
        _ = await (a, b, c)
    }

    func load(_ name: String, refresh: Bool = false) async {
        if loading.contains(name) { return }
        loading.insert(name)
        defer { loading.remove(name) }
        do {
            let out = try await API.get("/api/sources/\(name)\(refresh ? "?refresh=1" : "")")
            switch name {
            case "pulls": pulls = out
            case "linear": linear = out
            default: ports = out
            }
            errors[name] = out["stale"].nonEmpty
        } catch {
            errors[name] = error.localizedDescription
        }
    }

    private func applyState(_ s: JSON) {
        config = s["config"]
        cost = s["cost"]
        running = Set(s["jobs"]["running"].array.map(\.string))
        awaiting = Set(s["jobs"]["awaiting"].array.map(\.string))
        defaultWorkdir = s["meta"]["workdir"].string
        bridgeRoot = s["meta"]["root"].string
        if !s["meta"]["projects"].isNull { projects = s["meta"]["projects"].array.map(Project.init) }
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
        case "projects": projects = d["projects"].array.map(Project.init)
        case "message", "delta", "run-updated":
            if d["runId"].string == openId || paneRuns.contains(d["runId"].string) { scheduleRefresh() }
        case "ask":
            notify(title: "\(d["who"].nonEmpty ?? "A session") needs you", body: d["summary"].nonEmpty ?? "Claude is waiting on your answer", runId: d["runId"].string)
        case "outcome":
            let st = d["status"].string
            if ["needs-input", "blocked", "ready-for-review", "worker-gone", "usage-limit", "worker-stalled"].contains(st) || d["name"].string != "report" {
                notify(title: d["title"].nonEmpty ?? d["taskId"].string, body: statusLabels[st] ?? d["name"].string.replacingOccurrences(of: "-", with: " "), runId: d["taskId"].string)
            }
            if d["taskId"].string == openId { Task { await refreshOpen() } }
        default: break
        }
        updateBadge()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            refreshPending = false
            await refreshOpen()
        }
    }

    // MARK: sessions

    func open(_ id: String) {
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
    func refreshOpen() async {
        let id = openId
        guard !id.isEmpty, let r = try? await API.get("/api/runs/\(API.q(id))"), id == openId else { return }
        openRun = r["run"]
        runs[id] = openRun
        await refreshPanes()
        let kind = r["run"]["kind"].string
        guard kind == "task" || kind == "slack" || kind.isEmpty else { return }
        let task = (try? await API.get("/api/tasks/\(API.q(id))")) ?? .null
        if id == openId { openTask = task; taskCache[id] = task }
    }

    @discardableResult
    func send(_ text: String, to id: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let live = sessions.first { $0.id == id }.map(isLive) ?? false
        var ok = false
        await act {
            let out = try await API.post("/api/runs/\(API.q(id))/followup", ["text": t, "queue": live || id.hasPrefix("orchestrator")])
            ok = true
            if out["queued"].bool { self.say("Queued: it's mid-turn.") }
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

    func delete(_ id: String) async {
        await act {
            try await API.delete("/api/runs/\(API.q(id))")
            if self.openId == id { self.openId = ""; self.route = .sessions }
            self.forgetPanes(of: id)
        }
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
                self.say(out["state"].string == "queued" ? "Queued: every worker slot is busy." : "Worker started on \(out["branch"].string)")
                self.open(out["taskId"].string)
            } else {
                var orch = self.orchestratorId(project)
                if !self.sessions.contains(where: { $0.id == orch }), let pid = project {
                    orch = try await API.post("/api/projects/\(pid)/orchestrator")["runId"].string
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
            say(out["state"].string == "queued" ? "Queued: every worker slot is busy." : "Worker started on \(out["branch"].string)")
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
        await act { try await API.post("/api/decisions/\(id)", ["action": action, "answer": answer]) }
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

    private func notify(title: String, body: String, runId: String) {
        guard canNotify else { return }
        if NSApp.isActive, openId == runId { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = ["runId": runId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ask-\(runId)", content: c, trigger: nil))
    }

    func updateBadge() {
        let n = needsCount
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}
