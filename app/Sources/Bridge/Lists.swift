import AppKit
import SwiftUI

// MARK: - Shared rows

struct PortChips: View {
    let servers: [DevServer]
    var body: some View {
        ForEach(servers) { sv in
            ForEach(sv.ports.prefix(2), id: \.self) { port in
                Button { openURL("http://localhost:\(port)") } label: { Chip(text: ":\(port)", icon: "play.fill", tint: T.green, mono: true) }
                    .buttonStyle(.plain)
                    .help("\(sv.command) in \(sv.cwd)")
            }
        }
    }
}

/// Stops a dev server's process (every port it listens on) after a confirm; spins while it stops.
struct StopServerButton: View {
    @Environment(AppModel.self) var model
    let server: DevServer
    var size: CGFloat = B.small

    var body: some View {
        let busy = model.stoppingServers.contains(server.id)
        IconButton(icon: busy ? "arrow.triangle.2.circlepath" : "stop.circle", help: "Stop \(server.command) (pid \(server.id))", spinning: busy, size: size) {
            Task { await model.stopServer(server) }
        }
        .disabled(busy)
    }
}

struct ChecksIcon: View {
    let pr: PullRequest
    var body: some View {
        switch pr.checks {
        case "SUCCESS": Image(systemName: "checkmark.circle.fill").foregroundStyle(T.green).help("Checks pass")
        case "FAILURE", "ERROR": Image(systemName: "xmark.circle.fill").foregroundStyle(T.red).help("Checks failing")
        case "PENDING", "EXPECTED": Image(systemName: "clock.fill").foregroundStyle(T.yellow).help("Checks running")
        default: Image(systemName: "circle.dotted").foregroundStyle(T.text3)
        }
    }
}

struct PRStateIcon: View {
    let pr: PullRequest
    var body: some View {
        let (icon, color): (String, Color) = pr.state == "MERGED" ? ("arrow.triangle.merge", T.purple)
            : pr.state == "CLOSED" ? ("xmark.circle", T.red)
            : pr.draft ? ("arrow.triangle.pull", T.text3) : ("arrow.triangle.pull", T.green)
        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).frame(width: 16)
    }
}

/// A PR in a few glyphs: its state icon and number, then "Merged"/"Draft"/
/// "Closed" when it isn't plain open. Sits under a sidebar row's title.
struct PRBadge: View {
    let pr: PullRequest
    var size: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: size - 1.5, weight: .semibold)).foregroundStyle(tint)
            Text(verbatim: "\(pr.number)").font(T.ui(size)).foregroundStyle(T.text3).monospacedDigit()
            if !pr.open || pr.draft { Text(pr.stateLabel).font(T.ui(size)).foregroundStyle(tint) }
        }
        .fixedSize()
        .help("\(pr.stateLabel) pull request #\(pr.number)")
    }

    var icon: String { pr.state == "MERGED" ? "arrow.triangle.merge" : pr.state == "CLOSED" ? "xmark.circle" : "arrow.triangle.pull" }
    var tint: Color { pr.state == "MERGED" ? T.purple : pr.state == "CLOSED" ? T.red : pr.draft ? T.text3 : T.green }
}

/// The head commit's CI in one word ("passed", "2 failing", "running"),
/// with the counts behind it in the tooltip.
struct ChecksBadge: View {
    let pr: PullRequest
    var size: CGFloat = 11.5

    var body: some View {
        if let (icon, label, tint) = look {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: size - 1.5, weight: .semibold))
                Text(label).font(T.ui(size))
            }
            .foregroundStyle(tint)
            .fixedSize()
            .help(ChecksBadge.detail(pr))
        }
    }

    var look: (String, String, Color)? {
        if pr.failing { return ("xmark.circle", pr.failCount > 0 ? "\(pr.failCount) failing" : "failing", T.red) }
        if pr.running { return ("circle.dashed", pr.pendingCount > 0 ? "\(pr.pendingCount) running" : "running", T.orange) }
        if pr.checks == "SUCCESS" { return ("checkmark.circle", "passed", T.green) }
        return nil
    }

    static func detail(_ pr: PullRequest) -> String {
        let parts = [(pr.passCount, "passed"), (pr.failCount, "failing"), (pr.pendingCount, "running"), (pr.skippedCount, "skipped")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Checks" : "Checks: " + parts.joined(separator: ", ")
    }
}

/// Check counts as GitHub shows them: ✓ 6  ✗ 1  ◌ 2.
struct CheckCounts: View {
    let pr: PullRequest
    var body: some View {
        HStack(spacing: 8) {
            if pr.passCount + pr.failCount + pr.pendingCount + pr.skippedCount == 0 {
                ChecksBadge(pr: pr, size: 11.5)
            } else {
                count(pr.passCount, "checkmark.circle", T.green)
                count(pr.failCount, "xmark.circle", T.red)
                count(pr.pendingCount, "circle.dashed", T.orange)
                count(pr.skippedCount, "slash.circle", T.text3)
            }
        }
        .help(ChecksBadge.detail(pr))
    }

    @ViewBuilder func count(_ n: Int, _ icon: String, _ tint: Color) -> some View {
        if n > 0 {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(verbatim: "\(n)").font(T.ui(11.5)).monospacedDigit()
            }
            .foregroundStyle(tint)
        }
    }
}

/// What a sidebar session's hover shows: its PR's title, state, size,
/// author, branch, folder and checks.
struct SessionHoverCard: View {
    let session: Session
    let pr: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(session.title).font(T.ui(13, .semibold)).foregroundStyle(T.text).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                PRBadge(pr: pr, size: 12)
                if pr.review == "APPROVED" { Text("Approved").font(T.ui(12)).foregroundStyle(T.green) }
                if pr.review == "CHANGES_REQUESTED" { Text("Changes requested").font(T.ui(12)).foregroundStyle(T.red) }
                if pr.open && pr.mergeable == "CONFLICTING" { Text("Conflicts").font(T.ui(12)).foregroundStyle(T.orange) }
            }
            row("doc.text") {
                Text(verbatim: "+\(pr.additions)").foregroundStyle(T.green)
                Text(verbatim: "−\(pr.deletions)").foregroundStyle(T.red)
            }
            if !pr.author.isEmpty { row("person") { Text(pr.author).foregroundStyle(T.text2) } }
            if !pr.branch.isEmpty { row("arrow.triangle.branch") { Text(pr.branch).foregroundStyle(T.text2).lineLimit(1) } }
            if !session.worktree.isEmpty { row("folder") { Text(URL(fileURLWithPath: session.worktree).lastPathComponent).foregroundStyle(T.text2).lineLimit(1) } }
            Divider().overlay(T.line)
            HStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(T.text3).frame(width: 14)
                Text("Checks").font(T.ui(12)).foregroundStyle(T.text2)
                Spacer(minLength: 12)
                CheckCounts(pr: pr)
            }
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
    }

    func row<C: View>(_ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(T.text3).frame(width: 14)
            HStack(spacing: 5) { content() }.font(T.ui(12))
        }
    }
}

struct ReviewChip: View {
    let pr: PullRequest
    var body: some View {
        switch pr.review {
        case "APPROVED": Chip(text: "Approved", icon: "checkmark", tint: T.green)
        case "CHANGES_REQUESTED": Chip(text: "Changes requested", icon: "arrow.uturn.backward", tint: T.red)
        case "REVIEW_REQUIRED": Chip(text: "Review required", icon: "eye")
        default: EmptyView()
        }
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) var model
    let session: Session
    var unarchive = false

    var body: some View {
        HoverRow(height: 46) {
            HStack(spacing: 12) {
                SessionIcon(session: session)
                Text(session.isTask ? "TASK" : "SLACK").font(T.mono(10, .semibold)).foregroundStyle(session.isTask ? T.accent : T.slack).frame(width: 38, alignment: .leading)
                if !session.issueKey.isEmpty && !session.title.hasPrefix(session.issueKey) { Text(session.issueKey).font(T.mono(11.5)).foregroundStyle(T.text3) }
                Text(session.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                if session.pinned { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(T.yellow) }
                Text(model.isAwaiting(session) ? session.askedFor : session.statusLine.isEmpty ? session.snippet : session.statusLine)
                    .font(T.ui(12.5)).foregroundStyle(model.isAwaiting(session) ? T.orange : T.text3).lineLimit(1)
                Spacer(minLength: 8)
                PortChips(servers: model.servers(for: session))
                ProjectChip(session: session)
                if let pr = model.pr(for: session.prUrl) {
                    ChecksBadge(pr: pr, size: 11.5)
                    PRBadge(pr: pr, size: 11.5)
                } else if !session.prUrl.isEmpty {
                    Chip(text: "#\(session.prNumber)", icon: "arrow.triangle.pull", mono: true)
                }
                if unarchive {
                    Button { Task { await model.setArchived(session.id, false) } } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                        .buttonStyle(LButton())
                }
                Text(Fmt.ago(session.updatedAt)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 34, alignment: .trailing)
            }
        }
        .onTapGesture { model.open(session.id) }
        .draggable(session.id)
        .contextMenu { SessionMenu(session: session) }
    }
}

struct SessionMenu: View {
    @Environment(AppModel.self) var model
    let session: Session
    /// In the chat's own ⋯ menu: opening it again (or beside itself), the
    /// terminal (the + menu has it), and anything the header already shows
    /// (pin star, stop, unarchive, brief, open in) would only repeat what's
    /// on screen. A split pane's header has none of those, so they stay there.
    var inChat = false
    /// Header-covered actions drop out only in the single chat; a split
    /// pane's ⋯ is their only home.
    var ownHeader: Bool { inChat && !model.isSplit }
    var body: some View {
        if !inChat {
            Section {
                Button { model.open(session.id) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                Button { model.openToSide(session.id) } label: { Label("Open to the Side", systemImage: "rectangle.split.2x1") }
                    .disabled(model.isChatRoute && model.panes.contains { $0.run == session.id && $0.tab == "chat" })
                Button { model.open(session.id); model.openTerminalTab(session.id) } label: { Label("Terminal", systemImage: "terminal") }
            }
        }
        if !ownHeader {
            Section { OpenInMenu(session: session) }
        }
        Section {
            if !inChat {
                Button { Task { await model.setPinned(session.id, !session.pinned) } } label: {
                    Label(session.pinned ? "Unpin from Sidebar" : "Pin to Sidebar", systemImage: session.pinned ? "star.slash" : "star")
                }
            }
            Menu {
                ForEach(Column.allCases) { c in
                    Button { Task { await model.move(session.id, to: c) } } label: {
                        Label(c.label, systemImage: !session.boardPin.isEmpty && model.column(of: session) == c ? "checkmark" : c.symbol)
                    }
                }
                Divider()
                Button { Task { await model.move(session.id, to: nil) } } label: {
                    Label("Automatic", systemImage: session.boardPin.isEmpty ? "checkmark" : "wand.and.stars")
                }
            } label: { Label("Set Status", systemImage: model.column(of: session).symbol) }
            if model.projects.count > 1 {
                Menu {
                    ForEach(model.projects) { p in
                        Button { Task { await model.setProject(session.id, p.id) } } label: { Label(p.name, systemImage: p.id == session.project ? "checkmark" : "folder") }
                            .disabled(p.id == session.project)
                    }
                } label: { Label("Move to Project", systemImage: "folder") }
            }
        }
        Menu {
            if !session.branch.isEmpty { Button { copyToPasteboard(session.branch) } label: { Label("Branch Name", systemImage: "arrow.triangle.branch") } }
            if !session.prUrl.isEmpty { Button { copyToPasteboard(session.prUrl) } label: { Label("Pull Request Link", systemImage: "link") } }
            if !session.issueKey.isEmpty { Button { copyToPasteboard(session.issueKey) } label: { Label("Issue ID", systemImage: "number.square") } }
            Button { copyToPasteboard(session.title) } label: { Label("Title", systemImage: "textformat") }
            Button { copyToPasteboard(session.id) } label: { Label("Session ID", systemImage: "barcode") }
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        if session.isOrchestrator || !session.archived || !ownHeader {
            Section {
                if model.isLive(session) && !inChat {
                    Button { Task { await model.stop(session.id) } } label: { Label("Stop", systemImage: "stop.circle") }
                }
                if session.isOrchestrator {
                    if !ownHeader {
                        Button { Task { await model.brief(session.id) } } label: { Label("Brief Me", systemImage: "sparkles") }
                    }
                    Button(role: .destructive) { Task { await model.clearChat(session.id) } } label: { Label("Clear Chat…", systemImage: "eraser") }
                        .disabled(model.isLive(session))
                } else {
                    if session.archived {
                        if !ownHeader {
                            Button { Task { await model.setArchived(session.id, false) } } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                        }
                    } else {
                        Button { model.confirmArchive(session.id) } label: { Label("Archive…", systemImage: "archivebox") }
                            .disabled(model.isLive(session))
                    }
                }
            }
        }
    }
}

struct PRRow: View {
    @Environment(AppModel.self) var model
    let pr: PullRequest
    var mine = true

    var body: some View {
        HoverRow(height: 46) {
            HStack(spacing: 12) {
                PRStateIcon(pr: pr)
                Text(verbatim: "\(pr.repoName)#\(pr.number)").font(T.mono(11.5)).foregroundStyle(T.text3).frame(width: 108, alignment: .leading)
                Text(pr.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 8)
                PortChips(servers: pr.open ? model.servers(forBranch: pr.branch) : [])
                if pr.open, let p = pr.preview { PreviewChip(preview: p, run: model.session(forPR: pr)?.id, size: 11, boxed: true) }
                if !pr.issueKey.isEmpty { Chip(text: pr.issueKey, mono: true) }
                ReviewChip(pr: pr)
                if pr.mergeable == "CONFLICTING" && pr.open { Chip(text: "Conflicts", icon: "exclamationmark.triangle", tint: T.orange) }
                if pr.draft { Chip(text: "Draft") }
                HStack(spacing: 3) {
                    Text(verbatim: "+\(pr.additions)").foregroundStyle(T.green)
                    Text(verbatim: "−\(pr.deletions)").foregroundStyle(T.red)
                }
                .font(T.mono(11)).frame(width: 84, alignment: .trailing)
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left").font(.system(size: 10))
                    Text(verbatim: "\(pr.comments)").font(T.ui(11.5)).monospacedDigit()
                }
                .foregroundStyle(T.text3).frame(width: 38, alignment: .trailing)
                ChecksIcon(pr: pr).font(.system(size: 12.5)).frame(width: 16)
                if !mine { Avatar(name: pr.author, url: pr.avatar, size: 18) }
                Text(Fmt.ago(pr.updatedAt)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 34, alignment: .trailing)
            }
        }
        .onTapGesture(count: 2) { openURL(pr.url) }
        .onTapGesture { if let s = model.session(forPR: pr) { model.open(s.id) } else { openURL(pr.url) } }
        .contextMenu { PRMenu(pr: pr, mine: mine) }
    }
}

struct PRMenu: View {
    @Environment(AppModel.self) var model
    let pr: PullRequest
    let mine: Bool
    var body: some View {
        Section {
            Button { openURL(pr.url) } label: { Label("Open on GitHub", systemImage: "safari") }
            if let s = model.session(forPR: pr) { Button { model.open(s.id) } label: { Label("Open Session", systemImage: "bubble.left.and.text.bubble.right") } }
            if pr.open, let p = pr.preview {
                Button { model.openPreview(p.url, run: model.session(forPR: pr)?.id) } label: { Label("Open \(p.name) Preview", systemImage: "globe") }
            }
            if pr.open, !model.servers(forBranch: pr.branch).isEmpty, let port = model.servers(forBranch: pr.branch).first?.ports.first {
                Button { openURL("http://localhost:\(port)") } label: { Label("Open Dev Server :\(port)", systemImage: "play.circle") }
            }
        }
        if pr.open {
            Section {
                if mine {
                    if pr.failing { Button { ask("Spawn a worker for \(pr.url) (branch \(pr.branch)): checks are failing. Check out the existing PR branch, find why CI fails, fix it and push to the same branch.") } label: { Label("Fix CI with Claude", systemImage: "wrench.and.screwdriver") } }
                    Button { ask("Spawn a worker for \(pr.url) (branch \(pr.branch)): check out the existing PR branch and run /resolve on it.") } label: { Label("Resolve Comments with Claude", systemImage: "text.bubble") }
                    if pr.mergeable == "CONFLICTING" { Button { ask("Spawn a worker for \(pr.url) (branch \(pr.branch)): check out the PR branch, merge the base branch in, resolve the conflicts, verify, and push.") } label: { Label("Fix Conflicts with Claude", systemImage: "arrow.triangle.merge") } }
                } else {
                    Button { ask("Spawn a worker to review \(pr.url): run /review on it and report findings. Do not approve or merge.") } label: { Label("Review with Claude", systemImage: "eye") }
                }
            }
        }
        Section {
            Button { copyToPasteboard(pr.url) } label: { Label("Copy Link", systemImage: "link") }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            Button { copyToPasteboard(pr.branch) } label: { Label("Copy Branch Name", systemImage: "arrow.triangle.branch") }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button { copyToPasteboard("\(pr.repoName)#\(pr.number)") } label: { Label("Copy Reference", systemImage: "number") }
                .keyboardShortcut(".", modifiers: .command)
        }
    }
    func ask(_ t: String) { Task { await model.askOrchestrator(t) } }
}

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Home", icon: "house") {
                IconButton(icon: "arrow.clockwise", help: "Refresh (⌘R)", spinning: !model.refreshing.isEmpty) { Task { await model.loadSources(refresh: true) } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(greeting).font(T.ui(22, .semibold)).foregroundStyle(T.text).padding(.top, 6).rise(0)
                    stats.rise(1)
                    let needs = model.boardSessions.filter { model.column(of: $0) == .needs }
                    let live = model.boardSessions.filter { model.isLive($0) && model.column(of: $0) != .needs }
                    Card(title: "Needs you", count: needs.count + model.decisions.count, icon: AnyView(StatusIcon(kind: .attention, size: 13))) {
                        if needs.isEmpty && model.decisions.isEmpty { CardEmpty(text: "Nothing is waiting on you.") }
                        ForEach(model.decisions.prefix(4), id: \.self) { d in
                            HoverRow {
                                HStack(spacing: 10) {
                                    Image(systemName: d["kind"].string == "action" ? "hand.raised" : "questionmark.bubble").foregroundStyle(T.orange).frame(width: 14)
                                    Text(d["title"].nonEmpty ?? d["taskId"].string).font(T.ui(13, .medium)).lineLimit(1)
                                    Text(inline(d["text"].string.replacingOccurrences(of: "\n", with: " "))).font(T.ui(12.5)).foregroundStyle(T.text3).lineLimit(1)
                                    Spacer()
                                }
                            }
                            .onTapGesture { model.route = .inbox }
                        }
                        ForEach(needs.prefix(6)) { SessionRow(session: $0) }
                    }
                    .rise(2)
                    if !live.isEmpty {
                        Card(title: "Running", count: live.count, icon: AnyView(LiveIcon(size: 13))) { ForEach(live) { SessionRow(session: $0) } }
                            .rise(3)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        let prs = model.openPulls.filter(\.needsAttention) + model.reviewPulls
                        Card(title: "Pull requests", count: prs.count, icon: AnyView(Image(systemName: "arrow.triangle.pull").font(.system(size: 11)).foregroundStyle(T.text2)), more: ("All", { model.route = .pulls })) {
                            if prs.isEmpty { CardEmpty(text: model.loading.contains("pulls") ? "Loading…" : "Nothing failing or waiting on your review.") }
                            ForEach(prs.prefix(7)) { CompactPR(pr: $0) }
                        }
                        let issues = model.issues.filter { $0.stateType == "started" || $0.stateType == "unstarted" }.sorted { ($0.status == .progress ? 0 : 1, $0.priority == 0 ? 9 : $0.priority) < ($1.status == .progress ? 0 : 1, $1.priority == 0 ? 9 : $1.priority) }
                        Card(title: "Linear", count: issues.count, icon: AnyView(StatusIcon(kind: .progress, size: 13)), more: ("All", { model.route = .linear })) {
                            if issues.isEmpty { CardEmpty(text: model.loading.contains("linear") ? "Loading…" : "Nothing in progress or to do.") }
                            ForEach(issues.prefix(7)) { CompactIssue(issue: $0) }
                        }
                    }
                    .rise(4)
                    HStack(alignment: .top, spacing: 18) {
                        Card(title: "Dev servers", count: model.servers.count, icon: AnyView(Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(T.text2))) {
                            if model.servers.isEmpty { CardEmpty(text: "No dev server is listening in your folders.") }
                            ForEach(model.servers) { sv in
                                HoverRow {
                                    HStack(spacing: 10) {
                                        PortChips(servers: [sv])
                                        Text(sv.folder).font(T.ui(12.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.head)
                                        Spacer()
                                        Text(sv.command).font(T.mono(11)).foregroundStyle(T.text3)
                                        StopServerButton(server: sv)
                                    }
                                }
                            }
                        }
                    }
                    .rise(5)
                }
                .padding(.horizontal, 36)
                .padding(.top, 10)
                .padding(.bottom, 40)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    var stats: some View {
        HStack(spacing: 0) {
            Stat(value: "\(model.liveCount)", label: "Running", tint: model.liveCount == 0 ? nil : T.yellow) { model.navigate(.sessions) }
            Stat(value: "\(model.needsCount)", label: "Need you", tint: model.needsCount > 0 ? T.orange : nil) { model.route = .inbox }
            Stat(value: model.pulls.isNull ? "–" : "\(model.openPulls.count)", label: "Open PRs", sub: "\(model.openPulls.filter(\.needsAttention).count) need attention") { model.route = .pulls }
            Stat(value: model.pulls.isNull ? "–" : "\(model.reviewPulls.count)", label: "Reviews for you") { model.route = .pulls }
            Stat(value: model.linear.isNull ? "–" : "\(model.issues.filter { $0.stateType == "started" }.count)", label: "Issues in progress", last: true) { model.route = .linear }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Stat: View {
    let value: String
    let label: String
    var sub: String = ""
    var tint: Color? = nil
    var last = false
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(tint ?? T.text)
                    .contentTransition(.numericText())
                Text(label).font(T.ui(12)).foregroundStyle(T.text2)
                if !sub.isEmpty { Text(sub).font(T.ui(11)).foregroundStyle(T.text3) }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover.v ? T.hover.opacity(0.6) : .clear)
            .overlay(alignment: .trailing) { if !last { Rectangle().fill(T.line).frame(width: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBox(hover)
    }
}

struct Card<Content: View>: View {
    let title: String
    let count: Int?
    var icon: AnyView? = nil
    var more: (String, () -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let icon { icon }
                Text(title).font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                if let count { Text(verbatim: "\(count)").font(T.ui(12)).foregroundStyle(T.text3) }
                Spacer()
                if let more { LinkButton(more.0, action: more.1) }
            }
            .padding(.horizontal, 20).frame(height: 46)
            Hairline()
            // No bottom padding: the last row's divider lands under the card's border.
            VStack(spacing: 0) { content() }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CardEmpty: View {
    let text: String
    var body: some View { Text(text).font(T.ui(12.5)).foregroundStyle(T.text3).padding(.horizontal, 20).padding(.vertical, 14) }
}

struct CompactPR: View {
    @Environment(AppModel.self) var model
    let pr: PullRequest
    var body: some View {
        HoverRow(height: 40) {
            HStack(spacing: 10) {
                PRStateIcon(pr: pr)
                Text(verbatim: "#\(pr.number)").font(T.mono(11.5)).foregroundStyle(T.text3)
                Text(pr.title).font(T.ui(12.5)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 6)
                if pr.review == "CHANGES_REQUESTED" { Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(T.red) }
                if pr.author != model.pulls["login"].string { Avatar(name: pr.author, url: pr.avatar, size: 16) }
                ChecksIcon(pr: pr).font(.system(size: 12))
            }
        }
        .onTapGesture { openURL(pr.url) }
        .contextMenu { PRMenu(pr: pr, mine: pr.author == model.pulls["login"].string) }
    }
}

struct CompactIssue: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    var body: some View {
        HoverRow(height: 40) {
            HStack(spacing: 10) {
                PriorityIcon(priority: issue.priority)
                StatusIcon(kind: issue.status, color: hexColor(issue.stateColor, fallback: issue.status.color), size: 13)
                Text(issue.key).font(T.mono(11.5)).foregroundStyle(T.text3)
                Text(issue.title).font(T.ui(12.5)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 6)
                if !issue.children.isEmpty {
                    HStack(spacing: 4) { Ring(done: issue.childrenDone, total: issue.children.count, size: 11); Text(verbatim: "\(issue.childrenDone)/\(issue.children.count)").font(T.ui(11)).foregroundStyle(T.text3) }
                }
            }
        }
        .onTapGesture { openURL(issue.url) }
        .contextMenu { IssueMenu(issue: issue) }
    }
}

// MARK: - Board

struct BoardView: View {
    @Environment(AppModel.self) var model
    @StateObject private var query = Box("")
    @Namespace private var cards

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Sessions", subtitle: "Cards follow their session until you drag them", icon: "rectangle.stack") {
                LayoutPicker()
                ArchivedToggle()
                ProjectFilterMenu()
                SearchField(text: $query.v).frame(width: 200)
                IconButton(icon: "plus", help: "New task (⌘N)") { model.compose(in: model.projectFilter) }
            }
            GeometryReader { g in
                // Columns share the width, down to 210pt each; below that the board scrolls.
                let width = max(220, (g.size.width - 40 - 48) / 5)
                let cols = columns
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Column.allCases) { c in BoardColumn(column: c, sessions: cols[c] ?? [], ns: cards).frame(width: width) }
                    }
                    .animation(M.snappy, value: layout(cols))
                    .padding(20)
                    .frame(height: g.size.height, alignment: .top)
                }
            }
        }
    }

    func layout(_ cols: [Column: [Session]]) -> [String] { Column.allCases.flatMap { c in (cols[c] ?? []).map { "\(c.rawValue):\($0.id)" } } }

    var columns: [Column: [Session]] {
        let q = query.v.lowercased()
        let shown = model.boardSessions
            .filter { model.inFilter($0) && (q.isEmpty || "\($0.title) \($0.text) \($0.channel) \($0.issueKey)".lowercased().contains(q)) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Dictionary(grouping: shown) { model.column(of: $0) }
    }
}

struct BoardColumn: View {
    @Environment(AppModel.self) var model
    let column: Column
    let sessions: [Session]
    let ns: Namespace.ID
    @StateObject private var targeted = Box(false)
    @StateObject private var showAll = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatusIcon(kind: column.status, size: 13)
                Text(column.label).font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                Text(verbatim: "\(sessions.count)").font(T.ui(12)).foregroundStyle(T.text3).monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 42)
            ScrollView {
                LazyVStack(spacing: 8) {
                    let shown = column == .done && !showAll.v ? Array(sessions.prefix(30)) : sessions
                    ForEach(shown) { s in
                        BoardCard(session: s)
                            .matchedGeometryEffect(id: s.id, in: ns)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    if shown.count < sessions.count {
                        LinkButton("Show \(sessions.count - shown.count) more") { showAll.v = true }.padding(6)
                    }
                    if sessions.isEmpty {
                        RoundedRectangle(cornerRadius: 8).stroke(targeted.v ? T.accent.opacity(0.7) : T.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(height: 64)
                            .overlay(Text("Drop here").font(T.ui(12)).foregroundStyle(targeted.v ? T.accent : T.text3))
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(targeted.v ? T.accentSoft : T.raised.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(targeted.v ? T.accent.opacity(0.6) : Color.clear, lineWidth: 1))
        .animation(M.hover, value: targeted.v)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let s = model.sessions.first(where: { $0.id == id }) else { return false }
            // Dropping where it would land on its own unpins it.
            Task { await model.move(id, to: model.autoColumn(s) == column ? nil : column) }
            return true
        } isTargeted: { targeted.v = $0 }
    }
}

struct BoardCard: View {
    @Environment(AppModel.self) var model
    let session: Session
    @StateObject private var hover = Box(false)

    var body: some View {
        let pr = model.pr(for: session.prUrl)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(session.isTask ? "TASK" : "SLACK").font(T.mono(10, .semibold)).foregroundStyle(session.isTask ? T.accent : T.slack)
                if !session.issueKey.isEmpty && !session.title.hasPrefix(session.issueKey) { Text(session.issueKey).font(T.mono(11)).foregroundStyle(T.text3).fixedSize() }
                ProjectChip(session: session).lineLimit(1)
                Spacer(minLength: 4)
                if session.pinned { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(T.yellow) }
                if !session.boardPin.isEmpty {
                    Button { Task { await model.move(session.id, to: nil) } } label: {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(T.text3)
                    }
                    .buttonStyle(.plain).help("You placed this card. Click to let it follow its session again.")
                }
                Text(Fmt.ago(session.updatedAt)).font(T.ui(11)).foregroundStyle(T.text3).fixedSize()
            }
            HStack(alignment: .top, spacing: 8) {
                SessionIcon(session: session, size: 13).padding(.top, 1.5)
                Text(session.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(2)
            }
            if !session.snippet.isEmpty {
                Text(session.snippet).font(T.ui(12)).foregroundStyle(T.text2).lineLimit(2)
            }
            if model.isAwaiting(session) {
                Label(session.askedFor.isEmpty ? "Waiting on you" : session.askedFor, systemImage: "hand.raised.fill")
                    .font(T.ui(11.5, .medium)).foregroundStyle(T.orange).lineLimit(1)
            } else if !session.statusLine.isEmpty {
                Text(session.statusLine).font(T.ui(11.5)).foregroundStyle(T.accent).lineLimit(1)
            }
            let ports = model.servers(for: session)
            if !session.prUrl.isEmpty || !ports.isEmpty {
                HStack(spacing: 5) {
                    if let pr {
                        Button { openURL(session.prUrl) } label: { PRBadge(pr: pr, size: 11.5) }.buttonStyle(.plain)
                        ChecksBadge(pr: pr, size: 11.5)
                        if pr.open, let p = pr.preview { PreviewChip(preview: p, run: session.id) }
                    } else if !session.prUrl.isEmpty {
                        Button { openURL(session.prUrl) } label: { Chip(text: "#\(session.prNumber)", icon: "arrow.triangle.pull", mono: true) }.buttonStyle(.plain)
                    }
                    PortChips(servers: ports)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover.v ? T.hover : T.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(model.isAwaiting(session) ? T.orange.opacity(0.45) : hover.v ? T.text3.opacity(0.5) : T.line, lineWidth: 1))
        .shadow(color: T.shade.opacity(hover.v ? 0.35 : 0.18), radius: hover.v ? 10 : 2, y: hover.v ? 4 : 1)
        .offset(y: hover.v ? -1 : 0)
        .contentShape(Rectangle())
        .hoverBox(hover)
        .onTapGesture { model.open(session.id) }
        .draggable(session.id) {
            Text(session.title).font(T.ui(12.5, .medium)).padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(T.raised))
        }
        .contextMenu { SessionMenu(session: session) }
    }
}

// MARK: - Sessions list

struct SessionsView: View {
    @Environment(AppModel.self) var model
    @StateObject private var query = Box("")

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: model.showArchived ? "Archived" : "Sessions", subtitle: "\(model.showArchived ? archived.count : filtered.count)", icon: model.showArchived ? "archivebox" : "rectangle.stack") {
                LayoutPicker()
                ArchivedToggle()
                ProjectFilterMenu()
                SearchField(text: $query.v).frame(width: 220)
                IconButton(icon: "plus", help: "New task (⌘N)") { model.compose(in: model.projectFilter) }
            }
            if model.showArchived { archivedList } else { liveList }
        }
    }

    var archivedList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(archived) { s in
                    SessionRow(session: s, unarchive: true).transition(.opacity.combined(with: .move(edge: .top)))
                }
                if archived.isEmpty {
                    EmptyState(icon: "archivebox", title: "Nothing archived", detail: "Archive a session from its menu to put it away. It comes back from here.")
                }
            }
            .animation(M.snappy, value: archived.map(\.id))
        }
    }

    var archived: [Session] {
        let q = query.v.lowercased()
        return model.archivedSessions.filter { model.inFilter($0) && (q.isEmpty || "\($0.title) \($0.text) \($0.channel) \($0.issueKey) \($0.branch)".lowercased().contains(q)) }
    }

    var liveList: some View {
        let all = filtered
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if let o = model.sessions.first(where: { $0.id == model.orchestratorId(model.projectFilter) }) ?? model.orchestrator {
                        HoverRow(height: 40) {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles").foregroundStyle(T.purple).frame(width: 14)
                                Text("Orchestrator").font(T.ui(13, .medium))
                                Text("Hand it work; it starts sessions and keeps track of them").font(T.ui(12.5)).foregroundStyle(T.text3)
                                Spacer()
                                if model.isLive(o) { LiveIcon(size: 12) }
                            }
                        }
                        .onTapGesture { model.open(o.id) }
                        Hairline()
                    }
                    ForEach([Column.needs, .doing, .review, .backlog, .done]) { c in
                        let rows = all.filter { model.column(of: $0) == c }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { SessionRow(session: $0).transition(.opacity.combined(with: .move(edge: .top))) }
                            } header: {
                                GroupHeader(title: c.label, count: rows.count, icon: AnyView(StatusIcon(kind: c.status, size: 13)))
                            }
                        }
                    }
                    if model.boardSessions.isEmpty {
                        EmptyState(icon: "bubble.left.and.text.bubble.right", title: "No sessions yet", detail: "Press ⌘N to start a task, or paste a Slack thread link.")
                    }
                }
                .animation(M.snappy, value: all.map(\.id))
            }
        }
    }

    var filtered: [Session] {
        let q = query.v.lowercased()
        return model.boardSessions.filter { model.inFilter($0) && (q.isEmpty || "\($0.title) \($0.text) \($0.channel) \($0.issueKey) \($0.branch)".lowercased().contains(q)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - GitHub

struct PullsView: View {
    @Environment(AppModel.self) var model
    @AppStorage("pulls.tab") private var tab = "all"

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "GitHub", subtitle: model.pulls["login"].nonEmpty.map { "@\($0)" } ?? "", icon: "arrow.triangle.pull") {
                SlidingTabs(tabs: [
                    .init(id: "all", label: "All"),
                    .init(id: "attention", label: "Needs attention", count: attention.count, hot: true),
                    .init(id: "review", label: "Reviews", count: model.reviewPulls.count),
                    .init(id: "open", label: "Open", count: model.openPulls.count),
                    .init(id: "merged", label: "Merged"),
                ], selection: $tab)
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.refreshing.contains("pulls")) { Task { await model.load("pulls", refresh: true) } }
            }
            if let e = model.errors["pulls"], !e.isEmpty { ErrorBar(text: e) }
            if model.pulls.isNull {
                EmptyState(icon: "arrow.triangle.pull", title: model.loading.contains("pulls") ? "Loading from GitHub…" : "Nothing loaded")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if tab == "all" || tab == "attention" { group("Needs attention", attention, icon: AnyView(StatusIcon(kind: .attention, size: 13)), mine: true) }
                        if tab == "all" || tab == "review" { group("Review requested", model.reviewPulls, icon: AnyView(Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(T.yellow)), mine: false) }
                        if tab == "all" { group("Open", model.openPulls.filter { !$0.needsAttention }, icon: AnyView(StatusIcon(kind: .review, size: 13)), mine: true) }
                        if tab == "open" { group("Open", model.openPulls, icon: AnyView(StatusIcon(kind: .review, size: 13)), mine: true) }
                        if tab == "all" || tab == "merged" { group("Merged · last 14 days", model.mergedPulls, icon: AnyView(StatusIcon(kind: .done, size: 13)), mine: true) }
                        if empty { EmptyState(icon: "checkmark.circle", title: "Nothing here", detail: "No pull requests in this view.") }
                    }
                    .animation(M.snappy, value: tab)
                }
            }
        }
    }

    var attention: [PullRequest] { model.openPulls.filter(\.needsAttention) }

    var empty: Bool {
        switch tab {
        case "attention": return attention.isEmpty
        case "review": return model.reviewPulls.isEmpty
        case "open": return model.openPulls.isEmpty
        case "merged": return model.mergedPulls.isEmpty
        default: return model.openPulls.isEmpty && model.reviewPulls.isEmpty && model.mergedPulls.isEmpty
        }
    }

    @ViewBuilder
    func group(_ title: String, _ prs: [PullRequest], icon: AnyView, mine: Bool) -> some View {
        if !prs.isEmpty {
            Section {
                ForEach(prs) { PRRow(pr: $0, mine: mine) }
            } header: {
                GroupHeader(title: title, count: prs.count, icon: icon)
            }
        }
    }
}

struct ErrorBar: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.orange)
            Text(text).font(T.ui(12)).foregroundStyle(T.text2).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(T.orange.opacity(0.08))
    }
}

// MARK: - Linear

struct IssueTree: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    let showSubs: Bool
    @StateObject private var open = Box(true)

    var body: some View {
        VStack(spacing: 0) {
            IssueRow(issue: issue, expandable: showSubs && !issue.children.isEmpty, expanded: open.v) { withAnimation(M.snappy) { open.v.toggle() } }
            if showSubs && open.v && !issue.children.isEmpty {
                ForEach(issue.children) { child in
                    SubIssueRow(child: child, mine: model.issue(child.key))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

struct IssueRow: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    var expandable = false
    var expanded = true
    var toggle: () -> Void = {}
    @AppStorage("linear.props") private var propsRaw = LinearProps.defaults

    var body: some View {
        let props = csvSet(propsRaw)
        HoverRow(height: 40) {
            HStack(spacing: 10) {
                ZStack {
                    if expandable {
                        Button(action: toggle) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.text3).frame(width: 12, height: 20)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 12)
                if props.contains("priority") { PriorityIcon(priority: issue.priority).help(issue.priorityLabel) }
                if props.contains("id") { Text(issue.key).font(T.mono(11.5)).foregroundStyle(T.text3).frame(width: 74, alignment: .leading) }
                if props.contains("status") { StatusIcon(kind: issue.status, color: hexColor(issue.stateColor, fallback: issue.status.color)).help(issue.state) }
                if !issue.parentKey.isEmpty && model.issue(issue.parentKey) == nil {
                    Text(issue.parentTitle).font(T.ui(12.5)).foregroundStyle(T.text3).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
                }
                Text(issue.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                if !issue.children.isEmpty {
                    HStack(spacing: 4) {
                        Ring(done: issue.childrenDone, total: issue.children.count, size: 12)
                        Text(verbatim: "\(issue.childrenDone)/\(issue.children.count)").font(T.ui(11.5)).foregroundStyle(T.text3).monospacedDigit()
                    }
                    .padding(.horizontal, 6).frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(T.line, lineWidth: 1))
                    .help("\(issue.childrenDone) of \(issue.children.count) sub-issues done")
                }
                Spacer(minLength: 8)
                if props.contains("labels") { ForEach(issue.labels.prefix(2), id: \.0) { l in Chip(text: l.0, dot: hexColor(l.1)) } }
                ForEach(props.contains("prs") ? Array(model.pulls(forIssue: issue.key).prefix(2)) : []) { pr in
                    Button { openURL(pr.url) } label: {
                        HStack(spacing: 4) { Chip(text: "#\(pr.number)", icon: pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull", tint: pr.state == "MERGED" ? T.purple : nil, mono: true) }
                    }
                    .buttonStyle(.plain)
                    if pr.open { ChecksIcon(pr: pr).font(.system(size: 11.5)) }
                }
                if props.contains("project") && !issue.project.isEmpty { Chip(text: issue.project, icon: "cube") }
                if props.contains("cycle"), let c = issue.cycle { Chip(text: "Cycle \(c)", icon: "arrow.triangle.2.circlepath") }
                if props.contains("session") { IssueSessionButton(issue: issue) }
                if props.contains("assignee") { Avatar(name: issue.assignee.isEmpty ? "?" : issue.assignee, url: issue.assigneeAvatar, size: 18) }
                if props.contains("updated") { Text(Fmt.ago(issue.updatedAt)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 30, alignment: .trailing) }
            }
        }
        .onTapGesture(count: 2) { openURL(issue.url) }
        .contextMenu { IssueMenu(issue: issue) }
    }
}

struct SubIssueRow: View {
    @Environment(AppModel.self) var model
    let child: ChildIssue
    let mine: Issue?

    var body: some View {
        HoverRow(height: 34) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 12)
                // The tree line from the parent.
                ZStack(alignment: .leading) {
                    Rectangle().fill(T.line).frame(width: 1).frame(maxHeight: .infinity).offset(x: 6)
                    Rectangle().fill(T.line).frame(width: 8, height: 1).offset(x: 6)
                }
                .frame(width: 14, height: 34)
                PriorityIcon(priority: child.priority)
                Text(child.key).font(T.mono(11.5)).foregroundStyle(T.text3).frame(width: 74, alignment: .leading)
                StatusIcon(kind: child.status, color: hexColor(child.stateColor, fallback: child.status.color), size: 13).help(child.state)
                Text(child.title).font(T.ui(12.5)).foregroundStyle(child.status == .done || child.status == .canceled ? T.text3 : T.text2).lineLimit(1)
                    .strikethrough(child.status == .canceled, color: T.text3)
                Spacer(minLength: 8)
                ForEach(model.pulls(forIssue: child.key).prefix(1)) { pr in
                    Button { openURL(pr.url) } label: { Chip(text: "#\(pr.number)", icon: pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull", tint: pr.state == "MERGED" ? T.purple : nil, mono: true) }.buttonStyle(.plain)
                    if pr.open { ChecksIcon(pr: pr).font(.system(size: 11.5)) }
                }
                if let mine { IssueSessionButton(issue: mine) }
                Text(child.state).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 82, alignment: .trailing)
                Avatar(name: child.assignee.isEmpty ? "?" : child.assignee, url: child.assigneeAvatar, size: 18)
                    .opacity(child.assignee.isEmpty ? 0.35 : 1)
                    .help(child.assignee.isEmpty ? "Unassigned" : child.assignee)
                Color.clear.frame(width: 30)
            }
        }
        .background(T.raised.opacity(0.18))
        .onTapGesture(count: 2) { openURL(child.url) }
        .contextMenu {
            if let mine {
                IssueMenu(issue: mine)
            } else {
                Section {
                    Button { openURL(child.url) } label: { Label("Open in Linear", systemImage: "arrow.up.forward.app") }
                    if let pr = model.pulls(forIssue: child.key).first {
                        Button { openURL(pr.url) } label: { Label("Open #\(pr.number) on GitHub", systemImage: "arrow.triangle.pull") }
                    }
                }
                Section {
                    Button { copyToPasteboard(child.key) } label: { Label("Copy ID", systemImage: "number.square") }
                        .keyboardShortcut(".", modifiers: .command)
                    Button { copyToPasteboard(child.url) } label: { Label("Copy Link", systemImage: "link") }
                        .keyboardShortcut(",", modifiers: [.command, .shift])
                }
            }
        }
    }
}

struct IssueSessionButton: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    @StateObject private var busy = Box(false)

    var body: some View {
        if let s = model.session(forIssue: issue.key) {
            Button { model.open(s.id) } label: {
                HStack(spacing: 4) { SessionIcon(session: s, size: 11); Text("Session").font(T.ui(11, .medium)) }
                    .foregroundStyle(T.text2).padding(.horizontal, 6).frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(T.line, lineWidth: 1))
            }
            .buttonStyle(.plain).help("Open the Claude session working on \(issue.key)")
        } else if issue.active {
            Button {
                busy.v = true
                Task { await model.startIssue(issue); busy.v = false }
            } label: {
                HStack(spacing: 4) {
                    if busy.v { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold)) }
                    Text("Start").font(T.ui(11, .medium))
                }
                .foregroundStyle(T.accent).padding(.horizontal, 6).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(T.accentSoft))
            }
            .buttonStyle(.plain).disabled(busy.v).help("Start a Claude session on \(issue.key) in its own worktree")
        }
    }
}

struct IssueMenu: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    var body: some View {
        Section {
            Button { openURL(issue.url) } label: { Label("Open in Linear", systemImage: "arrow.up.forward.app") }
            if let s = model.session(forIssue: issue.key) {
                Button { model.open(s.id) } label: { Label("Open Session", systemImage: "bubble.left.and.text.bubble.right") }
            } else if issue.active {
                StartWithMenu(issue: issue)
            }
        }
        let prs = model.pulls(forIssue: issue.key)
        if !prs.isEmpty {
            Section {
                ForEach(prs.prefix(3)) { pr in
                    Button { openURL(pr.url) } label: { Label("Open #\(pr.number) on GitHub", systemImage: pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull") }
                }
            }
        }
        Section {
            Button { copyToPasteboard(issue.key) } label: { Label("Copy ID", systemImage: "number.square") }
                .keyboardShortcut(".", modifiers: .command)
            Button { copyToPasteboard(issue.branch) } label: { Label("Copy Branch Name", systemImage: "arrow.triangle.branch") }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button { copyToPasteboard(issue.url) } label: { Label("Copy Link", systemImage: "link") }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            Button { copyToPasteboard("\(issue.key) \(issue.title)") } label: { Label("Copy ID and Title", systemImage: "doc.on.doc") }
        }
    }
}
