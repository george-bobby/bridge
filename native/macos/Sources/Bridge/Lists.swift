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

    var body: some View {
        HoverRow(height: 38) {
            HStack(spacing: 10) {
                SessionIcon(session: session)
                Text(session.isTask ? "TASK" : "SLACK").font(T.mono(10, .semibold)).foregroundStyle(session.isTask ? T.accent : T.slack).frame(width: 38, alignment: .leading)
                if !session.issueKey.isEmpty { Text(session.issueKey).font(T.mono(11.5)).foregroundStyle(T.text3) }
                Text(session.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                Text(model.isAwaiting(session) ? session.askedFor : session.statusLine.isEmpty ? session.snippet : session.statusLine)
                    .font(T.ui(12.5)).foregroundStyle(model.isAwaiting(session) ? T.orange : T.text3).lineLimit(1)
                Spacer(minLength: 8)
                PortChips(servers: model.servers(for: session))
                if !session.prUrl.isEmpty {
                    Chip(text: "#\(session.prNumber)", icon: "arrow.triangle.pull", mono: true)
                }
                if session.cost > 0 { Text(Fmt.money(session.cost)).font(T.ui(11.5)).foregroundStyle(T.text3).monospacedDigit() }
                Text(Fmt.ago(session.updatedAt)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 34, alignment: .trailing)
            }
        }
        .onTapGesture { model.open(session.id) }
        .contextMenu { SessionMenu(session: session) }
    }
}

struct SessionMenu: View {
    @Environment(AppModel.self) var model
    let session: Session
    var body: some View {
        Button("Open") { model.open(session.id) }
        Menu("Move to") {
            ForEach(Column.allCases) { c in Button(c.label) { Task { await model.move(session.id, to: c) } } }
            Divider()
            Button("Automatic") { Task { await model.move(session.id, to: nil) } }
        }
        if !session.prUrl.isEmpty { Button("Open Pull Request") { openURL(session.prUrl) } }
        if !session.linearUrl.isEmpty { Button("Open in Linear") { openURL(session.linearUrl) } }
        if !session.permalink.isEmpty { Button("Open Slack Thread") { openURL(session.permalink) } }
        Button("Open in \(model.terminalName)") { Task { await model.terminal(session.id) } }
        if model.isLive(session) { Button("Stop") { Task { await model.stop(session.id) } } }
        Divider()
        Button("Delete", role: .destructive) { Task { await model.delete(session.id) } }.disabled(model.isLive(session))
    }
}

struct PRRow: View {
    @Environment(AppModel.self) var model
    let pr: PullRequest
    var mine = true

    var body: some View {
        HoverRow(height: 40) {
            HStack(spacing: 10) {
                PRStateIcon(pr: pr)
                Text(verbatim: "\(pr.repoName)#\(pr.number)").font(T.mono(11.5)).foregroundStyle(T.text3).frame(width: 108, alignment: .leading)
                Text(pr.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 8)
                PortChips(servers: pr.open ? model.servers(forBranch: pr.branch) : [])
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
        Button("Open on GitHub") { openURL(pr.url) }
        if let s = model.session(forPR: pr) { Button("Open Session") { model.open(s.id) } }
        Button("Copy Link") { copyToPasteboard(pr.url) }
        Button("Copy Branch Name") { copyToPasteboard(pr.branch) }
        if pr.open {
            Divider()
            if mine {
                if pr.failing { Button("Fix CI with Claude") { ask("Spawn a worker for \(pr.url) (branch \(pr.branch)): checks are failing. Check out the existing PR branch, find why CI fails, fix it and push to the same branch.") } }
                Button("Resolve Comments with Claude") { ask("Spawn a worker for \(pr.url) (branch \(pr.branch)): check out the existing PR branch and run /resolve on it.") }
                if pr.mergeable == "CONFLICTING" { Button("Fix Conflicts with Claude") { ask("Spawn a worker for \(pr.url) (branch \(pr.branch)): check out the PR branch, merge the base branch in, resolve the conflicts, verify, and push.") } }
            } else {
                Button("Review with Claude") { ask("Spawn a worker to review \(pr.url): run /review on it and report findings. Do not approve or merge.") }
            }
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
                IconButton(icon: "arrow.clockwise", help: "Refresh (⌘R)", spinning: !model.loading.isEmpty) { Task { await model.loadSources(refresh: true) } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(greeting).font(T.ui(22, .semibold)).foregroundStyle(T.text).padding(.top, 6)
                    stats
                    let needs = model.boardSessions.filter { model.column(of: $0) == .needs }
                    let live = model.boardSessions.filter { model.isLive($0) && model.column(of: $0) != .needs }
                    Card(title: "Needs you", count: needs.count + model.decisions.count, icon: AnyView(StatusIcon(kind: .attention, size: 13))) {
                        if needs.isEmpty && model.decisions.isEmpty { CardEmpty(text: "Nothing is waiting on you.") }
                        ForEach(model.decisions.prefix(4), id: \.self) { d in
                            HoverRow {
                                HStack(spacing: 10) {
                                    Image(systemName: d["kind"].string == "action" ? "hand.raised" : "questionmark.bubble").foregroundStyle(T.orange).frame(width: 14)
                                    Text(d["title"].nonEmpty ?? d["taskId"].string).font(T.ui(13, .medium)).lineLimit(1)
                                    Text(d["text"].string.replacingOccurrences(of: "\n", with: " ")).font(T.ui(12.5)).foregroundStyle(T.text3).lineLimit(1)
                                    Spacer()
                                }
                            }
                            .onTapGesture { model.route = .inbox }
                        }
                        ForEach(needs.prefix(6)) { SessionRow(session: $0) }
                    }
                    if !live.isEmpty {
                        Card(title: "Running", count: live.count, icon: AnyView(LiveIcon(size: 13))) { ForEach(live) { SessionRow(session: $0) } }
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
                                    }
                                }
                            }
                        }
                        Card(title: "Spend", count: nil, icon: AnyView(Image(systemName: "chart.bar").font(.system(size: 11)).foregroundStyle(T.text2))) {
                            SpendChart().frame(height: 130).padding(14)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
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
            Stat(value: "\(model.running.count)", label: "Running", tint: model.running.isEmpty ? nil : T.yellow) { model.route = .board }
            Stat(value: "\(model.needsCount)", label: "Need you", tint: model.needsCount > 0 ? T.orange : nil) { model.route = .inbox }
            Stat(value: model.pulls.isNull ? "–" : "\(model.openPulls.count)", label: "Open PRs", sub: "\(model.openPulls.filter(\.needsAttention).count) need attention") { model.route = .pulls }
            Stat(value: model.pulls.isNull ? "–" : "\(model.reviewPulls.count)", label: "Reviews for you") { model.route = .pulls }
            Stat(value: model.linear.isNull ? "–" : "\(model.issues.filter { $0.stateType == "started" }.count)", label: "Issues in progress") { model.route = .linear }
            Stat(value: Fmt.money(model.cost["today"].double), label: "Spent today", last: true) {}
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(T.raised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
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
                Text(label).font(T.ui(12)).foregroundStyle(T.text2)
                if !sub.isEmpty { Text(sub).font(T.ui(11)).foregroundStyle(T.text3) }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover.v ? T.hover.opacity(0.6) : .clear)
            .overlay(alignment: .trailing) { if !last { Rectangle().fill(T.line).frame(width: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.v = $0 }
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
                if let more { Button(more.0, action: more.1).buttonStyle(.plain).font(T.ui(12)).foregroundStyle(T.text3) }
            }
            .padding(.horizontal, 14).frame(height: 38)
            Hairline()
            VStack(spacing: 0) { content() }.padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.raised.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct CardEmpty: View {
    let text: String
    var body: some View { Text(text).font(T.ui(12.5)).foregroundStyle(T.text3).padding(.horizontal, 14).padding(.vertical, 10) }
}

struct CompactPR: View {
    @Environment(AppModel.self) var model
    let pr: PullRequest
    var body: some View {
        HoverRow(height: 34) {
            HStack(spacing: 9) {
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
        HoverRow(height: 34) {
            HStack(spacing: 9) {
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

struct SpendChart: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let series = model.cost["series"].array
        let maxV = max(series.map { $0["work"].double + $0["poll"].double }.max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.money(model.cost["total"].double)).font(T.ui(18, .semibold))
                Text(verbatim: "over \(model.cost["jobs"].int) jobs").font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            GeometryReader { g in
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, d in
                        let v = d["work"].double + d["poll"].double
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v > 0 ? T.accent : T.line)
                            .frame(height: max(2, g.size.height * v / maxV))
                            .help("\(Fmt.clock(d["day"].double)): \(Fmt.money(v))")
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

// MARK: - Board

struct BoardView: View {
    @Environment(AppModel.self) var model
    @StateObject private var query = Box("")

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Board", subtitle: "Cards follow their session until you drag them", icon: "rectangle.split.3x1") {
                LField(placeholder: "Filter", text: $query.v).frame(width: 200)
                IconButton(icon: "plus", help: "New task (⌘N)") { model.composeOpen = true }
            }
            GeometryReader { g in
                // Columns share the width, down to 210pt each; below that the board scrolls.
                let width = max(210, (g.size.width - 24 - 40) / 5)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Column.allCases) { c in BoardColumn(column: c, sessions: sessions(in: c)).frame(width: width) }
                    }
                    .padding(12)
                    .frame(height: g.size.height, alignment: .top)
                }
            }
        }
    }

    func sessions(in c: Column) -> [Session] {
        let q = query.v.lowercased()
        return model.boardSessions
            .filter { model.column(of: $0) == c }
            .filter { q.isEmpty || "\($0.title) \($0.text) \($0.channel) \($0.issueKey)".lowercased().contains(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

struct BoardColumn: View {
    @Environment(AppModel.self) var model
    let column: Column
    let sessions: [Session]
    @StateObject private var targeted = Box(false)
    @StateObject private var showAll = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatusIcon(kind: column.status, size: 13)
                Text(column.label).font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                Text(verbatim: "\(sessions.count)").font(T.ui(12)).foregroundStyle(T.text3)
                Spacer()
                if column == .backlog { IconButton(icon: "plus", help: "New task") { model.composeOpen = true } }
            }
            .padding(.horizontal, 8).frame(height: 34)
            ScrollView {
                LazyVStack(spacing: 6) {
                    let shown = column == .done && !showAll.v ? Array(sessions.prefix(30)) : sessions
                    ForEach(shown) { BoardCard(session: $0) }
                    if shown.count < sessions.count {
                        Button("Show \(sessions.count - shown.count) more") { showAll.v = true }.buttonStyle(.plain).font(T.ui(12)).foregroundStyle(T.text3).padding(6)
                    }
                    if sessions.isEmpty {
                        RoundedRectangle(cornerRadius: 8).stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(height: 64)
                            .overlay(Text("Drop here").font(T.ui(12)).foregroundStyle(T.text3))
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(targeted.v ? T.accentSoft : T.raised.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted.v ? T.accent.opacity(0.6) : Color.clear, lineWidth: 1))
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(session.isTask ? "TASK" : "SLACK").font(T.mono(10, .semibold)).foregroundStyle(session.isTask ? T.accent : T.slack)
                if !session.issueKey.isEmpty { Text(session.issueKey).font(T.mono(11)).foregroundStyle(T.text3) }
                Spacer()
                if !session.pinned.isEmpty {
                    Button { Task { await model.move(session.id, to: nil) } } label: {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(T.text3)
                    }
                    .buttonStyle(.plain).help("You placed this card. Click to let it follow its session again.")
                }
                Text(Fmt.ago(session.updatedAt)).font(T.ui(11)).foregroundStyle(T.text3)
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
            if !session.prUrl.isEmpty || !ports.isEmpty || session.cost > 0 || !session.taskStatus.isEmpty {
                HStack(spacing: 5) {
                    if let label = statusLabels[session.taskStatus], !model.isLive(session) { Chip(text: label) }
                    if !session.prUrl.isEmpty {
                        Button { openURL(session.prUrl) } label: { Chip(text: "#\(session.prNumber)", icon: "arrow.triangle.pull", mono: true) }.buttonStyle(.plain)
                    }
                    if let pr { ChecksIcon(pr: pr).font(.system(size: 11.5)) }
                    PortChips(servers: ports)
                    Spacer()
                    if session.cost > 0 { Text(Fmt.money(session.cost)).font(T.ui(11)).foregroundStyle(T.text3).monospacedDigit() }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover.v ? T.hover : T.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.isAwaiting(session) ? T.orange.opacity(0.45) : T.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onHover { hover.v = $0 }
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
            PageHeader(title: "Sessions", subtitle: "\(model.boardSessions.count)", icon: "bubble.left.and.text.bubble.right") {
                LField(placeholder: "Filter", text: $query.v).frame(width: 220)
                IconButton(icon: "plus", help: "New task (⌘N)") { model.composeOpen = true }
            }
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if let o = model.orchestrator {
                        HoverRow(height: 40) {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles").foregroundStyle(T.purple).frame(width: 14)
                                Text("Orchestrator").font(T.ui(13, .medium))
                                Text("Writes briefs, spawns and watches workers").font(T.ui(12.5)).foregroundStyle(T.text3)
                                Spacer()
                                if model.isLive(o) { LiveIcon(size: 12) }
                            }
                        }
                        .onTapGesture { model.open("orchestrator") }
                        Hairline()
                    }
                    ForEach([Column.needs, .doing, .review, .backlog, .done]) { c in
                        let rows = filtered.filter { model.column(of: $0) == c }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { SessionRow(session: $0) }
                            } header: {
                                GroupHeader(title: c.label, count: rows.count, icon: AnyView(StatusIcon(kind: c.status, size: 13)))
                            }
                        }
                    }
                    if model.boardSessions.isEmpty {
                        EmptyState(icon: "bubble.left.and.text.bubble.right", title: "No sessions yet", detail: "Press ⌘N to start a task, or paste a Slack thread link.")
                    }
                }
            }
        }
    }

    var filtered: [Session] {
        let q = query.v.lowercased()
        return model.boardSessions.filter { q.isEmpty || "\($0.title) \($0.text) \($0.channel) \($0.issueKey) \($0.branch)".lowercased().contains(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Pull requests

struct PullsView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Pull requests", subtitle: model.pulls["login"].nonEmpty.map { "as \($0)" } ?? "", icon: "arrow.triangle.pull") {
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.loading.contains("pulls")) { Task { await model.load("pulls", refresh: true) } }
            }
            if let e = model.errors["pulls"], !e.isEmpty { ErrorBar(text: e) }
            if model.pulls.isNull {
                EmptyState(icon: "arrow.triangle.pull", title: model.loading.contains("pulls") ? "Loading from GitHub…" : "Nothing loaded")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        group("Needs attention", model.openPulls.filter(\.needsAttention), icon: AnyView(StatusIcon(kind: .attention, size: 13)), mine: true)
                        group("Review requested", model.reviewPulls, icon: AnyView(Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(T.yellow)), mine: false)
                        group("Open", model.openPulls.filter { !$0.needsAttention }, icon: AnyView(StatusIcon(kind: .review, size: 13)), mine: true)
                        group("Merged · last 14 days", model.mergedPulls, icon: AnyView(StatusIcon(kind: .done, size: 13)), mine: true)
                    }
                }
            }
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

struct LinearView: View {
    @Environment(AppModel.self) var model
    @AppStorage("linear.subissues") private var showSubs = true
    @AppStorage("linear.done") private var showDone = false
    @StateObject private var collapsed = Box(Set<String>())

    static let order: [StatusKind] = [.progress, .review, .todo, .triage, .backlog, .done, .canceled]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "My issues", subtitle: model.linear["viewer"].nonEmpty ?? "", icon: "circle.lefthalf.filled") {
                Toggle("Sub-issues", isOn: $showSubs).toggleStyle(.switch).controlSize(.mini).font(T.ui(12))
                Toggle("Done", isOn: $showDone).toggleStyle(.switch).controlSize(.mini).font(T.ui(12))
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.loading.contains("linear")) { Task { await model.load("linear", refresh: true) } }
            }
            if let e = model.errors["linear"], !e.isEmpty { ErrorBar(text: e) }
            if model.linear.isNull {
                EmptyState(icon: "circle.lefthalf.filled", title: model.loading.contains("linear") ? "Loading from Linear…" : "Nothing loaded")
            } else if !model.linear["configured"].bool {
                EmptyState(icon: "key", title: "Linear isn't connected", detail: "Add LINEAR_API_KEY to .env and restart the server.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.0) { group in
                            Section {
                                if !collapsed.v.contains(group.0) {
                                    ForEach(group.2) { IssueTree(issue: $0, showSubs: showSubs) }
                                }
                            } header: {
                                GroupHeader(title: group.0, count: group.2.count, icon: AnyView(StatusIcon(kind: group.1, color: hexColor(group.2.first?.stateColor ?? "", fallback: group.1.color), size: 13))) {
                                    Image(systemName: collapsed.v.contains(group.0) ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.text3)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if collapsed.v.contains(group.0) { collapsed.v.remove(group.0) } else { collapsed.v.insert(group.0) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Issues grouped by workflow state, in Linear's order. A sub-issue whose
    /// parent is also yours is shown under that parent rather than twice.
    var groups: [(String, StatusKind, [Issue])] {
        let mine = Set(model.issues.map(\.key))
        let visible = model.issues.filter { (showDone || $0.active) && !(showSubs && mine.contains($0.parentKey)) }
        var byState: [String: [Issue]] = [:]
        for i in visible { byState[i.state, default: []].append(i) }
        return byState.map { ($0.key, $0.value.first!.status, $0.value.sorted { ($0.priority == 0 ? 9 : $0.priority, -$0.updatedAt) < ($1.priority == 0 ? 9 : $1.priority, -$1.updatedAt) }) }
            .sorted { (Self.order.firstIndex(of: $0.1) ?? 9, -($0.2.first?.statePos ?? 0)) < (Self.order.firstIndex(of: $1.1) ?? 9, -($1.2.first?.statePos ?? 0)) }
    }
}

struct IssueTree: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    let showSubs: Bool
    @StateObject private var open = Box(true)

    var body: some View {
        VStack(spacing: 0) {
            IssueRow(issue: issue, expandable: showSubs && !issue.children.isEmpty, expanded: open.v) { open.v.toggle() }
            if showSubs && open.v && !issue.children.isEmpty {
                ForEach(issue.children) { child in SubIssueRow(child: child, mine: model.issues.first { $0.key == child.key }) }
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

    var body: some View {
        HoverRow(height: 40) {
            HStack(spacing: 10) {
                ZStack {
                    if expandable {
                        Button(action: toggle) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.text3).frame(width: 12, height: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 12)
                PriorityIcon(priority: issue.priority).help(issue.priorityLabel)
                Text(issue.key).font(T.mono(11.5)).foregroundStyle(T.text3).frame(width: 74, alignment: .leading)
                StatusIcon(kind: issue.status, color: hexColor(issue.stateColor, fallback: issue.status.color)).help(issue.state)
                if !issue.parentKey.isEmpty && !model.issues.contains(where: { $0.key == issue.parentKey }) {
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
                ForEach(issue.labels.prefix(2), id: \.0) { l in Chip(text: l.0, dot: hexColor(l.1)) }
                ForEach(model.pulls(forIssue: issue.key).prefix(2)) { pr in
                    Button { openURL(pr.url) } label: {
                        HStack(spacing: 4) { Chip(text: "#\(pr.number)", icon: pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull", tint: pr.state == "MERGED" ? T.purple : nil, mono: true) }
                    }
                    .buttonStyle(.plain)
                    if pr.open { ChecksIcon(pr: pr).font(.system(size: 11.5)) }
                }
                if !issue.project.isEmpty { Chip(text: issue.project, icon: "cube") }
                if let c = issue.cycle { Chip(text: "Cycle \(c)", icon: "arrow.triangle.2.circlepath") }
                IssueSessionButton(issue: issue)
                Avatar(name: issue.assignee.isEmpty ? "?" : issue.assignee, url: issue.assigneeAvatar, size: 18)
                Text(Fmt.ago(issue.updatedAt)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 30, alignment: .trailing)
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
            Button("Open in Linear") { openURL(child.url) }
            Button("Copy ID") { copyToPasteboard(child.key) }
            if let mine { IssueMenu(issue: mine) }
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
            .buttonStyle(.plain).disabled(busy.v).help("Start a Claude worker on \(issue.key) in its own worktree")
        }
    }
}

struct IssueMenu: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    var body: some View {
        Button("Open in Linear") { openURL(issue.url) }
        if let s = model.session(forIssue: issue.key) { Button("Open Session") { model.open(s.id) } }
        else if issue.active { Button("Start Session with Claude") { Task { await model.startIssue(issue) } } }
        Divider()
        Button("Copy ID") { copyToPasteboard(issue.key) }
        Button("Copy Branch Name") { copyToPasteboard(issue.branch) }
        Button("Copy Link") { copyToPasteboard(issue.url) }
    }
}
