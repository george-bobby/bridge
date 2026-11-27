import AppKit
import SwiftUI

// MARK: - Details panel
//
// The session's properties, links, PR activity and report. One pane: a
// trailing column. Panes side by side: each pane toggles its own, as a column
// when the pane is wide and a drawer docked under it (`DetailsDrawer`)
// otherwise.

extension AppModel {
    /// The Linear issue this session is about, when the feed has it: its
    /// link, branch, title or brief names the key.
    func linkedIssue(_ s: Session) -> Issue? { issue(s.issueKey) }

    func issue(_ key: String) -> Issue? {
        _ = linear // observe the feed: the index itself isn't tracked
        return key.isEmpty ? nil : issuesByKey[key]
    }

    /// What the Status row shows: a manual move, then what's live, then
    /// Linear's workflow state, then Bridge's own guess.
    func statusDisplay(_ s: Session) -> (kind: StatusKind, color: Color?, label: String, source: String) {
        let col = column(of: s)
        if !s.boardPin.isEmpty { return (col.status, nil, col.label, "Manual") }
        if isAwaiting(s) || col == .needs || isLive(s) { return (col.status, nil, col.label, "") }
        if let i = linkedIssue(s) { return (i.status, hexColor(i.stateColor, fallback: i.status.color), i.state, "Linear") }
        return (col.status, nil, col.label, "")
    }

    func loadPRActivity(_ runId: String, url: String, refresh: Bool = false) async {
        guard !url.isEmpty else { return }
        if let out = try? await API.get("/api/runs/\(API.q(runId))/pr" + (refresh ? "?refresh=1" : "")), !out["pr"].isNull {
            withAnimation(M.snappy) { prActivity[url] = out["pr"] }
        }
    }
}

struct PropertiesPanel: View {
    @Environment(AppModel.self) var model
    let id: String
    var compact = false

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, compact ? 18 : 20)
                .padding(.vertical, compact ? 14 : 20)
        }
        .scrollIndicators(.never)
        .background(T.panel)
    }

    @ViewBuilder var content: some View {
        let s = model.sessions.first { $0.id == id }
        if compact {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 28, alignment: .top)], alignment: .leading, spacing: 22) {
                sections(s)
            }
        } else {
            VStack(alignment: .leading, spacing: 26) { sections(s) }
        }
    }

    @ViewBuilder func sections(_ s: Session?) -> some View {
        if let s, s.isOrchestrator { OrchestratorPanel(session: s) }
        if let s, !s.isOrchestrator {
            PropSection(title: "Properties") { PropertyRows(session: s) }
            PropSection(title: "Links") { LinkRows(session: s) }
            if !s.prUrl.isEmpty { PRActivitySection(runId: id, url: s.prUrl) }
        }
        PlanSection(runId: id)
        let parsed = model.taskData(id)["parsed"]
        if !parsed.isNull && (!parsed["tldr"].string.isEmpty || !parsed["questions"].array.isEmpty || !parsed["actions"].array.isEmpty) {
            PropSection(title: "Report") { ReportView(parsed: parsed) }
        }
        if let s { NextStep(session: s) }
    }
}

// MARK: orchestrator

/// The orchestrator's column: where it works, its workers, quick actions.
struct OrchestratorPanel: View {
    @Environment(AppModel.self) var model
    let session: Session

    var body: some View {
        let p = model.project(session.project) ?? model.projects.first
        let workers = model.boardSessions.filter { p == nil || $0.project == p!.id }
        let live = workers.filter(model.isLive)
        PropSection(title: "Orchestrator") {
            VStack(alignment: .leading, spacing: 2) {
                if let p {
                    PropRow(label: "Project") { Text(p.name).font(T.ui(12.5)) }
                    if !p.path.isEmpty { PropRow(label: "Repo") { CopyValue(text: p.path, shown: (p.path as NSString).lastPathComponent, what: "Path", reveal: true) } }
                }
                PropRow(label: "Sessions") {
                    Text(verbatim: live.isEmpty ? "\(workers.count)" : "\(live.count) running · \(workers.count)").font(T.ui(12.5)).monospacedDigit()
                }
            }
        }
        PropSection(title: "Actions") {
            VStack(alignment: .leading, spacing: 6) {
                Button { Task { await model.brief(session.id) } } label: { Label("Brief me", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .buttonStyle(LButton())
                Button { model.compose(in: p?.id) } label: { Label("New task", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(LButton())
            }
        }
        if !workers.isEmpty {
            PropSection(title: "Recent sessions") {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(workers.prefix(8))) { w in WorkerRow(session: w) }
                }
            }
        }
    }
}

private struct WorkerRow: View {
    @Environment(AppModel.self) var model
    let session: Session
    @StateObject private var hover = Box(false)
    var body: some View {
        Button { model.open(session.id) } label: {
            HStack(spacing: 8) {
                SessionIcon(session: session, size: 13)
                Text(session.title).font(T.ui(12.5)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 4)
                if model.isLive(session) { LiveIcon(size: 10) }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover.v ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .hoverBox(hover)
    }
}

// MARK: properties

struct PropertyRows: View {
    @Environment(AppModel.self) var model
    let session: Session

    var body: some View {
        let s = session
        let task = model.taskData(session.id)
        VStack(alignment: .leading, spacing: 2) {
            PropRow(label: "Status") { StatusMenu(session: s) }
            PropRow(label: "Project") {
                Menu {
                    ForEach(model.projects) { p in
                        Button { Task { await model.setProject(s.id, p.id) } } label: { Label(p.name, systemImage: p.id == s.project ? "checkmark" : "folder") }
                    }
                } label: { MenuLabel(text: model.project(s.project)?.name ?? "None") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if !s.branch.isEmpty {
                PropRow(label: "Branch") { CopyValue(text: s.branch, what: "Branch name") }
            }
            if let wt = task["meta"]["worktree"].nonEmpty {
                PropRow(label: "Worktree") {
                    CopyValue(text: wt, shown: (wt as NSString).lastPathComponent, what: "Worktree path", reveal: true)
                }
                let w = task["worktree"]
                if !w.isNull && (w["dirty"].bool || w["unpushed"].int > 0) {
                    PropRow(label: "Changes") {
                        Button { withAnimation(M.snappy) { model.showTab("changes", of: s.id) } } label: {
                            Text([w["dirty"].bool ? "\(w["dirtyFiles"].int) uncommitted" : "", w["unpushed"].int > 0 ? "\(w["unpushed"].int) unpushed" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(T.ui(12.5)).foregroundStyle(T.orange)
                        }
                        .buttonStyle(.plain).help("Open the Changes tab")
                    }
                }
            }
        }
    }
}

struct StatusMenu: View {
    @Environment(AppModel.self) var model
    let session: Session

    var body: some View {
        let s = session
        let d = model.statusDisplay(s)
        let issue = model.linkedIssue(s)
        // Menu labels drop shapes, so the icon and the source tag sit outside.
        HStack(spacing: 6) {
        Group {
            if model.isLive(s) && !model.isAwaiting(s) { LiveIcon(size: 12) } else { StatusIcon(kind: d.kind, color: d.color, size: 12) }
        }
        .frame(width: 14)
        Menu {
            ForEach(Column.allCases) { c in
                Button { Task { await model.move(s.id, to: c) } } label: {
                    Label(c.label, systemImage: s.boardPin == c.rawValue ? "checkmark" : c.symbol)
                }
            }
            Divider()
            Button { Task { await model.move(s.id, to: nil) } } label: {
                Label(issue == nil ? "Automatic" : "Follow Linear (\(issue!.state))", systemImage: s.boardPin.isEmpty ? "checkmark" : "wand.and.stars")
            }
        } label: { MenuLabel(text: d.label) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        if !d.source.isEmpty {
            Text(d.source).font(T.ui(10.5, .medium)).foregroundStyle(T.text3)
                .padding(.horizontal, 5).frame(height: 17)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(T.line, lineWidth: 1))
        }
        }
        .help(d.source == "Linear" ? "From Linear; pick a status to override it here" : d.source == "Manual" ? "Set by hand; Automatic goes back to following the work" : "Pick a status to pin it")
    }
}

struct MenuLabel: View {
    let text: String
    var body: some View {
        Text(text).font(T.ui(12.5)).foregroundStyle(T.text)
    }
}

/// A mono value that copies itself on click; the copy glyph shows on hover.
struct CopyValue: View {
    @Environment(AppModel.self) var model
    let text: String
    var shown: String? = nil
    let what: String
    var reveal = false
    @StateObject private var hover = Box(false)
    @StateObject private var copied = Box(false)

    var body: some View {
        HStack(spacing: 4) {
            Button { copy() } label: {
                HStack(spacing: 6) {
                    Text(shown ?? text).font(T.mono(11)).foregroundStyle(hover.v ? T.text : T.text2).lineLimit(1).truncationMode(.middle)
                    Image(systemName: copied.v ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied.v ? T.green : T.text3)
                        .opacity(hover.v || copied.v ? 1 : 0)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .help("\(text)\nClick to copy")
            .layoutPriority(1)
            if reveal {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: text)]) } label: {
                    Image(systemName: "folder").font(.system(size: 10, weight: .medium)).foregroundStyle(T.text3)
                }
                .buttonStyle(.plain).help("Show in Finder").opacity(hover.v ? 1 : 0)
            }
        }
        .hoverBox(hover)
    }

    func copy() {
        copyToPasteboard(text)
        withAnimation(M.pop) { copied.v = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(M.hover) { copied.v = false } }
    }
}

// MARK: links

struct LinkRows: View {
    @Environment(AppModel.self) var model
    let session: Session

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 4) {
            if !s.prUrl.isEmpty {
                let pr = model.pr(for: s.prUrl)
                LinkRow(icon: "arrow.triangle.pull", tint: pr.map(prTint) ?? T.text3, title: "Pull request", detail: "#\(s.prNumber)", url: s.prUrl)
                PreviewRows(session: s)
            }
            if let url = linearURL {
                let issue = model.linkedIssue(s)
                LinkRow(icon: "circle.lefthalf.filled", tint: issue.map { hexColor($0.stateColor, fallback: $0.status.color) } ?? T.text3, title: "Linear issue", detail: s.issueKey, url: url)
            }
            if !s.permalink.isEmpty {
                LinkRow(icon: "number", tint: T.slack, title: "Slack thread", detail: s.channel, url: s.permalink)
            }
            ForEach(model.servers(for: s)) { sv in
                ForEach(sv.ports, id: \.self) { p in
                    LinkRow(icon: "play.circle", tint: T.green, title: "localhost:\(p)", detail: sv.command, url: "http://localhost:\(p)")
                }
            }
            if s.prUrl.isEmpty && linearURL == nil && s.permalink.isEmpty {
                Text("No PR, issue or thread yet").font(T.ui(12)).foregroundStyle(T.text3).frame(height: 24)
            }
        }
    }

    var linearURL: String? {
        if !session.linearUrl.isEmpty { return session.linearUrl }
        return model.linkedIssue(session)?.url
    }

    func prTint(_ pr: PullRequest) -> Color {
        pr.state == "MERGED" ? T.purple : pr.state == "CLOSED" ? T.red : pr.draft ? T.text3 : T.green
    }
}

/// A link: click opens it, the trailing button copies the URL.
struct LinkRow<Trailing: View>: View {
    let icon: String
    var tint: Color = T.text3
    let title: String
    var detail: String = ""
    let url: String
    /// What a click does instead of opening the URL (a preview opens in Bridge's browser).
    var open: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    @StateObject private var hover = Box(false)
    @StateObject private var copied = Box(false)

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(tint).frame(width: 14)
            Text(title).font(T.ui(12.5)).foregroundStyle(hover.v ? T.text : T.text2).lineLimit(1).layoutPriority(1)
            if !detail.isEmpty { Text(detail).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 4)
            trailing()
            Button { copy() } label: {
                Image(systemName: copied.v ? "checkmark" : "link").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(copied.v ? T.green : T.text2)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(T.selected.opacity(hover.v ? 1 : 0)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(Pressable(scale: 0.88))
            .opacity(hover.v || copied.v ? 1 : 0)
            .help("Copy link")
        }
        .padding(.leading, 8).padding(.trailing, 4).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.v ? T.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if let open { open() } else { openURL(url) } }
        .hoverBox(hover)
        .help(url)
        .padding(.horizontal, -8)
    }

    func copy() {
        copyToPasteboard(url)
        withAnimation(M.pop) { copied.v = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(M.hover) { copied.v = false } }
    }
}

extension LinkRow where Trailing == EmptyView {
    init(icon: String, tint: Color = T.text3, title: String, detail: String = "", url: String) {
        self.init(icon: icon, tint: tint, title: title, detail: detail, url: url) { EmptyView() }
    }
}

// MARK: PR activity

struct PRActivitySection: View {
    @Environment(AppModel.self) var model
    let runId: String
    let url: String
    @StateObject private var loading = Box(false)

    var body: some View {
        let pr = model.prActivity[url]
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Pull request").font(T.ui(11.5, .semibold)).foregroundStyle(T.text3)
                Spacer()
                Button { Task { await reload(true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.text3)
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: loading.v)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Pressable(scale: 0.88)).help("Refresh from GitHub")
            }
            if let pr {
                PRSummary(pr: pr)
                ChecksSummary(checks: pr["checks"].array)
                if !pr["reviewers"].array.isEmpty { Reviewers(reviewers: pr["reviewers"].array) }
                PRConversation(items: pr["conversation"].array)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(T.raised).frame(height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(T.raised).frame(width: 160, height: 12)
                }
                .shimmer(loading.v)
            }
        }
        .task(id: url) { await reload(false) }
    }

    func reload(_ refresh: Bool) async {
        loading.v = true
        await model.loadPRActivity(runId, url: url, refresh: refresh)
        loading.v = false
    }
}

struct PRSummary: View {
    let pr: JSON

    var body: some View {
        let (label, tint) = state
        VStack(alignment: .leading, spacing: 6) {
            Text(pr["title"].string).font(T.ui(12.5, .medium)).foregroundStyle(T.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Chip(text: label, icon: label == "Merged" ? "arrow.triangle.merge" : "arrow.triangle.pull", tint: tint)
                if pr["mergeable"].string == "CONFLICTING" { Chip(text: "Conflicts", icon: "exclamationmark.triangle", tint: T.orange) }
                Text(verbatim: "+\(pr["additions"].int)").font(T.mono(11)).foregroundStyle(T.green)
                Text(verbatim: "−\(pr["deletions"].int)").font(T.mono(11)).foregroundStyle(T.red)
                Spacer(minLength: 0)
            }
        }
    }

    var state: (String, Color) {
        switch pr["state"].string {
        case "MERGED": return ("Merged", T.purple)
        case "CLOSED": return ("Closed", T.red)
        default: return pr["draft"].bool ? ("Draft", T.text3) : ("Open", T.green)
        }
    }
}

struct ChecksSummary: View {
    let checks: [JSON]
    @StateObject private var open = Box<Bool?>(nil)
    @StateObject private var hover = Box(false)

    var body: some View {
        let failed = checks.filter { $0["state"].string == "fail" }
        let pending = checks.filter { $0["state"].string == "pending" }
        let passed = checks.count - failed.count - pending.count
        let expanded = open.v ?? !failed.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                headIcon(failed: failed.count, pending: pending.count)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(failed: failed.count, pending: pending.count)).font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                    Text(counts(failed: failed.count, pending: pending.count, passed: passed)).font(T.ui(11)).foregroundStyle(T.text3)
                }
                Spacer(minLength: 4)
                if !checks.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 10).frame(height: 44)
            .contentShape(Rectangle())
            .onTapGesture { if !checks.isEmpty { withAnimation(M.snappy) { open.v = !expanded } } }
            if expanded && !checks.isEmpty {
                Rectangle().fill(T.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((failed + pending + checks.filter { $0["state"].string == "pass" }).enumerated()), id: \.offset) { _, c in
                        CheckRow(check: c)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(T.raised.opacity(hover.v ? 0.9 : 0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(failed.isEmpty ? T.line : T.red.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .hoverBox(hover)
    }

    @ViewBuilder func headIcon(failed: Int, pending: Int) -> some View {
        let (icon, tint): (String, Color) = checks.isEmpty ? ("circle.dotted", T.text3) : failed > 0 ? ("xmark.circle.fill", T.red) : pending > 0 ? ("clock.fill", T.yellow) : ("checkmark.circle.fill", T.green)
        Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
    }

    func headline(failed: Int, pending: Int) -> String {
        checks.isEmpty ? "No checks" : failed > 0 ? (failed == 1 ? "1 check failing" : "\(failed) checks failing") : pending > 0 ? "Checks running" : "All checks passed"
    }

    func counts(failed: Int, pending: Int, passed: Int) -> String {
        [failed > 0 ? "\(failed) failed" : "", pending > 0 ? "\(pending) running" : "", passed > 0 ? "\(passed) passed" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct CheckRow: View {
    let check: JSON
    @StateObject private var hover = Box(false)

    var body: some View {
        let st = check["state"].string
        HStack(spacing: 8) {
            Image(systemName: st == "fail" ? "xmark.circle.fill" : st == "pending" ? "clock" : "checkmark.circle")
                .font(.system(size: 11)).foregroundStyle(st == "fail" ? T.red : st == "pending" ? T.yellow : T.text3)
                .frame(width: 14)
            Text(check["name"].string).font(T.ui(12)).foregroundStyle(st == "fail" ? T.text : T.text2).lineLimit(1)
            if let w = check["workflow"].nonEmpty { Text(w).font(T.ui(11)).foregroundStyle(T.text3).lineLimit(1) }
            Spacer(minLength: 4)
            if !check["url"].string.isEmpty {
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3).opacity(hover.v ? 1 : 0)
            }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(hover.v ? T.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture { openURL(check["url"].string) }
        .hoverBox(hover)
    }
}

struct Reviewers: View {
    let reviewers: [JSON]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(reviewers.enumerated()), id: \.offset) { _, r in
                let (label, icon, tint) = verdict(r["state"].string)
                HStack(spacing: 8) {
                    Avatar(name: r["author"].string.replacingOccurrences(of: "-", with: " "), size: 18)
                    Text(r["author"].string).font(T.ui(12, .medium)).foregroundStyle(T.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    Label(label, systemImage: icon).font(T.ui(11.5, .medium)).foregroundStyle(tint).labelStyle(.titleAndIcon)
                }
            }
        }
    }

    func verdict(_ s: String) -> (String, String, Color) {
        switch s {
        case "APPROVED": return ("Approved", "checkmark", T.green)
        case "CHANGES_REQUESTED": return ("Changes requested", "arrow.uturn.backward", T.red)
        case "DISMISSED": return ("Dismissed", "minus", T.text3)
        default: return ("Commented", "bubble.left", T.text3)
        }
    }
}

struct PRConversation: View {
    let items: [JSON]
    @StateObject private var all = Box(false)

    var body: some View {
        let shown = all.v ? items : Array(items.suffix(3))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(items.isEmpty ? "No comments yet" : "Activity").font(T.ui(11.5, .medium)).foregroundStyle(T.text3)
                Spacer()
                if items.count > 3 {
                    Button(all.v ? "Show latest" : "Show all \(items.count)") { withAnimation(M.snappy) { all.v.toggle() } }
                        .buttonStyle(.plain).font(T.ui(11.5)).foregroundStyle(T.text2)
                }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, c in CommentCard(item: c) }
        }
    }
}

struct CommentCard: View {
    @Environment(AppModel.self) var model
    let item: JSON
    @StateObject private var hover = Box(false)
    @StateObject private var expanded = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let path = item["path"].nonEmpty {
                Text(verbatim: item["line"].int > 0 ? "\(path):\(item["line"].int)" : path)
                    .font(T.mono(10.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.head)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(T.selected))
            }
            Text(inline(item["body"].string)).font(T.ui(12)).foregroundStyle(T.text2)
                .lineLimit(expanded.v ? nil : 4).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .onTapGesture { withAnimation(M.snappy) { expanded.v.toggle() } }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(T.raised.opacity(hover.v ? 0.9 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.lineSoft, lineWidth: 1))
        .hoverBox(hover)
    }

    var header: some View {
        let who = item["author"].string
        let (verb, tint) = verbOf
        return HStack(spacing: 6) {
            Avatar(name: who.replacingOccurrences(of: "-", with: " "), size: 16)
            Text(who).font(T.ui(11.5, .semibold)).foregroundStyle(T.text).lineLimit(1)
            Text(verb).font(T.ui(11.5)).foregroundStyle(tint).lineLimit(1)
            Text(Fmt.ago(Fmt.iso(item["at"].string))).font(T.ui(11)).foregroundStyle(T.text3)
            Spacer(minLength: 2)
            HStack(spacing: 0) {
                MiniButton(icon: "text.quote", help: "Add to chat") {
                    model.quoteIntoComposer("\(who) on the PR\(item["path"].nonEmpty.map { " (\($0))" } ?? ""):\n\(item["body"].string)")
                }
                if !item["url"].string.isEmpty { MiniButton(icon: "arrow.up.right", help: "Open on GitHub") { openURL(item["url"].string) } }
            }
            .opacity(hover.v ? 1 : 0)
        }
    }

    var verbOf: (String, Color) {
        switch (item["kind"].string, item["state"].string) {
        case ("review", "APPROVED"): return ("approved", T.green)
        case ("review", "CHANGES_REQUESTED"): return ("requested changes", T.red)
        case ("review", _): return ("reviewed", T.text3)
        case ("inline", _): return ("on the code", T.text3)
        default: return ("commented", T.text3)
        }
    }
}

struct MiniButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View { IconButton(icon: icon, help: help, size: B.mini, action: action) }
}

// MARK: report

/// The worker's report: the TL;DR as Markdown, folded to a few lines, with
/// open questions and action requests as callouts under it.
struct ReportView: View {
    let parsed: JSON
    @StateObject private var more = Box(false)
    @StateObject private var full = Box<CGFloat>(0)
    private let folded: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let tldr = parsed["tldr"].string
            if !tldr.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownText(text: tldr, size: 12.5, color: NT.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full.v = $0 }
                        .frame(maxHeight: more.v || full.v <= folded + 8 ? nil : folded, alignment: .top)
                        .clipped()
                        .mask(fade)
                    if full.v > folded + 8 {
                        Button(more.v ? "Show less" : "Show more") { withAnimation(M.snappy) { more.v.toggle() } }
                            .buttonStyle(.plain).font(T.ui(11.5, .medium)).foregroundStyle(T.accent)
                    }
                }
            }
            ForEach(Array(parsed["questions"].array.enumerated()), id: \.offset) { _, q in
                Callout(icon: "questionmark", title: "Open question", text: q.string, tint: T.orange)
            }
            ForEach(Array(parsed["actions"].array.enumerated()), id: \.offset) { _, a in
                Callout(icon: "hand.raised.fill", title: "Needs you", text: a.string, tint: T.yellow)
            }
        }
    }

    var fade: some View {
        let folding = !more.v && full.v > folded + 8
        return LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: folding ? 0.6 : 1), .init(color: folding ? .clear : .black, location: 1)], startPoint: .top, endPoint: .bottom)
    }
}

/// An open question or an ask from the report: a quiet card with a colored
/// tag, the text selectable, and Reply to answer it from the composer.
struct Callout: View {
    @Environment(AppModel.self) var model
    let icon: String
    let title: String
    let text: String
    let tint: Color
    @StateObject private var hover = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(tint.opacity(0.14)))
                Text(title).font(T.ui(11.5, .semibold)).foregroundStyle(T.text)
                Spacer(minLength: 0)
            }
            RichText(markdown: text, size: 12.5, color: NT.text2)
            HStack(spacing: 6) {
                Button { model.quoteIntoComposer(text) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left").font(T.ui(11.5, .medium)) }
                    .buttonStyle(LButton())
                    .help("Quote this in the composer to answer it")
                Button { copyToPasteboard(text); model.say("Copied") } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(LButton(square: true))
                    .help("Copy")
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover.v ? T.hover : T.raised.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.line, lineWidth: 1))
        .hoverBox(hover)
    }
}

// MARK: next step

struct NextStep: View {
    @Environment(AppModel.self) var model
    let session: Session

    var body: some View {
        let s = session
        let run = !s.isTask && !s.worked && !s.isOrchestrator
        let worker = s.isTask && !model.isLive(s) && s.taskStatus != "cleaned" && s.taskStatus != "imported"
        if run || worker {
            PropSection(title: "Next step") {
                VStack(alignment: .leading, spacing: 6) {
                    if run {
                        Button { Task { await model.start(s.id) } } label: { Label("Run the pipeline", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(LButton(primary: true))
                    }
                    if worker {
                        HStack(spacing: 6) {
                            Button { Task { await model.relaunch(s.id) } } label: { Label("Relaunch", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }.buttonStyle(LButton())
                            Button { Task { await model.cleanup(s.id) } } label: { Label("Clean up", systemImage: "trash").frame(maxWidth: .infinity) }.buttonStyle(LButton())
                        }
                    }
                }
            }
        }
    }
}

struct PropSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(T.ui(11.5, .semibold)).foregroundStyle(T.text3)
            content()
        }
    }
}

struct PropRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label).font(T.ui(12.5)).foregroundStyle(T.text3).frame(width: 74, alignment: .leading)
            content().foregroundStyle(T.text)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }
}

// MARK: - Drawer

/// A split pane's details when it's too narrow for the column: docked
/// under the pane, a strip with the essentials that unfolds into the panel.
struct DetailsDrawer: View {
    @Environment(AppModel.self) var model
    let id: String
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(T.line).frame(height: 1)
            DrawerStrip(id: id, open: open, toggle: toggle)
            if open {
                Rectangle().fill(T.lineSoft).frame(height: 1)
                PropertiesPanel(id: id, compact: true)
                    .frame(height: 248)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(T.panel)
        .clipped()
        .animation(M.snappy, value: open)
    }
}

struct DrawerStrip: View {
    @Environment(AppModel.self) var model
    let id: String
    let open: Bool
    let toggle: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        let s = model.sessions.first { $0.id == id }
        HStack(spacing: 10) {
            Text("Details").font(T.ui(12, .semibold)).foregroundStyle(T.text2)
            if let s, !s.isOrchestrator {
                let d = model.statusDisplay(s)
                HStack(spacing: 5) {
                    StatusIcon(kind: d.kind, color: d.color, size: 11)
                    Text(d.label).font(T.ui(11.5)).foregroundStyle(T.text2)
                }
                if let pr = model.pr(for: s.prUrl) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.pull").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(T.text3)
                        Text(verbatim: "#\(pr.number)").font(T.mono(11)).foregroundStyle(T.text2)
                        ChecksIcon(pr: pr).font(.system(size: 10.5))
                    }
                }
                if !s.issueKey.isEmpty { Text(s.issueKey).font(T.mono(11)).foregroundStyle(T.text3) }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up").font(.system(size: 9.5, weight: .bold)).foregroundStyle(hover.v ? T.text : T.text3)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 14).frame(height: 32)
        .background(hover.v ? T.hover.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .hoverBox(hover)
        .help(open ? "Fold the details" : "Unfold the details")
    }
}
