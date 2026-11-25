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
    var isOrchestrator: Bool { kind == "orchestrator" || id == "orchestrator" }
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
    var pinned: String { j["board"].string }
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
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
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
    case home, inbox, board, sessions, pulls, linear, memory
    case session(String)

    var title: String {
        switch self {
        case .home: return "Home"
        case .inbox: return "Inbox"
        case .board: return "Board"
        case .sessions: return "Sessions"
        case .pulls: return "Pull requests"
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
    var route: Route = .home
    var connected = false
    var everConnected = false

    var config: JSON = .null
    var cost: JSON = .null
    var running: Set<String> = []
    var awaiting: Set<String> = []
    var defaultWorkdir = ""
    var terminalName = "Terminal"
    var sessions: [Session] = []
    var inbox: JSON = .null

    var pulls: JSON = .null
    var linear: JSON = .null
    var ports: JSON = .null
    var loading: Set<String> = []
    var errors: [String: String] = [:]

    var openRun: JSON = .null
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
        if st == "cleaned" || st == "stopped" { return .done }
        if !s.prUrl.isEmpty { return (!pulls.isNull && p == nil) ? .done : .review }
        if st == "ready-for-review" || st == "pushed-follow-up" { return .review }
        if ["acted", "skipped", "error"].contains(s.action) { return .done }
        if !s.worked { return .backlog }
        return .needs
    }

    func column(of s: Session) -> Column { Column(rawValue: s.pinned) ?? autoColumn(s) }

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
                Task { await self.loadAll() }
            } else if !self.startedServer {
                self.startedServer = true
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
        try? p.run()
    }

    func loadAll() async {
        if let s = try? await API.get("/api/state") { applyState(s) }
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
        terminalName = s["meta"]["terminal"].nonEmpty ?? "Terminal"
    }

    private func handle(_ name: String, _ d: JSON) {
        switch name {
        case "state": applyState(d)
        case "runs": sessions = d["runs"].array.map(Session.init)
        case "jobs":
            running = Set(d["running"].array.map(\.string))
            awaiting = Set(d["awaiting"].array.map(\.string))
        case "inbox": inbox = d
        case "message", "delta", "run-updated":
            if d["runId"].string == openId { scheduleRefresh() }
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
        route = .session(id)
        guard openId != id else { return }
        openId = id
        openRun = .null
        openTask = .null
        Task {
            await refreshOpen()
            try? await API.post("/api/runs/\(API.q(id))/seen")
        }
    }

    func refreshOpen() async {
        let id = openId
        guard !id.isEmpty else { return }
        if let r = try? await API.get("/api/runs/\(API.q(id))"), id == openId { openRun = r["run"] }
        let kind = openRun["kind"].string
        if kind == "task" || kind == "slack" || kind.isEmpty {
            openTask = (try? await API.get("/api/tasks/\(API.q(id))")) ?? .null
        }
    }

    func send(_ text: String, to id: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let live = sessions.first { $0.id == id }.map(isLive) ?? false
        await act {
            let out = try await API.post("/api/runs/\(API.q(id))/followup", ["text": t, "queue": live || id == "orchestrator"])
            if out["queued"].bool { self.say("Queued: it's mid-turn.") }
        }
        await refreshOpen()
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
            sessions[i] = Session(j: .obj(o))
        }
        await act { try await API.post("/api/runs/\(API.q(id))/board", ["column": column?.rawValue ?? ""]) }
    }

    func stop(_ id: String) async { await act { try await API.post("/api/runs/\(API.q(id))/stop") } }
    func start(_ id: String) async { await act { try await API.post("/api/runs/\(API.q(id))/start") } }
    func terminal(_ id: String) async {
        await act {
            let out = try await API.post("/api/runs/\(API.q(id))/terminal")
            if out["opened"].bool { self.say("Opened in \(out["app"].nonEmpty ?? self.terminalName)") }
            else {
                copyToPasteboard(out["command"].string)
                self.say((out["note"].nonEmpty ?? "Couldn't open a terminal") + " (command copied)", bad: true)
            }
        }
    }
    func relaunch(_ id: String) async { await act { try await API.post("/api/tasks/\(API.q(id))/relaunch") } }
    func cleanup(_ id: String, force: Bool = false) async {
        await act { try await API.post("/api/tasks/\(API.q(id))/cleanup", ["force": force]) }
        await refreshOpen()
    }

    func delete(_ id: String) async {
        await act {
            try await API.delete("/api/runs/\(API.q(id))")
            if self.openId == id { self.openId = ""; self.route = .sessions }
        }
    }

    // MARK: creating work

    /// The one box work starts from: a Slack thread link opens a chat and runs
    /// the pipeline; anything else becomes a task, written up either by the
    /// orchestrator or handed straight to a worker.
    func create(_ text: String, direct: Bool, repo: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        var ok = false
        await act {
            if t.range(of: #"^https://[^/]*slack\.com/archives/"#, options: .regularExpression) != nil {
                let out = try await API.post("/api/runs", ["url": t, "start": true])
                self.open(out["runId"].string)
            } else if direct {
                var body: [String: Any] = ["brief": t]
                if !repo.isEmpty { body["repo"] = repo }
                let out = try await API.post("/api/tasks", body)
                self.say(out["state"].string == "queued" ? "Queued: every worker slot is busy." : "Worker started on \(out["branch"].string)")
                self.open(out["taskId"].string)
            } else {
                try await API.post("/api/runs/orchestrator/followup", ["text": t, "queue": true])
                self.open("orchestrator")
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

    func startIssue(_ issue: Issue, branch: String? = nil) async {
        let brief = [
            "Linear issue \(issue.key): \(issue.title)", issue.url, "",
            issue.description.isEmpty ? "(no description)" : issue.description, "",
            "Read the issue and its comments through the Linear connector before starting. Build it, verify it, and open a PR that references the issue key.",
        ].joined(separator: "\n")
        var body: [String: Any] = ["title": "\(issue.key) \(issue.title)", "brief": brief]
        let br = branch ?? issue.branch
        if !br.isEmpty { body["branch"] = br }
        do {
            let out = try await API.post("/api/tasks", body)
            say(out["state"].string == "queued" ? "Queued: every worker slot is busy." : "Worker started on \(out["branch"].string)")
            open(out["taskId"].string)
        } catch {
            // Linear's branch already exists here: let the server name one.
            if error.localizedDescription.contains("already exists"), branch == nil, !issue.branch.isEmpty {
                await startIssue(issue, branch: "")
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
