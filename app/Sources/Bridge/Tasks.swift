import AppKit
import SwiftUI

// A session's subagents and background commands (server/jobs.js folds
// Claude's task_* events into each message's `tasks`): the strip over the
// composer, its list, a card in the transcript where each one started, and
// a tab per task with the subagent's own steps or the command's live output.

// MARK: - Data

struct AgentTask: Identifiable, Hashable {
    let j: JSON
    var id: String { j["id"].string }
    var toolUseId: String { j["toolUseId"].string }
    var isAgent: Bool { j["type"].string != "bash" }
    var title: String { j["description"].nonEmpty ?? (isAgent ? "Subagent" : command) }
    var subagentType: String { j["subagentType"].string }
    var prompt: String { j["prompt"].string }
    var background: Bool { j["background"].bool }
    var status: String { j["status"].nonEmpty ?? "running" }
    var running: Bool { status == "running" }
    var startedAt: Double { j["startedAt"].double / 1000 }
    var endedAt: Double { j["endedAt"].double / 1000 }
    var tokens: Int { j["tokens"].int }
    var toolUses: Int { j["toolUses"].int }
    var lastTool: String { j["lastTool"].string }
    var activity: String { j["activity"].string }
    var summary: String { j["summary"].string }
    var command: String { j["command"].string }
    var steps: [JSON] { j["steps"].array }
    var hasOutput: Bool { !j["outputFile"].string.isEmpty }

    var kindLabel: String {
        if !isAgent { return background ? "Background command" : "Command" }
        let t = subagentType.isEmpty || subagentType == "general-purpose" ? "Subagent" : "\(subagentType) subagent"
        return background ? "\(t) · background" : t
    }

    var icon: String { isAgent ? "person.crop.rectangle.stack" : "terminal" }

    func elapsed(_ now: Date = Date()) -> Double {
        guard startedAt > 0 else { return j["durationMs"].double / 1000 }
        return max(0, (endedAt > 0 ? endedAt : running ? now.timeIntervalSince1970 : startedAt + j["durationMs"].double / 1000) - startedAt)
    }

    static func clock(_ s: Double) -> String {
        let n = Int(s.rounded())
        return n < 60 ? "\(n)s" : n < 3600 ? "\(n / 60)m \(String(format: "%02d", n % 60))s" : "\(n / 3600)h \(String(format: "%02d", n / 60 % 60))m"
    }
}

enum TaskTone {
    static func color(_ status: String) -> Color {
        switch status {
        case "running": return T.yellow
        case "completed": return T.green
        case "failed": return T.red
        default: return T.orange
        }
    }

    static func label(_ status: String) -> String {
        switch status {
        case "running": return "Running"
        case "completed": return "Done"
        case "failed": return "Failed"
        case "stopped": return "Stopped"
        default: return status.capitalized
        }
    }
}

extension AppModel {
    /// Every task in the chat, oldest first.
    func agentTasks(_ runId: String) -> [AgentTask] {
        runData(runId)["messages"].array.flatMap { $0["tasks"].array }.map(AgentTask.init)
    }

    func agentTask(_ runId: String, _ id: String) -> AgentTask? { agentTasks(runId).first { $0.id == id } }

    func openTaskTab(_ runId: String, _ taskId: String, in pane: String? = nil) {
        withAnimation(M.snappy) {
            if !(taskTabs[runId] ?? []).contains(taskId) { taskTabs[runId, default: []].append(taskId) }
            showTab("task-\(taskId)", of: runId, in: pane)
        }
    }

    func closeTaskTab(_ runId: String, _ taskId: String) {
        withAnimation(M.snappy) {
            taskTabs[runId]?.removeAll { $0 == taskId }
            vacate(runId, "task-\(taskId)")
        }
    }

    func stopAgentTask(_ runId: String, _ t: AgentTask) async {
        await act {
            try await API.post("/api/runs/\(API.q(runId))/tasks/\(API.q(t.id))/stop")
            self.say("Stopping \(t.title)")
        }
    }
}

// MARK: - Pieces

/// The task's mark: what it is, ringed in its state.
struct TaskMark: View {
    let task: AgentTask
    var size: CGFloat = 26

    var body: some View {
        let tone = TaskTone.color(task.status)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tone.opacity(0.12))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(tone.opacity(0.35), lineWidth: 1)
            Image(systemName: task.icon).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(tone)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            Group {
                if task.running { LiveIcon(size: size * 0.42) } else {
                    Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : task.status == "failed" ? "xmark.circle.fill" : "stop.circle.fill")
                        .font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(tone)
                }
            }
            .background(Circle().fill(T.panel).padding(-1.5))
            .offset(x: 3, y: 3)
        }
    }
}

struct TaskStatusPill: View {
    let status: String
    var body: some View {
        let tone = TaskTone.color(status)
        HStack(spacing: 5) {
            if status == "running" { LiveIcon(size: 9) } else { Circle().fill(tone).frame(width: 6, height: 6) }
            Text(TaskTone.label(status)).font(T.ui(11, .medium)).foregroundStyle(tone)
        }
        .padding(.horizontal, 7).frame(height: 20)
        .background(Capsule().fill(tone.opacity(0.1)))
        .overlay(Capsule().stroke(tone.opacity(0.25), lineWidth: 1))
        .fixedSize()
    }
}

/// "4 tools · 18.4k tokens · 1m 30s", ticking while it runs.
struct TaskMetrics: View {
    let task: AgentTask
    var font: Font = T.ui(11.5)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let parts = [
                task.isAgent && task.toolUses > 0 ? (task.toolUses == 1 ? "1 tool" : "\(task.toolUses) tools") : "",
                task.tokens > 0 ? "\(Fmt.tokens(task.tokens)) tokens" : "",
                task.elapsed(ctx.date) > 0 ? AgentTask.clock(task.elapsed(ctx.date)) : "",
            ].filter { !$0.isEmpty }
            Text(parts.joined(separator: " · ")).font(font).foregroundStyle(T.text3).monospacedDigit().lineLimit(1)
        }
    }
}

// MARK: - Strip over the composer

/// What's running beside the chat, one click from the list.
struct TaskStrip: View {
    @Environment(AppModel.self) var model
    let runId: String
    @StateObject private var open = Box(false)
    @StateObject private var hover = Box(false)
    @ObservedObject private var data = ComposerData.shared

    var body: some View {
        let all = model.agentTasks(runId)
        let running = all.filter(\.running)
        let lastTurn = model.runData(runId)["messages"].array.last { $0["role"].string == "assistant" }?["tasks"].array.count ?? 0
        if !running.isEmpty || lastTurn > 0 {
            Button { open.v.toggle() } label: { bar(all: all, running: running) }
                .buttonStyle(Pressable(scale: 0.99))
                .hoverBox(hover)
                .popover(isPresented: $open.v, arrowEdge: .top) { TaskListPanel(runId: runId) { open.v = false }.environment(model) }
                .padding(.horizontal, 44)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .onChange(of: data.snapshotOpen) { if data.snapshotOpen == "tasks" { open.v = true } else if open.v && !data.snapshotOpen.isEmpty { open.v = false } }
        }
    }

    func bar(all: [AgentTask], running: [AgentTask]) -> some View {
        let agents = running.filter(\.isAgent).count, cmds = running.count - agents
        let head = running.isEmpty
            ? (all.count == 1 ? "1 task finished" : "\(all.count) tasks finished")
            : [agents > 0 ? (agents == 1 ? "1 subagent" : "\(agents) subagents") : "", cmds > 0 ? (cmds == 1 ? "1 background command" : "\(cmds) background commands") : ""].filter { !$0.isEmpty }.joined(separator: " · ") + " running"
        let lead = running.first ?? all.last
        return HStack(spacing: 10) {
            HStack(spacing: -6) {
                ForEach(Array((running.isEmpty ? Array(all.suffix(3)) : Array(running.prefix(3))).enumerated()), id: \.element.id) { _, t in
                    TaskMark(task: t, size: 20)
                }
            }
            Text(head).font(T.ui(12, .medium)).foregroundStyle(running.isEmpty ? T.text2 : T.text).lineLimit(1).layoutPriority(1)
            if let t = lead, t.running {
                Text(t.activity.isEmpty ? t.title : t.activity).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.tail).shimmer()
            }
            Spacer(minLength: 8)
            Text(open.v ? "Hide" : "View").font(T.ui(11.5, .medium)).foregroundStyle(T.text3)
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(T.text3)
                .rotationEffect(.degrees(open.v ? 180 : 0))
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover.v || open.v ? T.hover : T.raised.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(running.isEmpty ? T.line : T.yellow.opacity(0.25), lineWidth: 1))
        .contentShape(Rectangle())
        .animation(M.snappy, value: running.count)
    }
}

struct TaskListPanel: View {
    @Environment(AppModel.self) var model
    let runId: String
    let dismiss: () -> Void

    var body: some View {
        let all = model.agentTasks(runId)
        let running = all.filter(\.running).reversed()
        let done = all.filter { !$0.running }.reversed()
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right").font(.system(size: 12, weight: .medium)).foregroundStyle(T.text2)
                Text("Tasks").font(T.ui(13, .semibold))
                Text(verbatim: "\(all.count)").font(T.ui(12)).foregroundStyle(T.text3).monospacedDigit()
                Spacer()
                Text("Subagents and background commands").font(T.ui(11)).foregroundStyle(T.text3)
            }
            .padding(.horizontal, 14).frame(height: 40)
            Hairline()
            ScrollView {
                VStack(spacing: 1) {
                    if !running.isEmpty { SectionLabel(text: "Running", count: running.count) }
                    ForEach(Array(running)) { t in row(t) }
                    if !done.isEmpty { SectionLabel(text: "Finished", count: done.count) }
                    ForEach(Array(done)) { t in row(t) }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
        }
        .frame(width: 440)
        .background(T.raised)
    }

    func row(_ t: AgentTask) -> some View {
        TaskListRow(task: t, runId: runId) {
            dismiss()
            model.openTaskTab(runId, t.id)
        }
    }
}

struct TaskListRow: View {
    @Environment(AppModel.self) var model
    let task: AgentTask
    let runId: String
    let open: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let t = task
        HStack(spacing: 10) {
            TaskMark(task: t, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(T.ui(12.5, .medium)).foregroundStyle(T.text).lineLimit(1)
                HStack(spacing: 4) {
                    Text(t.isAgent ? t.kindLabel : t.command).font(t.isAgent ? T.ui(11.5) : T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    Text("·").foregroundStyle(T.text3)
                    TaskMetrics(task: t)
                }
            }
            Spacer(minLength: 6)
            if t.running && hover.v {
                Button { Task { await model.stopAgentTask(runId, t) } } label: { Image(systemName: "stop.fill").font(.system(size: 9)) }
                    .buttonStyle(LButton(danger: true)).help("Stop this task")
                    .transition(.opacity)
            }
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(hover.v ? T.text2 : T.text3)
        }
        .padding(.horizontal, 9).frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.v ? T.selected : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .hoverBox(hover)
        .animation(M.hover, value: hover.v)
    }
}

// MARK: - Card in the transcript

/// Where a subagent or background command started: what it's doing now,
/// how far it got, and the way into its own tab.
struct TaskCard: View {
    @Environment(AppModel.self) var model
    let task: AgentTask
    let runId: String
    @StateObject private var hover = Box(false)

    var body: some View {
        let t = task
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TaskMark(task: t, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t.kindLabel).font(T.ui(11.5, .medium)).foregroundStyle(T.text3).lineLimit(1).fixedSize()
                        TaskMetrics(task: t)
                    }
                    Text(t.title).font(T.ui(12.5, .medium)).foregroundStyle(T.text).lineLimit(1)
                }
                Spacer(minLength: 8)
                if t.running { TaskStatusPill(status: t.status) }
                HStack(spacing: 4) {
                    Text("Open").font(T.ui(11.5, .medium))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(hover.v ? T.text : T.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            detail
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover.v ? T.hover.opacity(0.6) : T.raised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.running ? T.yellow.opacity(0.22) : T.lineSoft, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.openTaskTab(runId, t.id) }
        .hoverBox(hover)
        .help("Open in its own tab")
    }

    @ViewBuilder var detail: some View {
        let t = task
        if t.running, !(t.activity.isEmpty && t.lastTool.isEmpty) {
            Hairline()
            HStack(spacing: 6) {
                if !t.lastTool.isEmpty {
                    Image(systemName: ToolView.icon(t.lastTool)).font(.system(size: 10)).foregroundStyle(T.text3)
                    Text(ToolView.display(t.lastTool)).font(T.ui(11.5, .medium)).foregroundStyle(T.text2)
                }
                Text(t.activity).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1).shimmer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        } else if !t.running, !t.summary.isEmpty, t.isAgent {
            Hairline()
            Text(Session.plain(t.summary)).font(T.ui(11.5)).foregroundStyle(T.text2).lineLimit(2)
                .padding(.horizontal, 10).padding(.vertical, 7)
        }
    }
}

// MARK: - The task's tab

struct TaskView: View {
    @Environment(AppModel.self) var model
    let runId: String
    let taskId: String

    var body: some View {
        if let t = model.agentTask(runId, taskId) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TaskHeader(task: t, runId: runId)
                        if t.isAgent { AgentTaskBody(task: t, runId: runId) } else { CommandTaskBody(task: t, runId: runId) }
                        Color.clear.frame(height: 4).id("end")
                    }
                    .padding(.horizontal, 40).padding(.vertical, 28)
                    .frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                .onChange(of: t.steps.count) { if t.running { withAnimation(M.snappy) { proxy.scrollTo("end", anchor: .bottom) } } }
            }
        } else {
            EmptyState(icon: "square.stack.3d.down.right", title: "This task is gone", detail: "Its chat was cleared or compacted.")
        }
    }
}

struct TaskHeader: View {
    @Environment(AppModel.self) var model
    let task: AgentTask
    let runId: String
    @StateObject private var width = Box<CGFloat>(800)

    /// A narrow split pane: icon buttons, two stats a row.
    var compact: Bool { width.v < 520 }

    var body: some View {
        let t = task
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                TaskMark(task: t, size: compact ? 32 : 40)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(t.kindLabel).font(T.ui(12, .medium)).foregroundStyle(T.text3).lineLimit(1)
                        TaskStatusPill(status: t.status)
                    }
                    Text(t.title).font(T.ui(compact ? 15 : 18, .semibold)).foregroundStyle(T.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                actions
            }
            stats
        }
        .padding(compact ? 14 : 18)
        .card(radius: 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.v = $0 }
    }

    @ViewBuilder var actions: some View {
        let t = task
        HStack(spacing: 6) {
            if t.running {
                if compact {
                    IconButton(icon: "stop.fill", help: "Stop this task", tint: T.red) { Task { await model.stopAgentTask(runId, t) } }
                } else {
                    Button { Task { await model.stopAgentTask(runId, t) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(LButton(danger: true)).fixedSize()
                }
            }
            if compact {
                IconButton(icon: "bubble.left", help: "Back to the chat that started it") { withAnimation(M.snappy) { model.showTab("chat", of: runId) } }
            } else {
                Button { withAnimation(M.snappy) { model.showTab("chat", of: runId) } } label: { Label("Chat", systemImage: "bubble.left") }
                    .buttonStyle(LButton()).fixedSize()
                    .help("Back to the chat that started it")
            }
        }
    }

    var stats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let t = task
            HStack(spacing: 0) {
                stat("Elapsed", t.elapsed(ctx.date) > 0 ? AgentTask.clock(t.elapsed(ctx.date)) : "–")
                if t.isAgent {
                    stat("Tool calls", t.toolUses > 0 ? "\(t.toolUses)" : "–")
                    stat("Tokens", t.tokens > 0 ? Fmt.tokens(t.tokens) : "–")
                    stat("Last tool", t.lastTool.isEmpty ? "–" : ToolView.display(t.lastTool))
                } else {
                    stat("Started", t.startedAt > 0 ? Fmt.clock(t.startedAt) : "–")
                    stat("Finished", t.endedAt > 0 ? Fmt.clock(t.endedAt) : t.running ? "Still running" : "–")
                }
            }
        }
    }

    func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(T.ui(10, .semibold)).tracking(0.4).foregroundStyle(T.text3)
            Text(value).font(T.ui(13, .medium)).foregroundStyle(T.text).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A subagent: what it was asked, every step it took, what it reported.
struct AgentTaskBody: View {
    let task: AgentTask
    let runId: String
    @StateObject private var promptOpen = Box(false)

    var body: some View {
        let t = task
        VStack(alignment: .leading, spacing: 18) {
            if !t.prompt.isEmpty { prompt }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Activity", count: t.steps.count)
                if t.steps.isEmpty {
                    Text(t.running ? "Waiting for its first step…" : "It reported without using any tools.").font(T.ui(12)).foregroundStyle(T.text3).shimmer(t.running)
                }
                ForEach(Array(t.steps.enumerated()), id: \.offset) { _, s in StepView(step: s, runId: runId) }
                if t.j["stepsTruncated"].bool { Text("Later steps weren't kept").font(T.ui(11.5)).foregroundStyle(T.text3) }
                if t.running {
                    HStack(spacing: 7) { LiveIcon(size: 11); Text(t.activity.isEmpty ? "Working…" : t.activity).font(T.ui(12)).foregroundStyle(T.text3).shimmer() }
                }
            }
            if !t.summary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Result")
                    MarkdownText(text: t.summary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.green.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.green.opacity(0.22), lineWidth: 1))
                }
            }
        }
    }

    var prompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(M.snappy) { promptOpen.v.toggle() } } label: {
                HStack(spacing: 6) {
                    SectionTitle(text: "Prompt")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3).rotationEffect(.degrees(promptOpen.v ? 90 : 0))
                    if !promptOpen.v {
                        Text(task.prompt.replacingOccurrences(of: "\n", with: " ")).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.tail)
                            .padding(.leading, 6)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if promptOpen.v {
                Text(task.prompt).font(T.ui(12.5)).foregroundStyle(T.text2).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.raised.opacity(0.6)))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// A background command: the line it runs and its output, live.
struct CommandTaskBody: View {
    let task: AgentTask
    let runId: String
    @StateObject private var output = Box<JSON>(.null)
    @StateObject private var failed = Box("")
    @StateObject private var attempt = Box(0)

    var body: some View {
        let t = task
        VStack(alignment: .leading, spacing: 18) {
            if !t.command.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "Command")
                    HStack(spacing: 8) {
                        Text("$").font(T.mono(12, .bold)).foregroundStyle(T.green)
                        Text(t.command).font(T.mono(12)).foregroundStyle(T.text).textSelection(.enabled)
                        Spacer(minLength: 6)
                        IconButton(icon: "doc.on.doc", help: "Copy", size: 24) { copyToPasteboard(t.command) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.bg.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.line, lineWidth: 1))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(text: "Output")
                    if output.v["truncated"].bool { Text("· last 256 KB").font(T.ui(11.5)).foregroundStyle(T.text3) }
                    Spacer()
                    if !output.v["text"].string.isEmpty { IconButton(icon: "doc.on.doc", help: "Copy output", size: 24) { copyToPasteboard(output.v["text"].string) } }
                }
                if !failed.v.isEmpty && !t.running {
                    MCPLoadError(title: "Couldn't read the output", message: failed.v) { attempt.v += 1 }
                } else {
                    OutputPane(text: TaskOutput.clean(output.v["text"].string), running: t.running, loaded: !output.v.isNull, exists: output.v["exists"].bool)
                }
            }
            if !t.summary.isEmpty && !t.running {
                Label(t.summary, systemImage: t.status == "completed" ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(T.ui(12)).foregroundStyle(t.status == "completed" ? T.text2 : T.orange)
            }
        }
        .task(id: "\(t.id)|\(t.status)|\(attempt.v)") {
            // Tail while it runs; one last read once it's finished.
            repeat {
                do {
                    let o = try await API.get("/api/runs/\(API.q(runId))/tasks/\(API.q(t.id))/output")
                    if o != output.v { output.v = o }
                    failed.v = ""
                } catch {
                    failed.v = error.localizedDescription
                }
                if !t.running { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } while !Task.isCancelled
        }
    }
}

enum TaskOutput {
    /// Colour codes and carriage-return redraws read as noise in a plain view.
    static func clean(_ s: String) -> String {
        let noAnsi = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return noAnsi.split(separator: "\n", omittingEmptySubsequences: false).map { line in line.split(separator: "\r").last.map(String.init) ?? "" }.joined(separator: "\n")
    }
}

struct OutputPane: View {
    let text: String
    let running: Bool
    let loaded: Bool
    let exists: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if text.isEmpty {
                        Text(!loaded ? "Reading…" : running ? "No output yet" : exists ? "It printed nothing" : "The output file is gone")
                            .font(T.mono(11.5)).foregroundStyle(T.text3).shimmer(running || !loaded)
                    } else {
                        Text(text).font(T.mono(11.5)).foregroundStyle(T.text2).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if running && !text.isEmpty {
                        Rectangle().fill(T.text2).frame(width: 7, height: 13).opacity(0.7).padding(.top, 2).shimmer()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .scrollIndicators(.never)
            .frame(minHeight: 160, maxHeight: 520)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.line, lineWidth: 1))
            .onChange(of: text) { if running { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct SectionTitle: View {
    let text: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(T.ui(10.5, .semibold)).tracking(0.5).foregroundStyle(T.text3)
            if let count, count > 0 { Text(verbatim: "\(count)").font(T.ui(10.5)).foregroundStyle(T.text3.opacity(0.8)).monospacedDigit() }
        }
    }
}
