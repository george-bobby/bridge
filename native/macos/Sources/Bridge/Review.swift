import AppKit
import SwiftUI

// MARK: - Changes (diff, commit, push, PR)

/// What the session's working folder changed, file by file, with the actions
/// you take on it: commit, push, open a PR.
struct ChangesView: View {
    @Environment(AppModel.self) var model
    let runId: String
    @StateObject private var status = Box(JSON.null)
    @StateObject private var selected = Box("")
    @StateObject private var diff = Box("")
    @StateObject private var message = Box("")
    @StateObject private var busy = Box("")

    var body: some View {
        let s = status.v
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(T.text3)
                Text(s["branch"].nonEmpty ?? "—").font(T.mono(12)).foregroundStyle(T.text2)
                if s["unpushed"].int > 0 { Chip(text: "\(s["unpushed"].int) unpushed", icon: "arrow.up", tint: T.orange) }
                Text(verbatim: "\(s["files"].array.count) changed").font(T.ui(12)).foregroundStyle(T.text3)
                Spacer()
                IconButton(icon: "arrow.clockwise", help: "Refresh") { load() }
            }
            .padding(.horizontal, 16).frame(height: 40)
            Hairline()
            if !s["repo"].bool && !s.isNull {
                EmptyState(icon: "folder.badge.questionmark", title: "Not a git checkout", detail: s["dir"].string)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if s["files"].array.isEmpty { Text("Nothing uncommitted").font(T.ui(12)).foregroundStyle(T.text3).padding(14) }
                                ForEach(s["files"].array, id: \.self) { f in fileRow(f) }
                            }
                        }
                        Hairline()
                        actions
                    }
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                    ScrollView([.vertical, .horizontal]) { DiffText(diff: diff.v).padding(12) }
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        .background(T.bg)
                }
            }
        }
        .onAppear(perform: load)
    }

    func fileRow(_ f: JSON) -> some View {
        let path = f["path"].string
        let kind = f["kind"].string
        return HoverRow(selected: selected.v == path, height: 30) {
            HStack(spacing: 6) {
                Text(kind == "added" ? "A" : kind == "deleted" ? "D" : kind == "renamed" ? "R" : "M")
                    .font(T.mono(10.5, .bold)).foregroundStyle(kind == "added" ? T.green : kind == "deleted" ? T.red : T.yellow).frame(width: 12)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(T.ui(12.5)).foregroundStyle(T.text).lineLimit(1)
                Text(URL(fileURLWithPath: path).deletingLastPathComponent().relativePath).font(T.ui(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                if f["additions"].int > 0 { Text(verbatim: "+\(f["additions"].int)").font(T.mono(10.5)).foregroundStyle(T.green) }
                if f["deletions"].int > 0 { Text(verbatim: "−\(f["deletions"].int)").font(T.mono(10.5)).foregroundStyle(T.red) }
            }
        }
        .onTapGesture { open(path) }
    }

    var actions: some View {
        let s = status.v
        let session = model.sessions.first { $0.id == runId }
        return VStack(alignment: .leading, spacing: 8) {
            LField(placeholder: "Commit message", text: $message.v) { commit() }
            HStack(spacing: 6) {
                Button(busy.v == "commit" ? "Committing…" : "Commit all") { commit() }
                    .buttonStyle(LButton(primary: true)).disabled(!busy.v.isEmpty || s["files"].array.isEmpty || message.v.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(busy.v == "push" ? "Pushing…" : "Push") { act("push") }
                    .buttonStyle(LButton()).disabled(!busy.v.isEmpty || s["unpushed"].int == 0 && !s["upstream"].string.isEmpty)
                if let pr = session?.prUrl, !pr.isEmpty {
                    Button { openURL(pr) } label: { Label("PR #\(session?.prNumber ?? "")", systemImage: "arrow.up.right") }.buttonStyle(LButton())
                } else {
                    Button(busy.v == "pr" ? "Opening…" : "Create PR") { act("pr") }.buttonStyle(LButton()).disabled(!busy.v.isEmpty)
                }
            }
            ForEach(Array(s["commits"].array.prefix(3).enumerated()), id: \.offset) { _, c in
                HStack(spacing: 6) {
                    Text(c["sha"].string).font(T.mono(10.5)).foregroundStyle(T.text3)
                    Text(c["subject"].string).font(T.ui(11.5)).foregroundStyle(T.text2).lineLimit(1)
                    Spacer()
                    Text(c["when"].string).font(T.ui(10.5)).foregroundStyle(T.text3)
                }
            }
        }
        .padding(12)
    }

    func load() {
        Task {
            if let s = try? await API.get("/api/runs/\(API.q(runId))/changes") { status.v = s }
            if selected.v.isEmpty, let first = status.v["files"].array.first?["path"].string { open(first) }
        }
    }

    func open(_ path: String) {
        selected.v = path
        diff.v = ""
        Task {
            let out = try? await API.get("/api/runs/\(API.q(runId))/diff?file=\(API.q(path))")
            if selected.v == path { diff.v = out?["diff"].string ?? "" }
        }
    }

    func commit() {
        let msg = message.v.trimmingCharacters(in: .whitespaces)
        guard !msg.isEmpty else { return }
        busy.v = "commit"
        Task {
            await model.act {
                self.status.v = try await API.post("/api/runs/\(API.q(self.runId))/commit", ["message": msg])
                self.message.v = ""
                self.model.say("Committed")
            }
            busy.v = ""
            load()
        }
    }

    func act(_ verb: String) {
        busy.v = verb
        Task {
            await model.act {
                let out = try await API.post("/api/runs/\(API.q(self.runId))/\(verb)")
                if verb == "pr" { self.model.say("Opened \(out["prUrl"].string)"); openURL(out["prUrl"].string) } else { self.model.say("Pushed") }
            }
            busy.v = ""
            load()
        }
    }
}

/// A unified diff, coloured line by line.
struct DiffText: View {
    let diff: String
    var body: some View {
        if diff.isEmpty {
            Text("Pick a file").font(T.ui(12)).foregroundStyle(T.text3)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000).enumerated()), id: \.offset) { _, line in
                    let l = String(line)
                    let header = l.hasPrefix("+++") || l.hasPrefix("---") || l.hasPrefix("diff ") || l.hasPrefix("index ")
                    Text(l.isEmpty ? " " : l)
                        .font(T.mono(11.5))
                        .foregroundStyle(header ? T.text3 : l.hasPrefix("@@") ? T.accent : l.hasPrefix("+") ? T.green : l.hasPrefix("-") ? T.red : T.text2)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(header ? Color.clear : l.hasPrefix("+") ? T.green.opacity(0.08) : l.hasPrefix("-") ? T.red.opacity(0.08) : .clear)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - Inline edits and to-dos in the transcript

/// An Edit / Write / MultiEdit step's change, as a small diff under the step.
struct EditPreview: View {
    let raw: JSON
    var body: some View {
        let edits: [(String, String)] = {
            if !raw["edits"].array.isEmpty { return raw["edits"].array.map { ($0["old_string"].string, $0["new_string"].string) } }
            if !raw["old_string"].isNull || !raw["new_string"].isNull { return [(raw["old_string"].string, raw["new_string"].string)] }
            if !raw["content"].isNull { return [("", raw["content"].string)] }
            return []
        }()
        if !edits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(edits.prefix(4).enumerated()), id: \.offset) { _, e in
                    ForEach(Array(e.0.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).enumerated()), id: \.offset) { _, l in
                        line("-", String(l), T.red)
                    }
                    ForEach(Array(e.1.split(separator: "\n", omittingEmptySubsequences: false).prefix(16).enumerated()), id: \.offset) { _, l in
                        line("+", String(l), T.green)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.bg))
        }
    }

    func line(_ sign: String, _ text: String, _ color: Color) -> some View {
        Text("\(sign) \(text)").font(T.mono(11)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.07))
    }
}

/// TodoWrite (Claude) and update_plan (Codex) as a checklist.
struct TodoList: View {
    let raw: JSON
    var body: some View {
        let items = raw["todos"].array.isEmpty ? raw["plan"].array : raw["todos"].array
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                let st = t["status"].string
                HStack(spacing: 8) {
                    Image(systemName: st == "completed" ? "checkmark.circle.fill" : st == "in_progress" ? "circle.dotted.circle" : "circle")
                        .font(.system(size: 11)).foregroundStyle(st == "completed" ? T.accent : st == "in_progress" ? T.yellow : T.text3)
                    Text(t["content"].nonEmpty ?? t["step"].string).font(T.ui(12.5))
                        .foregroundStyle(st == "completed" ? T.text3 : T.text).strikethrough(st == "completed", color: T.text3)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(T.raised.opacity(0.45)))
    }
}

// MARK: - Slash commands

struct SlashMenu: View {
    @Environment(AppModel.self) var model
    let query: String
    let pick: (String) -> Void

    var body: some View {
        let q = query.lowercased()
        let hits = model.commands.filter { q.isEmpty || $0["name"].string.lowercased().hasPrefix(q) || $0["name"].string.lowercased().contains(q) }.prefix(8)
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hits), id: \.self) { c in
                    Button { pick(c["name"].string) } label: {
                        HStack(spacing: 8) {
                            Text("/" + c["name"].string).font(T.mono(12, .medium)).foregroundStyle(T.text)
                            Text(c["description"].string).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
                            Spacer()
                            Text(c["source"].string).font(T.ui(10)).foregroundStyle(T.text3)
                        }
                        .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 9).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        }
    }
}

extension AppModel {
    func loadCommands(for runId: String) async {
        commands = (try? await API.get("/api/commands?runId=\(API.q(runId))"))?["commands"].array ?? []
    }

    func secondOpinion(_ runId: String, agent: AgentKind) async {
        await act {
            let out = try await API.post("/api/runs/\(API.q(runId))/advisor", ["agent": agent.rawValue])
            self.say("\(agent.label) is reviewing it in its own worktree")
            self.open(out["taskId"].string)
        }
    }

    func stopAndSend(_ text: String, to id: String) async -> Bool {
        await stop(id)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !running.contains(id) { break }
        }
        return await send(text, to: id)
    }
}

/// How full the context window was on the last turn.
struct ContextMeter: View {
    let run: JSON
    var body: some View {
        let last = run["messages"].array.last { $0["role"].string == "assistant" && $0["usage"]["input"].int + $0["usage"]["cacheRead"].int > 0 }
        if let m = last {
            let used = m["usage"]["input"].double + m["usage"]["cacheRead"].double + m["usage"]["cacheWrite"].double
            let size = m["contextWindow"].double > 0 ? m["contextWindow"].double : 200_000
            let f = min(1, used / size)
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(T.line, lineWidth: 2)
                    Circle().trim(from: 0, to: f).stroke(f > 0.8 ? T.orange : T.text2, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text(verbatim: "\(Int(f * 100))%").font(T.ui(10.5)).foregroundStyle(T.text3).monospacedDigit()
            }
            .help("Context: \(Fmt.tokens(Int(used))) of \(Fmt.tokens(Int(size))) tokens on the last turn")
        }
    }
}
