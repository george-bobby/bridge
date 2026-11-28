import SwiftUI

// MARK: - Source Control (an orchestrator's tab)

/// An orchestrator doesn't build, so its second tab isn't a session's diff:
/// it's VS Code's Source Control for the project's checkout. Branch with
/// ahead/behind, fetch / pull / push / sync, a commit box, the changed files
/// as a tree and the commit graph; the right side shows the picked file's
/// diff or the picked commit. Pull only fast-forwards and push never forces.
struct SourceControlView: View {
    @Environment(AppModel.self) var model
    let runId: String
    @StateObject private var status = Box(JSON.null)
    @StateObject private var graph = Box(JSON.null)
    @StateObject private var pick = Box("")          // "file:<path>" or "commit:<sha>"
    @StateObject private var diff = Box("")
    @StateObject private var message = Box("")
    @StateObject private var busy = Box("")
    @StateObject private var collapsed = Box(Set<String>())
    @StateObject private var error = Box("")

    var base: String { "/api/runs/\(API.q(runId))" }

    var body: some View {
        Group {
            if !status.v.isNull && !status.v["repo"].bool {
                EmptyState(icon: "folder.badge.questionmark", title: "Not a git checkout", detail: status.v["dir"].string)
            } else {
                GeometryReader { g in
                    if g.size.width >= 680 {
                        HSplitView {
                            sidebar.frame(minWidth: 280, idealWidth: 360, maxWidth: 460)
                            detail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VSplitView {
                            sidebar.frame(minHeight: 260, idealHeight: g.size.height * 0.6, maxHeight: .infinity)
                            detail.frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .onAppear { load() }
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            SCMHeader(status: status.v, busy: busy.v, run: run)
            Hairline()
            commitBox
            if !error.v.isEmpty { errorLine }
            // Changes takes what its rows need (up to a third); the graph gets the rest.
            GeometryReader { g in
                let rows = ChangeNode.rows(ChangeNode.tree(status.v["files"].array), collapsed: collapsed.v).count
                VStack(spacing: 0) {
                    changesSection.frame(height: min(max(CGFloat(rows) * 24 + 42, 74), max(74, g.size.height / 3)))
                    graphSection.frame(maxHeight: .infinity)
                }
            }
        }
        .background(T.panel)
    }

    var commitBox: some View {
        let s = status.v
        let dirty = !s["files"].array.isEmpty
        let behind = s["behind"].int, ahead = s["unpushed"].int
        let msg = message.v.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 8) {
            LField(placeholder: "Message (↩ to commit on \"\(s["branch"].nonEmpty ?? "HEAD")\")", text: $message.v) { commit() }
            if dirty {
                HStack(spacing: 6) {
                    Button { commit() } label: { Label(busy.v == "commit" ? "Committing…" : "Commit", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .buttonStyle(LButton(kind: .primary)).disabled(!busy.v.isEmpty || msg.isEmpty)
                    if behind > 0 || ahead > 0 {
                        Button { run("sync") } label: { Label(syncLabel(behind: behind, ahead: ahead, publish: false).replacingOccurrences(of: "Sync Changes", with: "Sync"), systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(LButton()).disabled(!busy.v.isEmpty)
                            .help("Fast-forward to \(s["upstream"].string), then push. Git stops if your uncommitted files would be overwritten.")
                    }
                }
            } else if behind > 0 || ahead > 0 || s["upstream"].string.isEmpty && !s["branch"].string.isEmpty {
                Button { run("sync") } label: {
                    Label(busy.v == "sync" ? "Syncing…" : syncLabel(behind: behind, ahead: ahead, publish: s["upstream"].string.isEmpty), systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(LButton(kind: .primary)).disabled(!busy.v.isEmpty)
                .help(s["upstream"].string.isEmpty ? "Push this branch and track it on origin" : "Fast-forward to \(s["upstream"].string), then push")
            } else {
                Text(s.isNull ? " " : "Up to date with \(s["upstream"].nonEmpty ?? "its upstream")").font(T.ui(11.5)).foregroundStyle(T.text3)
                    .frame(maxWidth: .infinity).frame(height: B.regular)
            }
        }
        .padding(12)
    }

    func syncLabel(behind: Int, ahead: Int, publish: Bool) -> String {
        if publish { return "Publish Branch" }
        return "Sync Changes" + (behind > 0 ? " \(behind)↓" : "") + (ahead > 0 ? " \(ahead)↑" : "")
    }

    var errorLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(T.red)
            Text(error.v).font(T.ui(11.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            IconButton(icon: "xmark", help: "Dismiss", size: B.mini) { error.v = "" }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    var changesSection: some View {
        let files = status.v["files"].array
        return VStack(spacing: 0) {
            SectionBar(title: "Changes", count: files.count) {
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: busy.v == "load", size: B.small) { load() }
            }
            ScrollView {
                if files.isEmpty && !status.v.isNull {
                    Text("No uncommitted changes in the checkout").font(T.ui(12)).foregroundStyle(T.text3).padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
                ChangeList(files: files, selected: pick.v.hasPrefix("file:") ? String(pick.v.dropFirst(5)) : "", collapsed: collapsed) { openFile($0) }
            }
        }
    }

    var graphSection: some View {
        VStack(spacing: 0) {
            SectionBar(title: "Graph", count: nil) {
                IconButton(icon: "arrow.down.circle", help: "Fetch", spinning: busy.v == "fetch", size: B.small) { run("fetch") }.disabled(!busy.v.isEmpty)
                IconButton(icon: "arrow.clockwise", help: "Refresh", size: B.small) { load() }
            }
            CommitGraph(commits: graph.v["commits"].array, selected: pick.v.hasPrefix("commit:") ? String(pick.v.dropFirst(7)) : "") { openCommit($0) }
        }
    }

    var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if pick.v.hasPrefix("file:") {
                    let p = String(pick.v.dropFirst(5))
                    FileGlyph(name: p, size: 14)
                    Text(p).font(T.ui(12)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.head)
                } else if pick.v.hasPrefix("commit:") {
                    Image(systemName: "smallcircle.filled.circle").font(.system(size: 11)).foregroundStyle(T.text3)
                    Text(String(pick.v.dropFirst(7).prefix(10))).font(T.mono(11.5)).foregroundStyle(T.text2)
                } else {
                    Text("Pick a file or a commit").font(T.ui(12)).foregroundStyle(T.text3)
                }
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 34)
            Hairline()
            ScrollView(.vertical) { DiffText(diff: diff.v).padding(12) }
                .defaultScrollAnchor(.topLeading)
        }
        .background(T.bg)
    }

    // MARK: Loading and actions

    func load() {
        if busy.v.isEmpty { busy.v = "load" }
        Task {
            async let s = try? API.get("\(base)/changes")
            async let g = try? API.get("\(base)/graph?limit=120")
            if let s = await s { status.v = s }
            if let g = await g { graph.v = g }
            if busy.v == "load" { busy.v = "" }
            if pick.v.isEmpty, let f = status.v["files"].array.first?["path"].string { openFile(f) }
        }
    }

    func openFile(_ path: String) {
        pick.v = "file:" + path
        diff.v = ""
        Task {
            let out = try? await API.get("\(base)/diff?file=\(API.q(path))")
            if pick.v == "file:" + path { diff.v = out?["diff"].string ?? "" }
        }
    }

    func openCommit(_ sha: String) {
        pick.v = "commit:" + sha
        diff.v = ""
        Task {
            let out = try? await API.get("\(base)/show?sha=\(API.q(sha))")
            if pick.v == "commit:" + sha { diff.v = out?["diff"].string ?? "" }
        }
    }

    func commit() {
        let msg = message.v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, busy.v.isEmpty, !status.v["files"].array.isEmpty else { return }
        perform("commit", ["message": msg]) { message.v = ""; model.say("Committed") }
    }

    /// fetch, pull, push or sync; git's own message shows under the commit box on failure.
    func run(_ verb: String) {
        guard busy.v.isEmpty else { return }
        let done = ["fetch": "Fetched", "pull": "Pulled", "push": "Pushed", "sync": "Synced"][verb] ?? "Done"
        perform(verb, [:]) { model.say(done) }
    }

    func perform(_ verb: String, _ body: [String: Any], then: @escaping () -> Void) {
        busy.v = verb
        error.v = ""
        Task {
            do {
                status.v = try await API.request("POST", "\(base)/\(verb)", body, timeout: 150)
                then()
            } catch {
                self.error.v = error.localizedDescription
            }
            busy.v = ""
            load()
        }
    }
}

/// Branch, ahead/behind and the pull / push buttons, at the top of Source Control.
struct SCMHeader: View {
    let status: JSON
    let busy: String
    let run: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11.5)).foregroundStyle(T.text3)
            Text(status["branch"].nonEmpty ?? "—").font(T.mono(12, .medium)).foregroundStyle(T.text).lineLimit(1).truncationMode(.middle)
            if status["behind"].int > 0 || status["unpushed"].int > 0 {
                Text(verbatim: "\(status["behind"].int)↓ \(status["unpushed"].int)↑").font(T.mono(11)).foregroundStyle(T.text2)
                    .help("\(status["behind"].int) to pull from \(status["upstream"].string), \(status["unpushed"].int) to push")
            }
            Spacer(minLength: 4)
            IconButton(icon: "arrow.down.to.line", help: "Pull (fast-forward only)", spinning: busy == "pull", size: B.small) { run("pull") }
                .disabled(!busy.isEmpty || status["upstream"].string.isEmpty)
            IconButton(icon: "arrow.up.to.line", help: "Push", spinning: busy == "push", size: B.small) { run("push") }
                .disabled(!busy.isEmpty || status["unpushed"].int == 0 && !status["upstream"].string.isEmpty)
        }
        .padding(.horizontal, 12).frame(height: 40)
    }
}

/// A pane's title bar inside Source Control: "CHANGES 3" and its buttons.
struct SectionBar<Trailing: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(T.ui(10.5, .semibold)).tracking(0.4).foregroundStyle(T.text2)
            if let count, count > 0 {
                Text(verbatim: "\(count)").font(T.ui(10, .semibold)).foregroundStyle(T.text2)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16).background(Capsule().fill(T.selected))
            }
            Spacer()
            trailing()
        }
        .padding(.leading, 14).padding(.trailing, 8).frame(height: 30)
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Commit graph

/// One row's share of the graph: where its dot sits and the lane segments
/// above (into the dot or straight through) and below (to its parents).
struct GraphRow {
    let col: Int
    let color: Int
    let up: [Seg]
    let down: [Seg]
    struct Seg { let from: Int; let to: Int; let color: Int }

    /// The usual lane assignment: each lane waits for a commit id; a commit
    /// takes the first lane waiting for it (others waiting for it merge in),
    /// then hands its lane to its first parent and opens lanes for the rest.
    static func layout(_ commits: [JSON]) -> [GraphRow] {
        var lanes: [(sha: String, color: Int)?] = []
        var next = 0
        var out: [GraphRow] = []
        func slot() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            return lanes.count - 1
        }
        for c in commits {
            let sha = c["sha"].string
            let parents = c["parents"].array.map(\.string)
            var col = lanes.firstIndex { $0?.sha == sha } ?? -1
            let fresh = col < 0
            if fresh { col = slot(); lanes[col] = (sha, next); next += 1 }
            let color = lanes[col]!.color
            var up: [Seg] = []
            for (i, l) in lanes.enumerated() {
                guard let l, !(fresh && i == col) else { continue }
                up.append(Seg(from: i, to: l.sha == sha ? col : i, color: l.color))
            }
            for i in lanes.indices where i != col && lanes[i]?.sha == sha { lanes[i] = nil }
            var merges: [Int] = []
            if let first = parents.first {
                lanes[col] = (first, color)
                for p in parents.dropFirst() {
                    if let j = lanes.firstIndex(where: { $0?.sha == p }) { merges.append(j) } else {
                        let j = slot(); lanes[j] = (p, next); next += 1; merges.append(j)
                    }
                }
            } else {
                lanes[col] = nil
            }
            var down: [Seg] = []
            for (i, l) in lanes.enumerated() {
                guard let l else { continue }
                if i == col { down.append(Seg(from: col, to: col, color: color)) } else { down.append(Seg(from: i, to: i, color: l.color)) }
                if merges.contains(i) && i != col { down.append(Seg(from: col, to: i, color: l.color)) }
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            out.append(GraphRow(col: col, color: color, up: up, down: down))
        }
        return out
    }

    var width: Int { ([col] + up.flatMap { [$0.from, $0.to] } + down.flatMap { [$0.from, $0.to] }).max()! + 1 }
}

/// VS Code's Graph panel: lanes and dots on the left, the subject, and the
/// branch / remote / tag markers on the right. Click a row for its patch.
struct CommitGraph: View {
    let commits: [JSON]
    let selected: String
    let open: (String) -> Void

    static let lane: CGFloat = 11
    static let palette: [Color] = [T.accent, T.purple, T.orange, T.green, T.red, T.yellow, Color(nsColor: NT.link), T.slack]

    var body: some View {
        let rows = GraphRow.layout(commits)
        let lanes = min(8, rows.map(\.width).max() ?? 1)
        ScrollView {
            if commits.isEmpty { Text("No commits").font(T.ui(12)).foregroundStyle(T.text3).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
            LazyVStack(spacing: 0) {
                ForEach(Array(zip(commits, rows).enumerated()), id: \.offset) { _, pair in
                    CommitRow(commit: pair.0, row: pair.1, lanes: lanes, selected: pair.0["sha"].string == selected)
                        .onTapGesture { open(pair.0["sha"].string) }
                }
            }
            .padding(.bottom, 6)
        }
    }
}

struct CommitRow: View {
    let commit: JSON
    let row: GraphRow
    let lanes: Int
    let selected: Bool
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 6) {
            GraphLanes(row: row, head: commit["head"].bool)
                .frame(width: 8 + CGFloat(lanes) * CommitGraph.lane, height: 24)
                .clipped()
            Text(commit["subject"].string).font(T.ui(12.5, commit["head"].bool ? .semibold : .regular)).foregroundStyle(T.text).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(Array(commit["refs"].array.prefix(3).enumerated()), id: \.offset) { _, r in RefMarker(ref: r, color: CommitGraph.palette[row.color % CommitGraph.palette.count]) }
            if hover.v && commit["refs"].array.isEmpty {
                Text(Fmt.ago(Double(commit["at"].int))).font(T.ui(10.5)).foregroundStyle(T.text3)
            }
        }
        .padding(.leading, 6).padding(.trailing, 10)
        .frame(height: 24)
        .background(selected ? T.selected : hover.v ? T.hover : Color.clear)
        .contentShape(Rectangle())
        .hoverBox(hover)
        .help("\(commit["short"].string) · \(commit["author"].string) · \(Fmt.ago(Double(commit["at"].int)))\n\(commit["subject"].string)")
    }
}

/// The lanes for one row: segments in, segments out, and the commit's dot
/// (hollow for HEAD, like VS Code).
struct GraphLanes: View {
    let row: GraphRow
    let head: Bool

    var body: some View {
        Canvas { ctx, size in
            let x = { (i: Int) in 8 + CGFloat(i) * CommitGraph.lane }
            let mid = size.height / 2
            func stroke(_ s: GraphRow.Seg, _ y0: CGFloat, _ y1: CGFloat) {
                var p = Path()
                p.move(to: CGPoint(x: x(s.from), y: y0))
                if s.from == s.to { p.addLine(to: CGPoint(x: x(s.to), y: y1)) } else {
                    p.addCurve(to: CGPoint(x: x(s.to), y: y1), control1: CGPoint(x: x(s.from), y: (y0 + y1) / 2), control2: CGPoint(x: x(s.to), y: (y0 + y1) / 2))
                }
                ctx.stroke(p, with: .color(CommitGraph.palette[s.color % CommitGraph.palette.count]), lineWidth: 1.6)
            }
            for s in row.up { stroke(s, 0, mid) }
            for s in row.down { stroke(s, mid, size.height) }
            let c = CommitGraph.palette[row.color % CommitGraph.palette.count]
            let dot = CGRect(x: x(row.col) - 4, y: mid - 4, width: 8, height: 8)
            if head {
                ctx.fill(Path(ellipseIn: dot), with: .color(T.panel))
                ctx.stroke(Path(ellipseIn: dot.insetBy(dx: 0.5, dy: 0.5)), with: .color(c), lineWidth: 2)
            } else {
                ctx.fill(Path(ellipseIn: dot.insetBy(dx: 0.5, dy: 0.5)), with: .color(c))
            }
        }
    }
}

/// A branch (target), remote (cloud) or tag on a commit row.
struct RefMarker: View {
    let ref: JSON
    let color: Color

    var body: some View {
        let kind = ref["kind"].string
        HStack(spacing: 3) {
            Image(systemName: kind == "tag" ? "tag.fill" : kind == "remote" ? "cloud.fill" : "smallcircle.filled.circle")
                .font(.system(size: 8.5, weight: .bold))
            Text(ref["name"].string).font(T.ui(10.5, .semibold)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).frame(height: 17)
        .frame(maxWidth: 150)
        .background(Capsule().fill(color.opacity(kind == "branch" ? 0.22 : 0.12)))
        .overlay(Capsule().stroke(color.opacity(kind == "branch" ? 0.7 : 0), lineWidth: 1))
        .help(kind == "remote" ? "Remote branch \(ref["name"].string)" : kind == "tag" ? "Tag \(ref["name"].string)" : "Current branch \(ref["name"].string)")
    }
}
