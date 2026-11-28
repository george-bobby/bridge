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
                // Side by side when there's room; stacked in a narrow split pane.
                GeometryReader { g in
                    if g.size.width >= 620 {
                        HSplitView {
                            files.frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                            diffView.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VSplitView {
                            files.frame(minHeight: 200, idealHeight: min(g.size.height * 0.45, 380), maxHeight: .infinity)
                            diffView.frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    var files: some View {
        let s = status.v
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if s["files"].array.isEmpty { Text("Nothing uncommitted").font(T.ui(12)).foregroundStyle(T.text3).padding(14) }
                    ForEach(s["files"].array, id: \.self) { f in fileRow(f) }
                }
            }
            Hairline()
            actions
        }
    }

    var diffView: some View {
        ScrollView(.vertical) { DiffText(diff: diff.v).padding(12) }
            .defaultScrollAnchor(.topLeading)
            .background(T.bg)
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

/// A unified diff, coloured line by line, selectable across lines.
struct DiffText: View {
    let diff: String
    var body: some View {
        if diff.isEmpty {
            Text("Pick a file").font(T.ui(12)).foregroundStyle(T.text3)
        } else {
            RichText(key: "unified|\(diff.hashValue)") { DiffText.render(diff) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func render(_ diff: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let add = RichBlock(.band(NT.green.withAlphaComponent(0.08))), del = RichBlock(.band(NT.red.withAlphaComponent(0.08)))
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000)
        for (i, line) in lines.enumerated() {
            let l = String(line)
            let header = l.hasPrefix("+++") || l.hasPrefix("---") || l.hasPrefix("diff ") || l.hasPrefix("index ")
            let color: NSColor = header ? NT.text3 : l.hasPrefix("@@") ? NT.accent : l.hasPrefix("+") ? NT.green : l.hasPrefix("-") ? NT.red : NT.text2
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byCharWrapping
            p.lineSpacing = 1.5
            if !header && l.hasPrefix("+") { p.textBlocks = [add] } else if !header && l.hasPrefix("-") { p.textBlocks = [del] } else { p.headIndent = 0 }
            if !header && l.hasPrefix("@@") { p.paragraphSpacingBefore = i == 0 ? 0 : 6 }
            out.append(NSAttributedString(string: (l.isEmpty ? " " : l) + (i == lines.count - 1 ? "" : "\n"), attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        return out
    }
}

// MARK: - Inline edits and to-dos in the transcript

/// An Edit / Write / MultiEdit step's change, as a selectable diff under the
/// step: long ones fold to a few lines with a toggle for the rest.
struct EditPreview: View {
    let raw: JSON
    @StateObject private var all = Box(false)
    private let folded = 14

    var edits: [(String, String)] {
        if !raw["edits"].array.isEmpty { return raw["edits"].array.map { ($0["old_string"].string, $0["new_string"].string) } }
        if !raw["old_string"].isNull || !raw["new_string"].isNull { return [(raw["old_string"].string, raw["new_string"].string)] }
        if !raw["content"].isNull { return [("", raw["content"].string)] }
        return []
    }

    /// Every line, signed; an empty side (a new file) adds nothing.
    var lines: [(Character, String)] {
        edits.flatMap { e -> [(Character, String)] in
            func split(_ s: String) -> [String] { s.isEmpty ? [] : s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
            return split(e.0).map { ("-", $0) } + split(e.1).map { ("+", $0) }
        }
    }

    var body: some View {
        let lines = self.lines
        if !lines.isEmpty {
            let shown = all.v ? lines : Array(lines.prefix(folded))
            VStack(alignment: .leading, spacing: 0) {
                RichText(key: "diff|\(shown.count)|\(raw.hashValue)") { EditPreview.render(shown) }
                    .padding(.vertical, 4)
                if lines.count > folded {
                    Button { withAnimation(M.snappy) { all.v.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: all.v ? "chevron.up" : "chevron.down").font(.system(size: 8.5, weight: .bold))
                            Text(all.v ? "Show less" : "Show all \(lines.count) lines").font(T.ui(11, .medium))
                        }
                        .foregroundStyle(T.text3).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(T.bg))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    static func render(_ lines: [(Character, String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let bands: [Character: RichBlock] = ["-": RichBlock(.band(NT.red.withAlphaComponent(0.08))), "+": RichBlock(.band(NT.green.withAlphaComponent(0.08)))]
        for (i, l) in lines.enumerated() {
            let p = NSMutableParagraphStyle()
            p.textBlocks = [bands[l.0]!]
            p.lineBreakMode = .byCharWrapping
            out.append(NSAttributedString(string: "\(l.0) \(l.1)\(i == lines.count - 1 ? "" : "\n")", attributes: [.font: font, .foregroundColor: l.0 == "-" ? NT.red : NT.green, .paragraphStyle: p]))
        }
        return out
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

extension AppModel {
    func loadCommands(for runId: String) async {
        commands = (try? await API.get("/api/commands?runId=\(API.q(runId))"))?["commands"].array ?? []
    }
}
