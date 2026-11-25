import AppKit
import SwiftUI

// MARK: - Chat

struct ChatView: View {
    @Environment(AppModel.self) var model
    let id: String

    var session: Session? { model.sessions.first { $0.id == id } }
    var run: JSON { model.openRun }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Transcript(run: run, runId: id)
                    Composer(runId: id)
                }
                Rectangle().fill(T.line).frame(width: 1)
                PropertiesPanel(id: id).frame(width: 284)
            }
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Button { model.route = .sessions } label: { Text("Sessions").font(T.ui(13)).foregroundStyle(T.text2) }.buttonStyle(.plain)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3)
            if let s = session {
                if s.isOrchestrator { Image(systemName: "sparkles").foregroundStyle(T.purple) } else { SessionIcon(session: s, size: 13) }
                if !s.issueKey.isEmpty { Text(s.issueKey).font(T.mono(12)).foregroundStyle(T.text3) }
                Text(s.isOrchestrator ? "Orchestrator" : s.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
            } else {
                Text(run["who"].nonEmpty ?? id).font(T.ui(13, .medium))
            }
            Spacer()
            if let s = session {
                if !s.permalink.isEmpty { IconButton(icon: "number", help: "Read the Slack thread") { model.openThread(s.permalink) } }
                IconButton(icon: s.pinned ? "star.fill" : "star", help: s.pinned ? "Unpin" : "Pin to the sidebar") { Task { await model.setPinned(s.id, !s.pinned) } }
                if !s.linearUrl.isEmpty { IconButton(icon: "circle.lefthalf.filled", help: "Open in Linear") { openURL(s.linearUrl) } }
                if !s.prUrl.isEmpty { IconButton(icon: "arrow.triangle.pull", help: "Open the pull request") { openURL(s.prUrl) } }
                IconButton(icon: "terminal", help: "Continue this session in \(model.terminalName)") { Task { await model.terminal(id) } }
                if model.isLive(s) {
                    Button { Task { await model.stop(id) } } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(LButton(danger: true))
                }
                Menu {
                    SessionMenu(session: s)
                } label: { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(T.text2).frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }
}

struct Transcript: View {
    let run: JSON
    let runId: String

    var body: some View {
        let messages = run["messages"].array
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if run.isNull {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
                } else if messages.isEmpty {
                    EmptyState(icon: "bubble.left", title: "Nothing here yet", detail: "Send a message below to start the session.")
                }
                ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                    MessageView(m: m, run: run, runId: runId)
                }
                Color.clear.frame(height: 8).id("end")
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
    }
}

struct MessageView: View {
    let m: JSON
    let run: JSON
    let runId: String

    var body: some View {
        switch m["role"].string {
        case "assistant": AssistantMessage(m: m, runId: runId)
        case "event", "outcome": EventLine(m: m)
        case "relay", "harness": HarnessMessage(m: m)
        default: UserMessage(m: m, run: run)
        }
    }
}

struct MessageHead: View {
    let name: String
    var detail: String = ""
    let ts: Double
    var body: some View {
        HStack(spacing: 7) {
            Text(name).font(T.ui(13, .semibold)).foregroundStyle(T.text)
            if !detail.isEmpty { Text(detail).font(T.ui(11.5)).foregroundStyle(T.text3) }
            Text(Fmt.clock(ts)).font(T.ui(11.5)).foregroundStyle(T.text3)
        }
    }
}

struct UserMessage: View {
    let m: JSON
    let run: JSON
    var body: some View {
        let role = m["role"].string
        let fromSlack = role == "slack" || role == "thread"
        let name = fromSlack ? (m["who"].nonEmpty ?? run["who"].nonEmpty ?? "Slack") : "You"
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: name, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                MessageHead(name: name, detail: fromSlack ? (run["channel"].nonEmpty.map { "in \($0)" } ?? "Slack") : "", ts: m["ts"].double)
                MarkdownText(text: fromSlack ? Session.plain(m["text"].string) : m["text"].string)
                if m["queued"].bool { Chip(text: "Queued", icon: "clock") }
            }
        }
    }
}

struct ClaudeMark: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.85, green: 0.47, blue: 0.34))
            .overlay(Image(systemName: "asterisk").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

struct AssistantMessage: View {
    let m: JSON
    let runId: String

    var body: some View {
        let state = m["state"].string
        HStack(alignment: .top, spacing: 12) {
            ClaudeMark()
            VStack(alignment: .leading, spacing: 8) {
                MessageHead(name: "Claude", detail: [m["label"].string, m["model"].string].filter { !$0.isEmpty }.joined(separator: " · "), ts: m["ts"].double)
                let steps = m["steps"].array
                if steps.isEmpty && !m["text"].string.isEmpty { MarkdownText(text: m["text"].string) }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in StepView(step: s, runId: runId) }
                footer(state)
            }
        }
    }

    @ViewBuilder func footer(_ state: String) -> some View {
        if state == "running" {
            HStack(spacing: 7) { LiveIcon(size: 11); Text("Working…").font(T.ui(12)).foregroundStyle(T.text3) }
        } else if state == "error" || state == "failed" {
            Label(m["error"].nonEmpty ?? "The session ended with an error", systemImage: "exclamationmark.triangle.fill")
                .font(T.ui(12)).foregroundStyle(T.red)
        } else if m["cost"].double > 0 || m["durationMs"].double > 0 {
            HStack(spacing: 10) {
                if m["cost"].double > 0 { Text(Fmt.money(m["cost"].double)) }
                if m["durationMs"].double > 0 { Text(duration(m["durationMs"].double)) }
                if m["usage"]["output"].int > 0 { Text(verbatim: "\(Fmt.tokens(m["usage"]["output"].int)) out") }
                if m["turns"].int > 0 { Text(verbatim: "\(m["turns"].int) turns") }
                if state == "stopped" { Text("stopped").foregroundStyle(T.orange) }
            }
            .font(T.ui(11.5)).foregroundStyle(T.text3).monospacedDigit()
        }
    }

    func duration(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

struct StepView: View {
    let step: JSON
    let runId: String

    var body: some View {
        switch step["kind"].string {
        case "text":
            if !step["text"].string.isEmpty { MarkdownText(text: step["text"].string) }
        case "thinking":
            ThinkingView(step: step)
        case "tool":
            VStack(alignment: .leading, spacing: 8) {
                ToolView(step: step)
                if !step["ask"].isNull { AskCard(ask: step["ask"], runId: runId) }
            }
        default:
            EmptyView()
        }
    }
}

struct ThinkingView: View {
    let step: JSON
    @StateObject private var open = Box(false)
    var body: some View {
        let text = step["text"].string
        if step["streaming"].bool && text.isEmpty {
            HStack(spacing: 6) { Image(systemName: "brain").font(.system(size: 11)); Text("Thinking…").font(T.ui(12)) }.foregroundStyle(T.text3)
        } else if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { open.v.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain").font(.system(size: 11))
                        Text("Thought").font(T.ui(12))
                        if step["tokens"].int > 0 { Text(verbatim: "· \(Fmt.tokens(step["tokens"].int)) tokens").font(T.ui(12)) }
                        Image(systemName: open.v ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(T.text3)
                }
                .buttonStyle(.plain)
                if open.v {
                    Text(text).font(T.ui(12.5)).foregroundStyle(T.text2).textSelection(.enabled)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 2) }
                }
            }
        }
    }
}

struct ToolView: View {
    let step: JSON
    @StateObject private var open = Box(false)
    @StateObject private var hover = Box(false)

    var body: some View {
        let name = step["name"].string
        let result = step["result"].string
        let failed = step["ok"] == .bool(false)
        VStack(alignment: .leading, spacing: 0) {
            Button { if !result.isEmpty { open.v.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: ToolView.icon(name)).font(.system(size: 11)).foregroundStyle(T.text3).frame(width: 14)
                    Text(ToolView.display(name)).font(T.ui(12, .medium)).foregroundStyle(T.text2)
                    Text(step["detail"].string).font(T.mono(11.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if step["ok"].isNull && result.isEmpty && step["ask"].isNull {
                        EmptyView()
                    } else if failed {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(T.red)
                    } else if !result.isEmpty {
                        if step["resultLines"].int > 0 { Text(verbatim: "\(step["resultLines"].int) lines").font(T.ui(11)).foregroundStyle(T.text3) }
                        Image(systemName: open.v ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
                    }
                }
                .padding(.horizontal, 10).frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.v {
                Hairline()
                ScrollView {
                    Text(result).font(T.mono(11)).foregroundStyle(failed ? T.red : T.text2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 260)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(hover.v ? T.hover.opacity(0.5) : T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.lineSoft, lineWidth: 1))
        .onHover { hover.v = $0 }
    }

    static func display(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            return parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
        }
        return name
    }

    static func icon(_ name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "Task", "Agent": return "person.2"
        case "WebFetch", "WebSearch": return "globe"
        case "TodoWrite": return "checklist"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode": return "list.bullet.clipboard"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

struct EventLine: View {
    let m: JSON
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(T.lineSoft).frame(height: 1).frame(maxWidth: 40)
            Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(T.text3)
            Text(inline(m["text"].string)).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(3)
            Text(Fmt.clock(m["ts"].double)).font(T.ui(11)).foregroundStyle(T.text3.opacity(0.7))
            Rectangle().fill(T.lineSoft).frame(height: 1)
        }
        .padding(.leading, 38)
    }

    var icon: String {
        switch m["phase"].string {
        case "outcome": return "flag"
        case "spawned": return "arrow.triangle.branch"
        case "waiting": return "hourglass"
        default: return "circle.fill"
        }
    }
}

struct HarnessMessage: View {
    let m: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond").font(.system(size: 10.5))
                Text(m["role"].string == "relay" ? "Harness → orchestrator" : "Harness → worker").font(T.ui(11.5, .medium))
                if !m["label"].string.isEmpty { Text(verbatim: "· \(m["label"].string)").font(T.ui(11.5)) }
                Spacer()
                Text(Fmt.clock(m["ts"].double)).font(T.ui(11))
            }
            .foregroundStyle(T.text3)
            MarkdownText(text: m["text"].string.replacingOccurrences(of: #"^\[harness\]\s*"#, with: "", options: .regularExpression), size: 12.5, color: T.text2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(T.raised.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(.leading, 38)
    }
}

// MARK: - Asks

struct AskCard: View {
    @Environment(AppModel.self) var model
    let ask: JSON
    let runId: String
    @StateObject private var note = Box("")
    @StateObject private var picked = Box([String: Set<String>]())
    @StateObject private var busy = Box(false)

    var body: some View {
        let pending = ask["state"].string == "pending"
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: pending ? "hand.raised.fill" : ask["state"].string == "allowed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(pending ? T.orange : ask["state"].string == "allowed" ? T.green : T.red)
                Text(title).font(T.ui(13, .semibold)).foregroundStyle(T.text)
                Spacer()
            }
            if !pending {
                Text(ask["state"].string == "allowed" ? "Allowed\(answerSuffix)" : "Denied\(answerSuffix)").font(T.ui(12.5)).foregroundStyle(T.text2)
            } else if ask["tool"].string == "AskUserQuestion" {
                questions
            } else if ask["tool"].string == "ExitPlanMode" {
                ScrollView { MarkdownText(text: ask["plan"].string).padding(12) }
                    .frame(maxHeight: 360)
                    .background(RoundedRectangle(cornerRadius: 7).fill(T.panel))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.line, lineWidth: 1))
                decision(yes: "Approve and build", no: "Send back", why: "What to change about the plan (optional)")
            } else {
                if !ask["detail"].string.isEmpty {
                    Text(ask["detail"].string).font(T.mono(11.5)).foregroundStyle(T.text).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(T.panel))
                }
                if let why = ask["reason"].nonEmpty ?? ask["blockedPath"].nonEmpty.map({ "Outside the working directory: \($0)" }) {
                    Text(why).font(T.ui(12)).foregroundStyle(T.text2)
                }
                decision(yes: "Allow", no: "Deny", why: "What to do instead (optional)")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(pending ? T.orange.opacity(0.06) : T.raised.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pending ? T.orange.opacity(0.4) : T.line, lineWidth: 1))
        .disabled(busy.v)
    }

    var answerSuffix: String { ask["answer"].nonEmpty.map { ": \($0)" } ?? "" }

    var title: String {
        switch ask["tool"].string {
        case "AskUserQuestion": return "Claude has a question"
        case "ExitPlanMode": return "Plan ready for review"
        default: return "Allow \(ask["display"].nonEmpty ?? ask["tool"].string)?"
        }
    }

    func decision(yes: String, no: String, why: String) -> some View {
        HStack(spacing: 8) {
            LField(placeholder: why, text: $note.v)
            Button(no) { reply("deny") }.buttonStyle(LButton(danger: true))
            Button(yes) { reply("allow") }.buttonStyle(LButton(primary: true)).keyboardShortcut(.return, modifiers: [.command, .shift])
        }
    }

    var questions: some View {
        let qs = ask["questions"].array
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                let question = q["question"].string
                let multi = q["multiSelect"].bool
                // With several questions, every pick is held until Send, so one
                // click can't submit half the answers.
                let hold = multi || qs.count > 1
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if !q["header"].string.isEmpty { Chip(text: q["header"].string, tint: T.accent) }
                        Text(question).font(T.ui(13, .medium)).foregroundStyle(T.text)
                    }
                    ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, o in
                        let label = o["label"].string
                        let on = picked.v[question]?.contains(label) ?? false
                        Button {
                            if multi {
                                var set = picked.v[question] ?? []
                                if set.contains(label) { set.remove(label) } else { set.insert(label) }
                                picked.v[question] = set
                            } else if hold {
                                picked.v[question] = [label]
                            } else {
                                send([question: label])
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                                    .font(.system(size: 12)).foregroundStyle(on ? T.accent : T.text3).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label).font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                                    if !o["description"].string.isEmpty { Text(o["description"].string).font(T.ui(12)).foregroundStyle(T.text2) }
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? T.accentSoft : T.panel))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? T.accent.opacity(0.5) : T.line, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                LField(placeholder: "Or answer in your own words…", text: $note.v) { sendTyped(qs) }
                Button("Send") { sendTyped(qs) }.buttonStyle(LButton(primary: true))
            }
        }
    }

    func sendTyped(_ qs: [JSON]) {
        if qs.count > 1, let missing = qs.first(where: { (picked.v[$0["question"].string] ?? []).isEmpty }), note.v.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.say("Answer \"\(missing["question"].string.prefix(60))\" too", bad: true)
        }
        var answers: [String: String] = [:]
        for q in qs {
            let question = q["question"].string
            let set = picked.v[question] ?? []
            let value = set.isEmpty ? note.v.trimmingCharacters(in: .whitespaces) : set.sorted().joined(separator: ", ")
            if !value.isEmpty { answers[question] = value }
        }
        guard !answers.isEmpty else { return model.say("Pick an option or type an answer", bad: true) }
        send(answers)
    }

    func send(_ answers: [String: String]) {
        busy.v = true
        Task { await model.answer(run: runId, askId: ask["id"].string, behavior: "allow", answers: answers); busy.v = false }
    }

    func reply(_ behavior: String) {
        busy.v = true
        Task { await model.answer(run: runId, askId: ask["id"].string, behavior: behavior, message: note.v); busy.v = false }
    }
}

// MARK: - Composer

struct JobOption {
    let key: String
    let label: String
    let icon: String
    let choices: [(String, String)]

    static let all: [JobOption] = [
        JobOption(key: "permissionMode", label: "Mode", icon: "lock.shield", choices: [("plan", "Plan"), ("manual", "Manual"), ("acceptEdits", "Edit"), ("bypassPermissions", "Full access")]),
        JobOption(key: "model", label: "Model", icon: "cpu", choices: [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("fable", "Fable")]),
        JobOption(key: "effort", label: "Thinking", icon: "brain", choices: [("", "Auto"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "X-High"), ("max", "Max")]),
    ]
}

struct Composer: View {
    @Environment(AppModel.self) var model
    let runId: String
    @StateObject private var text = Box("")
    @StateObject private var sending = Box(false)
    @FocusState private var focused: Bool

    var body: some View {
        let live = model.sessions.first { $0.id == runId }.map(model.isLive) ?? false
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.v.isEmpty {
                    Text(live ? "Queue a follow-up for when this turn ends…" : "Reply to continue this session…")
                        .font(T.ui(13)).foregroundStyle(T.text3).padding(.horizontal, 5).padding(.top, 1)
                }
                TextEditor(text: $text.v)
                    .font(T.ui(13))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                    .frame(minHeight: 44, maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.top, 10)
            HStack(spacing: 4) {
                ForEach(JobOption.all, id: \.key) { opt in optionMenu(opt) }
                contextToggle
                repoButton
                Spacer()
                Text("⌘↩").font(T.ui(11)).foregroundStyle(T.text3)
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(text.v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? T.text3 : T.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                // Covered by the New Task sheet or ⌘K: ⌘↩ belongs to them.
                .disabled(sending.v || model.composeOpen || model.paletteOpen)
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? T.accent.opacity(0.6) : T.line, lineWidth: 1))
        .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 6)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    func value(_ key: String) -> JSON {
        let own = model.openRun["opts"][key]
        return own.isNull ? model.config["followup"][key] : own
    }

    func optionMenu(_ opt: JobOption) -> some View {
        let current = value(opt.key).string
        let label = opt.choices.first { $0.0 == current }?.1 ?? (current.isEmpty ? "Auto" : current)
        return Menu {
            ForEach(opt.choices, id: \.0) { c in
                Button { Task { await model.setOpts(runId, [opt.key: c.0]) } } label: {
                    if c.0 == current { Label(c.1, systemImage: "checkmark") } else { Text(c.1) }
                }
            }
        } label: {
            ComposerChip(icon: opt.icon, text: label, warn: opt.key == "permissionMode" && current == "bypassPermissions")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(opt.label)
    }

    var contextToggle: some View {
        let on = value("context1m").bool
        return Button { Task { await model.setOpts(runId, ["context1m": !on]) } } label: {
            ComposerChip(icon: "rectangle.stack", text: on ? "1M" : "200k")
        }
        .buttonStyle(.plain).help("Context window")
    }

    var repoButton: some View {
        let dir = value("workdir").string
        return Button {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.directoryURL = URL(fileURLWithPath: dir.isEmpty ? NSHomeDirectory() : dir)
            p.prompt = "Use this folder"
            if p.runModal() == .OK, let u = p.url { Task { await model.setOpts(runId, ["workdir": u.path]) } }
        } label: {
            ComposerChip(icon: "folder", text: dir.isEmpty ? "Repo" : URL(fileURLWithPath: dir).lastPathComponent)
        }
        .buttonStyle(.plain).help(dir.isEmpty ? "Working directory" : dir)
    }

    /// The draft is cleared only once the server has taken it, and only if
    /// you haven't typed something new in the meantime.
    func send() {
        let t = text.v
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending.v = true
        Task {
            if await model.send(t, to: runId), text.v == t { text.v = "" }
            sending.v = false
        }
    }
}

struct ComposerChip: View {
    let icon: String
    let text: String
    var warn = false
    @StateObject private var hover = Box(false)
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(text).font(T.ui(11.5, .medium))
        }
        .foregroundStyle(warn ? T.orange : T.text2)
        .padding(.horizontal, 7).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover.v ? T.hover : .clear))
        .onHover { hover.v = $0 }
    }
}

// MARK: - Properties

struct PropertiesPanel: View {
    @Environment(AppModel.self) var model
    let id: String

    var body: some View {
        let s = model.sessions.first { $0.id == id }
        let task = model.openTask
        let parsed = task["parsed"]
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let s, !s.isOrchestrator {
                    PropSection(title: "Properties") {
                        PropRow(label: "Status") {
                            SessionIcon(session: s, size: 13)
                            Menu {
                                ForEach(Column.allCases) { c in Button(c.label) { Task { await model.move(id, to: c) } } }
                                Divider()
                                Button("Automatic") { Task { await model.move(id, to: nil) } }
                            } label: {
                                Text(model.column(of: s).label + (s.boardPin.isEmpty ? "" : " · pinned")).font(T.ui(12.5)).foregroundStyle(T.text)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        if let st = statusLabels[s.taskStatus] { PropRow(label: "Worker") { Text(st).font(T.ui(12.5)) } }
                        PropRow(label: "Source") { Text(s.isTask ? "Task" : "Slack thread").font(T.ui(12.5)) }
                        PropRow(label: "Project") {
                            Menu {
                                ForEach(model.projects) { p in Button(p.name) { Task { await model.setProject(id, p.id) } } }
                            } label: { Text(model.project(s.project)?.name ?? "—").font(T.ui(12.5)).foregroundStyle(T.text) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        if !s.channel.isEmpty { PropRow(label: "Channel") { Text(s.channel).font(T.ui(12.5)) } }
                        if !s.branch.isEmpty {
                            PropRow(label: "Branch") {
                                Button { copyToPasteboard(s.branch); model.say("Branch name copied") } label: {
                                    Text(s.branch).font(T.mono(11.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
                                }
                                .buttonStyle(.plain).help("Copy")
                            }
                        }
                        if let wt = task["meta"]["worktree"].nonEmpty {
                            PropRow(label: "Worktree") {
                                Button { NSWorkspace.shared.open(URL(fileURLWithPath: wt)) } label: {
                                    Text(URL(fileURLWithPath: wt).lastPathComponent).font(T.mono(11.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
                                }
                                .buttonStyle(.plain).help(wt)
                            }
                            let w = task["worktree"]
                            if !w.isNull && (w["dirty"].bool || w["unpushed"].int > 0) {
                                PropRow(label: "Changes") {
                                    Text([w["dirty"].bool ? "\(w["dirtyFiles"].int) uncommitted" : "", w["unpushed"].int > 0 ? "\(w["unpushed"].int) unpushed" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
                                        .font(T.ui(12.5)).foregroundStyle(T.orange)
                                }
                            }
                        }
                        PropRow(label: "Updated") { Text(Fmt.ago(s.updatedAt) + " ago").font(T.ui(12.5)) }
                        if s.cost > 0 { PropRow(label: "Cost") { Text(Fmt.money(s.cost)).font(T.ui(12.5)).monospacedDigit() } }
                    }

                    PropSection(title: "Links") {
                        if !s.prUrl.isEmpty {
                            let pr = model.pr(for: s.prUrl)
                            LinkRow(icon: "arrow.triangle.pull", text: pr?.title ?? "Pull request #\(s.prNumber)", url: s.prUrl) {
                                if let pr { ChecksIcon(pr: pr).font(.system(size: 11)) }
                            }
                        }
                        if !s.linearUrl.isEmpty || !s.issueKey.isEmpty {
                            let issue = model.issues.first { $0.key == s.issueKey }
                            LinkRow(icon: "circle.lefthalf.filled", text: issue.map { "\($0.key) \($0.title)" } ?? s.issueKey, url: s.linearUrl.isEmpty ? (issue?.url ?? "") : s.linearUrl) {
                                if let issue { StatusIcon(kind: issue.status, color: hexColor(issue.stateColor), size: 11) }
                            }
                        }
                        if !s.permalink.isEmpty { LinkRow(icon: "number", text: "Slack thread", url: s.permalink) { EmptyView() } }
                        ForEach(model.servers(for: s)) { sv in
                            ForEach(sv.ports, id: \.self) { p in
                                LinkRow(icon: "play.circle", text: "localhost:\(p) · \(sv.command)", url: "http://localhost:\(p)") { EmptyView() }
                            }
                        }
                        if s.prUrl.isEmpty && s.linearUrl.isEmpty && s.permalink.isEmpty && s.issueKey.isEmpty {
                            Text("No PR, issue or thread yet").font(T.ui(12)).foregroundStyle(T.text3)
                        }
                    }
                }

                if !parsed.isNull {
                    PropSection(title: "Report") {
                        if !parsed["tldr"].string.isEmpty { MarkdownText(text: parsed["tldr"].string, size: 12.5, color: T.text2) }
                        ForEach(Array(parsed["questions"].array.enumerated()), id: \.offset) { _, q in
                            Label { Text(q.string).font(T.ui(12)) } icon: { Image(systemName: "questionmark.circle").foregroundStyle(T.orange) }
                        }
                        ForEach(Array(parsed["actions"].array.enumerated()), id: \.offset) { _, a in
                            Label { Text(a.string).font(T.ui(12)) } icon: { Image(systemName: "hand.raised").foregroundStyle(T.orange) }
                        }
                    }
                }

                if let s {
                    PropSection(title: "Actions") {
                        VStack(alignment: .leading, spacing: 6) {
                            if !s.isTask && !s.worked && !s.isOrchestrator {
                                Button { Task { await model.start(id) } } label: { Label("Run the pipeline", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(LButton(primary: true))
                            }
                            if s.isTask && !model.isLive(s) && s.taskStatus != "cleaned" {
                                Button { Task { await model.relaunch(id) } } label: { Label("Relaunch worker", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }.buttonStyle(LButton())
                                Button { Task { await model.cleanup(id) } } label: { Label("Clean up worktree", systemImage: "trash").frame(maxWidth: .infinity) }.buttonStyle(LButton())
                            }
                            Button { Task { await model.terminal(id) } } label: { Label("Open in \(model.terminalName)", systemImage: "terminal").frame(maxWidth: .infinity) }.buttonStyle(LButton())
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(T.bg.opacity(0.5))
    }
}

struct PropSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(T.ui(11.5, .medium)).foregroundStyle(T.text3)
            content()
        }
    }
}

struct PropRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label).font(T.ui(12.5)).foregroundStyle(T.text3).frame(width: 78, alignment: .leading)
            content().foregroundStyle(T.text)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }
}

struct LinkRow<Trailing: View>: View {
    let icon: String
    let text: String
    let url: String
    @ViewBuilder let trailing: () -> Trailing
    @StateObject private var hover = Box(false)
    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(T.text3).frame(width: 14)
                Text(text).font(T.ui(12.5)).foregroundStyle(hover.v ? T.text : T.text2).lineLimit(1)
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover.v ? T.hover : T.raised.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.v = $0 }
    }
}

// MARK: - Markdown

func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// Block-level Markdown the way a transcript needs it: paragraphs, headings,
/// lists, quotes and fenced code. Inline styling comes from AttributedString.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 13
    var color: Color = T.text

    enum Block: Hashable {
        case para(String), heading(Int, String), bullet(String, Int), numbered(String, String), quote(String), code(String, String), rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownText.parse(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
        .tint(T.accent)
    }

    @ViewBuilder func block(_ b: Block) -> some View {
        switch b {
        case .para(let s):
            Text(inline(s)).font(T.ui(size)).foregroundStyle(color).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(inline(s)).font(T.ui(level == 1 ? size + 4 : level == 2 ? size + 2 : size + 0.5, .semibold)).foregroundStyle(T.text).padding(.top, 4)
        case .bullet(let s, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(T.ui(size)).foregroundStyle(T.text3)
                Text(inline(s)).font(T.ui(size)).foregroundStyle(color).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).font(T.ui(size)).foregroundStyle(T.text3).monospacedDigit()
                Text(inline(s)).font(T.ui(size)).foregroundStyle(color).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let s):
            Text(inline(s)).font(T.ui(size)).foregroundStyle(T.text2)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 2) }
        case .code(let lang, let s):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    HStack {
                        Text(lang).font(T.ui(11)).foregroundStyle(T.text3)
                        Spacer()
                        Button { copyToPasteboard(s) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10.5)).foregroundStyle(T.text3) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.top, 7)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(s).font(T.mono(11.5)).foregroundStyle(T.text).padding(10)
                }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(T.bg))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.lineSoft, lineWidth: 1))
        case .rule:
            Hairline()
        }
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        var lang = ""
        func flush() {
            if !para.isEmpty { out.append(.para(para.joined(separator: "\n"))); para = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let t = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if t.hasPrefix("```") { out.append(.code(lang, code!.joined(separator: "\n"))); code = nil } else { code!.append(line) }
                continue
            }
            if t.hasPrefix("```") { flush(); lang = String(t.dropFirst(3)); code = []; continue }
            if t.isEmpty { flush(); continue }
            if t == "---" || t == "***" { flush(); out.append(.rule); continue }
            if let r = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                out.append(.heading(t[r].filter { $0 == "#" }.count, String(t[r.upperBound...])))
                continue
            }
            if let r = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                flush()
                let indent = line.prefix { $0 == " " }.count / 2
                out.append(.bullet(String(line[r.upperBound...]), min(indent, 3)))
                continue
            }
            if let r = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                out.append(.numbered(String(t[r].trimmingCharacters(in: .whitespaces)), String(t[r.upperBound...])))
                continue
            }
            if t.hasPrefix(">") { flush(); out.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            para.append(line)
        }
        if let code { out.append(.code(lang, code.joined(separator: "\n"))) }
        flush()
        return out
    }
}
