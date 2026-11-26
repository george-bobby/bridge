import AppKit
import SwiftUI

// MARK: - Inbox

struct InboxView: View {
    @Environment(AppModel.self) var model
    @StateObject private var tasks = Box(JSON.null)
    @StateObject private var activity = Box(JSON.null)
    @StateObject private var since = Box("24h")

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            PageHeader(title: "Inbox", icon: "tray") {
                SlidingTabs(tabs: [
                    .init(id: "normal", label: "Normal", icon: "bell"),
                    .init(id: "quiet", label: "Quiet", icon: "moon"),
                    .init(id: "away", label: "Away", icon: "airplane"),
                ], selection: Binding(get: { model.inbox["mode"].nonEmpty ?? "normal" }, set: { m in Task { await model.setMode(m) } }))
                .help("Normal relays everything to the orchestrator; quiet only what needs you; away holds it all for one catch-up")
                Button { Task { await model.brief(since: since.v) } } label: { Label("Brief me", systemImage: "sparkles") }
                    .buttonStyle(LButton())
                    .help("The orchestrator catches you up on the last \(since.v)")
            }
            HStack(spacing: 8) {
                SlidingTabs(tabs: [
                    .init(id: "decisions", label: "Needs you", count: model.decisions.count, hot: true),
                    .init(id: "slack", label: "Slack", count: model.slackOpenCount, hot: model.slackOpenCount > 0),
                    .init(id: "todos", label: "To-dos", count: model.todos.count),
                    .init(id: "tasks", label: "Workers", count: tasks.v["tasks"].array.filter { $0["status"].string != "cleaned" }.count),
                    .init(id: "activity", label: "Activity"),
                ], selection: $m.inboxTab)
                Spacer()
                if model.inboxTab == "slack" { SlackWatchBar().transition(.opacity.combined(with: .move(edge: .trailing))) }
                if model.inboxTab == "activity" {
                    SlidingTabs(tabs: ["3h", "8h", "24h", "3d"].map { .init(id: $0, label: $0) }, selection: $since.v)
                        .onChange(of: since.v) { load() }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(M.snappy, value: model.inboxTab)
            .padding(.horizontal, 20).frame(height: 50)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch model.inboxTab {
                    case "decisions":
                        if model.decisions.isEmpty { EmptyState(icon: "checkmark.circle", title: "You're all caught up", detail: "Questions and requests from workers land here.") }
                        ForEach(model.decisions, id: \.self) { DecisionRow(d: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
                    case "slack":
                        if model.slackItems.isEmpty {
                            EmptyState(icon: "number", title: "Nothing new on Slack", detail: model.slack["configured"].bool ? "Mentions and posts in the channels you watch land here until you start or dismiss them." : "Connect Slack in Settings › Integrations to have mentions land here.")
                        }
                        ForEach(model.slackItems, id: \.self) { SlackItemRow(item: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
                    case "todos":
                        if model.todos.isEmpty { EmptyState(icon: "checklist", title: "No to-dos", detail: "Things only you can do, like merging a PR, show up here.") }
                        ForEach(model.todos, id: \.self) { TodoRow(t: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
                    case "tasks":
                        let list = tasks.v["tasks"].array
                        if list.isEmpty { EmptyState(icon: "person.2", title: "No workers", detail: "Workers the orchestrator spawns are listed here.") }
                        ForEach(list, id: \.self) { TaskRow(t: $0) }
                    default:
                        let ev = activity.v["events"].array.reversed()
                        if ev.isEmpty { EmptyState(icon: "clock", title: "Quiet", detail: "Nothing happened in the last \(since.v).") }
                        ForEach(Array(ev.enumerated()), id: \.offset) { _, e in
                            HoverRow(height: 34) {
                                HStack(spacing: 10) {
                                    Text(Fmt.clock(e["at"].double > 0 ? e["at"].double : e["ts"].double)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 90, alignment: .leading)
                                    Chip(text: e["name"].string)
                                    Text(e["text"].string).font(T.ui(12.5)).foregroundStyle(T.text2).lineLimit(1)
                                    Spacer()
                                }
                            }
                            .onTapGesture { if let id = e["taskId"].nonEmpty { model.open(id) } }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.inboxTab) { if model.inboxTab == "tasks" || model.inboxTab == "activity" { load() } }
    }

    func load() {
        Task {
            if let t = try? await API.get("/api/tasks") { tasks.v = t }
            if let a = try? await API.get("/api/catchup?since=\(since.v)") { activity.v = a }
        }
    }
}

struct DecisionRow: View {
    @Environment(AppModel.self) var model
    let d: JSON
    @StateObject private var answer = Box("")

    var body: some View {
        let kind = d["kind"].string
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind == "action" ? "hand.raised.fill" : kind == "resume" ? "arrow.clockwise.circle.fill" : "questionmark.circle.fill")
                    .foregroundStyle(T.orange)
                Text(d["title"].nonEmpty ?? d["taskId"].string).font(T.ui(13, .semibold))
                Chip(text: kind == "action" ? "Action request" : kind == "resume" ? "Resume" : "Question")
                Spacer()
                Text(Fmt.ago(d["createdAt"].double)).font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            MarkdownText(text: d["text"].string, size: 12.5, color: NT.text2)
            HStack(spacing: 8) {
                LField(placeholder: kind == "action" ? "Anything to add (optional)" : kind == "resume" ? "Note for the worker (optional)" : "Your answer", text: $answer.v) { submit("answer") }
                Button("Tomorrow") { submit("defer", tomorrow()) }.buttonStyle(LButton()).help("Hide until tomorrow")
                Button("Dismiss") { submit("dismiss") }.buttonStyle(LButton())
                Button(kind == "action" ? "Approve" : kind == "resume" ? "Resume" : "Answer") { submit("answer") }.buttonStyle(LButton(primary: true))
                Button { model.open(d["taskId"].string) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(LButton()).help("Open the chat")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.line, lineWidth: 1))
        .padding(.horizontal, 20).padding(.top, 14)
    }

    func tomorrow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date().addingTimeInterval(86400))
    }

    func submit(_ action: String, _ value: String? = nil) {
        let a = value ?? answer.v
        Task { await model.decide(d["id"].string, action: action, answer: a) }
    }
}

/// The watcher's state, and a way to poll now, above the Slack tab.
struct SlackWatchBar: View {
    @Environment(AppModel.self) var model
    @StateObject private var checking = Box(false)

    var body: some View {
        let w = model.slackWatch
        HStack(spacing: 8) {
            if let e = w["lastError"].nonEmpty {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(T.ui(11.5)).foregroundStyle(T.orange).lineLimit(1)
            } else if w["mode"].string == "off" {
                Text("Watching is off").font(T.ui(11.5)).foregroundStyle(T.text3)
            } else if w["lastPollAt"].double > 0 {
                Text(Fmt.checked(w["lastPollAt"].double)).font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            IconButton(icon: "arrow.clockwise", help: "Check Slack now", spinning: checking.v) {
                checking.v = true
                Task { await model.slackCheckNow(); checking.v = false }
            }
            IconButton(icon: "gearshape", help: "Slack watch settings") { model.settingsPane = "integrations"; model.navigate(.settings) }
        }
    }
}

struct SlackItemRow: View {
    @Environment(AppModel.self) var model
    let item: JSON

    var body: some View {
        let skip = item["verdict"].string == "skip"
        VStack(alignment: .leading, spacing: 10) {
            head
            MarkdownText(text: Session.plain(item["text"].string), size: 12.5, color: NT.text2)
                .lineLimit(6)
            if let r = item["reason"].nonEmpty {
                Label("Orchestrator: \(r)", systemImage: "sparkles").font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            actions
        }
        .padding(18)
        .opacity(skip ? 0.6 : 1)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.line, lineWidth: 1))
        .padding(.horizontal, 20).padding(.top, 14)
    }

    var head: some View {
        HStack(spacing: 8) {
            Avatar(name: item["who"].string, url: item["avatar"].string, size: 20)
            Text(item["who"].string).font(T.ui(13, .semibold))
            Text(item["channel"].nonEmpty ?? "Slack").font(T.ui(12)).foregroundStyle(T.text3)
            Chip(text: item["kind"].string == "channel" ? "Channel post" : "Mention", icon: item["kind"].string == "channel" ? "number" : "at")
            if item["count"].int > 1 { Chip(text: "\(item["count"].int) messages") }
            if let v = item["verdict"].nonEmpty { Chip(text: v == "skip" ? "Triage: skip" : "Triage: actionable", icon: v == "skip" ? "minus.circle" : "checkmark.circle") }
            Spacer()
            Text(Fmt.ago(item["ts"].double)).font(T.ui(11.5)).foregroundStyle(T.text3)
        }
    }

    var actions: some View {
        HStack(spacing: 8) {
            Button("Dismiss") { Task { await model.slackItem(item["id"].string, "dismiss") } }.buttonStyle(LButton())
            Spacer()
            if let link = item["permalink"].nonEmpty {
                Button { model.openThread(link) } label: { Label("Read thread", systemImage: "text.bubble") }.buttonStyle(LButton())
                Button { openURL(link) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(LButton()).help("Open in Slack")
                Menu {
                    ForEach(model.projects) { p in
                        Button(p.name) { Task { await model.slackItem(item["id"].string, "start", ["project": p.id]) } }
                    }
                } label: { Label("Hand to Claude", systemImage: "sparkles") } primaryAction: {
                    Task { await model.slackItem(item["id"].string, "start", model.projectFilter.map { ["project": $0] } ?? [:]) }
                }
                .menuStyle(.button).buttonStyle(LButton(primary: true)).fixedSize()
                .help("Run the Slack pipeline on this thread (pick a project from the arrow)")
            }
        }
    }
}

struct TodoRow: View {
    @Environment(AppModel.self) var model
    let t: JSON
    var body: some View {
        HoverRow(height: 46) {
            HStack(spacing: 12) {
                Button { Task { await model.todoDone(t["key"].string) } } label: {
                    Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(T.text3)
                }
                .buttonStyle(.plain).help("Mark done")
                Text(t["text"].string).font(T.ui(13)).foregroundStyle(T.text).lineLimit(2)
                if !t["title"].string.isEmpty { Text(t["title"].string).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1) }
                Spacer()
                if let u = t["url"].nonEmpty { IconButton(icon: "arrow.up.right.square", help: u) { openURL(u) } }
                if let id = t["taskId"].nonEmpty { IconButton(icon: "bubble.left", help: "Open the chat") { model.open(id) } }
            }
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) var model
    let t: JSON
    var body: some View {
        let st = t["status"].string
        HoverRow(height: 46) {
            HStack(spacing: 12) {
                StatusIcon(kind: needsStatuses.contains(st) ? .attention : st == "working" ? .progress : st == "ready-for-review" ? .review : st == "cleaned" ? .done : .todo, size: 13)
                Text(t["title"].nonEmpty ?? t["id"].string).font(T.ui(13, .medium)).lineLimit(1)
                Text(t["branch"].string).font(T.mono(11.5)).foregroundStyle(T.text3).lineLimit(1)
                Spacer()
                Chip(text: statusLabels[st] ?? st)
                if let pr = t["pr"].nonEmpty { IconButton(icon: "arrow.triangle.pull", help: pr) { openURL(pr) } }
            }
        }
        .onTapGesture { model.open(t["id"].string) }
    }
}

// MARK: - Memory

struct MemoryView: View {
    @Environment(AppModel.self) var model
    @StateObject private var list = Box(JSON.null)
    @StateObject private var selected = Box("")
    @StateObject private var text = Box("")
    @StateObject private var saved = Box("")
    @StateObject private var loading = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Memory", subtitle: list.v["project"].nonEmpty.map { "what Claude Code remembers about \($0)" } ?? "", icon: "book.closed") {
                if text.v != saved.v && !selected.v.isEmpty && !loading.v {
                    Button("Revert") { text.v = saved.v }.buttonStyle(LButton())
                    Button("Save") { save() }.buttonStyle(LButton(primary: true)).keyboardShortcut("s")
                }
                IconButton(icon: "folder", help: "Show in Finder") { if let d = list.v["dir"].nonEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: d)) } }
            }
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !list.v.isNull && list.v["files"].array.isEmpty {
                            Text("No memories yet. Claude Code writes them as it learns this project.").font(T.ui(12)).foregroundStyle(T.text3).padding(16)
                        }
                        ForEach(list.v["files"].array, id: \.self) { f in
                            let name = f["name"].string
                            HoverRow(selected: selected.v == name, height: 46) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(f["title"].nonEmpty ?? name).font(T.ui(12.5, .medium)).foregroundStyle(T.text).lineLimit(1)
                                        if !f["type"].string.isEmpty { Chip(text: f["type"].string) }
                                    }
                                    Text(f["desc"].nonEmpty ?? name).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .onTapGesture { open(name) }
                        }
                    }
                }
                .frame(width: 300)
                Rectangle().fill(T.line).frame(width: 1)
                if selected.v.isEmpty {
                    EmptyState(icon: "book.closed", title: "Pick a memory", detail: "Every headless run reads these. Edit them here and press ⌘S.")
                } else {
                    TextEditor(text: $text.v)
                        .font(T.mono(12.5))
                        .scrollContentBackground(.hidden)
                        .padding(18)
                        .disabled(loading.v)
                        .opacity(loading.v ? 0.5 : 1)
                }
            }
        }
        .onAppear { Task { list.v = (try? await API.get("/api/memory")) ?? .null } }
    }

    /// The buffer always belongs to the file it was read from: a read is
    /// applied only if that file is still selected, and editing waits for it.
    func open(_ name: String) {
        guard name != selected.v else { return }
        if text.v != saved.v && !selected.v.isEmpty {
            let a = NSAlert()
            a.messageText = "Discard your changes to \(selected.v)?"
            a.addButton(withTitle: "Discard")
            a.addButton(withTitle: "Keep Editing")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        selected.v = name
        loading.v = true
        Task {
            guard let f = try? await API.get("/api/memory/file?name=\(API.q(name))"), selected.v == name else { return }
            text.v = f["text"].string
            saved.v = text.v
            loading.v = false
        }
    }

    func save() {
        let name = selected.v
        let body = text.v
        guard !loading.v, !name.isEmpty else { return }
        Task {
            await model.act {
                try await API.post("/api/memory/file", ["name": name, "text": body])
                // Only this file's baseline moves, and only if you're still on it.
                if self.selected.v == name { self.saved.v = body }
                self.model.say("Saved \(name)")
            }
        }
    }
}

// MARK: - Command menu (⌘K)

struct PaletteItem: Identifiable {
    let id: String
    let icon: AnyView
    let title: String
    var detail: String = ""
    var hint: String = ""
    var group: String = "Actions"
    let run: () -> Void
}

/// ⌘K: one field for commands, sessions, PRs, issues and transcript search,
/// grouped like Linear's and Raycast's, keyboard first.
struct CommandPalette: View {
    @Environment(AppModel.self) var model
    @StateObject private var query = Box("")
    @StateObject private var sel = Box(0)
    @StateObject private var hits = Box([JSON]())
    @StateObject private var searching = Box(false)
    @FocusState private var focused: Bool

    static let groups = ["Suggestions", "Actions", "Go to", "Sessions", "Pull requests", "Issues", "Transcripts"]

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                field
                Hairline()
                list(items)
                Hairline()
                footer(items.count)
            }
            .frame(width: 680)
            .floatingPanel(radius: 16)
            .padding(.top, 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { move(1, items.count); return .handled }
        .onKeyPress(.upArrow) { move(-1, items.count); return .handled }
        .onKeyPress(.escape) { if query.v.isEmpty { close() } else { query.v = "" }; return .handled }
        .onKeyPress(keys: ["n", "p"], phases: .down) { k in
            guard k.modifiers == .control else { return .ignored }
            move(k.characters == "n" ? 1 : -1, items.count); return .handled
        }
        .onChange(of: query.v) { sel.v = 0; search() }
    }

    var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                .foregroundStyle(query.v.isEmpty ? T.text3 : T.accent)
                .animation(M.hover, value: query.v.isEmpty)
            TextField("", text: $query.v, prompt: Text("Search or type a command…").foregroundStyle(T.text3))
                .textFieldStyle(.plain).font(T.ui(16)).focused($focused)
                .onSubmit { pick(results) }
            if searching.v { ProgressView().controlSize(.small).transition(.opacity) }
            if !query.v.isEmpty {
                Button { query.v = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(T.text3)
                }
                .buttonStyle(.plain).help("Clear").transition(.opacity)
            }
            Kbd(keys: "esc")
        }
        .padding(.horizontal, 18).frame(height: 56)
        .animation(M.hover, value: query.v.isEmpty)
    }

    func list(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                        if i == 0 || items[i - 1].group != it.group {
                            Text(it.group).font(T.ui(11, .semibold)).foregroundStyle(T.text3)
                                .padding(.horizontal, 12).padding(.top, i == 0 ? 6 : 14).padding(.bottom, 5)
                        }
                        PaletteRow(item: it, query: query.v, selected: i == sel.v)
                            .onTapGesture { sel.v = i; pick(items) }
                            .onHover { if $0 { sel.v = i } }
                            .id(i)
                    }
                    if items.isEmpty { empty }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: sel.v) { withAnimation(M.hover) { proxy.scrollTo(sel.v) } }
        }
    }

    var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass").font(.system(size: 22, weight: .light)).foregroundStyle(T.text3)
            Text(query.v.count < 3 ? "Keep typing to search transcripts" : searching.v ? "Searching transcripts…" : "No results for \u{201C}\(query.v)\u{201D}")
                .font(T.ui(13, .medium)).foregroundStyle(T.text2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34)
    }

    func footer(_ count: Int) -> some View {
        HStack(spacing: 14) {
            hintKey("↑↓", "Navigate")
            hintKey("↩", "Open")
            hintKey("esc", query.v.isEmpty ? "Close" : "Clear")
            Spacer()
            Text(verbatim: count == 1 ? "1 result" : "\(count) results").font(T.ui(11.5)).foregroundStyle(T.text3).monospacedDigit()
        }
        .padding(.horizontal, 16).frame(height: 36)
        .background(T.bg.opacity(0.35))
    }

    func hintKey(_ k: String, _ label: String) -> some View {
        HStack(spacing: 6) { Kbd(keys: k); Text(label).font(T.ui(11.5)).foregroundStyle(T.text3) }
    }

    func move(_ d: Int, _ n: Int) {
        guard n > 0 else { return }
        sel.v = (sel.v + d + n) % n
    }

    func close() { model.paletteOpen = false }

    func pick(_ items: [PaletteItem]) {
        guard items.indices.contains(sel.v) else { return }
        let it = items[sel.v]
        close()
        it.run()
    }

    func search() {
        let q = query.v.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { hits.v = []; searching.v = false; return }
        searching.v = true
        Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard q == query.v.trimmingCharacters(in: .whitespaces) else { return }
            hits.v = (try? await API.get("/api/search?q=\(API.q(q))"))?["hits"].array ?? []
            if q == query.v.trimmingCharacters(in: .whitespaces) { searching.v = false }
        }
    }

    var results: [PaletteItem] {
        let q = query.v.lowercased().trimmingCharacters(in: .whitespaces)
        func sym(_ s: String, _ c: Color = T.text2) -> AnyView { AnyView(Image(systemName: s).font(.system(size: 12, weight: .medium)).foregroundStyle(c)) }
        var all: [PaletteItem] = [
            PaletteItem(id: "new", icon: sym("square.and.pencil"), title: "New task", hint: "⌘N", group: "Suggestions") { model.composeOpen = true },
            PaletteItem(id: "import", icon: sym("square.and.arrow.down.on.square"), title: "Import a chat from Claude Code, Codex, Cursor or Devin…", hint: "⇧⌘I", group: "Suggestions") { model.importOpen = true },
            PaletteItem(id: "project", icon: sym("folder.badge.plus"), title: "Add a project…", hint: "⇧⌘P") { model.addProject() },
            PaletteItem(id: "refresh", icon: sym("arrow.clockwise"), title: "Refresh GitHub and Linear", hint: "⌘R") { Task { await model.loadSources(refresh: true) } },
        ]
        for (i, n) in navOrder.enumerated() {
            all.append(PaletteItem(id: "go-\(n.label)", icon: sym(n.icon), title: n.label, hint: "⌘\(i + 1)", group: "Go to") { model.navigate(n.route) })
        }
        all.append(PaletteItem(id: "go-settings", icon: sym("gearshape"), title: "Settings", hint: "⌘,", group: "Go to") { model.navigate(.settings) })
        all.append(PaletteItem(id: "board-view", icon: sym("rectangle.split.3x1"), title: "Sessions as a board", group: "Go to") { model.route = .board })
        all.append(PaletteItem(id: "list-view", icon: sym("list.bullet"), title: "Sessions as a list", group: "Go to") { model.route = .sessions })
        if case .session(let id) = model.route {
            all.append(PaletteItem(id: "web", icon: sym("globe"), title: "New browser tab", hint: "⌘T") { model.openBrowser(id, url: "") })
            all.append(PaletteItem(id: "prev", icon: sym("chevron.up"), title: "Previous chat", hint: "⌥⌘↑") { model.stepChat(-1) })
            all.append(PaletteItem(id: "next", icon: sym("chevron.down"), title: "Next chat", hint: "⌥⌘↓") { model.stepChat(1) })
            if let s = model.sessions.first(where: { $0.id == id }), model.isLive(s) {
                all.insert(PaletteItem(id: "stop", icon: sym("stop.circle", T.red), title: "Stop the running turn", hint: "⌘.", group: "Suggestions") { Task { await model.stop(id) } }, at: 0)
            }
            if let s = model.sessions.first(where: { $0.id == id }), s.isOrchestrator {
                all.append(PaletteItem(id: "brief", icon: sym("sparkles", T.purple), title: "Brief me", group: "Suggestions") { Task { await model.brief(id) } })
            }
            if let s = model.sessions.first(where: { $0.id == id }), s.isOrchestrator, !model.isLive(s) {
                all.append(PaletteItem(id: "clear", icon: sym("eraser"), title: "Clear orchestrator chat") { Task { await model.clearChat(id) } })
            }
            if let nav = model.messageNavs[id] {
                all.append(PaletteItem(id: "prev-msg", icon: sym("arrow.up.to.line"), title: "Previous prompt", hint: "⌥↑") { nav.step(-1) })
                all.append(PaletteItem(id: "next-msg", icon: sym("arrow.down.to.line"), title: "Next prompt", hint: "⌥↓") { nav.step(1) })
            }
        }
        for p in model.projects {
            all.append(PaletteItem(id: "o-\(p.id)", icon: sym("sparkles", T.purple), title: "Orchestrator · \(p.name)", group: "Go to") { model.openOrchestrator(p.id) })
            all.append(PaletteItem(id: "n-\(p.id)", icon: sym("square.and.pencil"), title: "New task in \(p.name)") { model.compose(in: p.id) })
        }
        for s in model.boardSessions {
            all.append(PaletteItem(id: "s-\(s.id)", icon: AnyView(SessionIcon(session: s, size: 13)), title: s.title, detail: [s.issueKey, s.snippet].filter { !$0.isEmpty }.joined(separator: " · "), group: "Sessions") { model.open(s.id) })
        }
        for pr in model.openPulls + model.reviewPulls {
            all.append(PaletteItem(id: "p-\(pr.url)", icon: AnyView(PRStateIcon(pr: pr)), title: pr.title, detail: "\(pr.repoName)#\(pr.number)", group: "Pull requests") { openURL(pr.url) })
        }
        for i in model.issues where i.active {
            all.append(PaletteItem(id: "i-\(i.key)", icon: AnyView(StatusIcon(kind: i.status, color: hexColor(i.stateColor), size: 13)), title: i.title, detail: i.key, group: "Issues") { openURL(i.url) })
        }
        let order = Dictionary(uniqueKeysWithValues: Self.groups.enumerated().map { ($1, $0) })
        func sorted(_ xs: [PaletteItem]) -> [PaletteItem] {
            xs.enumerated().sorted { (order[$0.element.group] ?? 9, $0.offset) < (order[$1.element.group] ?? 9, $1.offset) }.map(\.element)
        }
        if q.isEmpty {
            // Nothing typed: what you'd reach for, the pages, the latest sessions.
            let pick = all.filter { $0.group == "Suggestions" } + all.filter { $0.group == "Go to" } + Array(all.filter { $0.group == "Sessions" }.prefix(5))
            return sorted(pick)
        }
        let words = q.split(separator: " ").map(String.init)
        let matched = all.filter { it in
            let hay = "\(it.title) \(it.detail) \(it.group)".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        let seen = Set(matched.map(\.id))
        let found = hits.v.filter { !seen.contains("s-\($0["runId"].string)") }.map { h in
            PaletteItem(id: "h-\(h["runId"].string)", icon: sym("text.magnifyingglass"), title: h["who"].string, detail: h["snippet"].string, group: "Transcripts") { model.open(h["runId"].string) }
        }
        return Array(sorted(matched + found).prefix(60))
    }
}

/// A palette row: an icon tile, the title with the query's words lit, detail, hint.
struct PaletteRow: View {
    let item: PaletteItem
    let query: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            item.icon
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? T.accent.opacity(0.18) : T.raised))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.line, lineWidth: selected ? 0 : 1))
            Text(lit(item.title)).font(T.ui(13.5)).foregroundStyle(T.text).lineLimit(1)
            if !item.detail.isEmpty { Text(item.detail).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 8)
            if !item.hint.isEmpty { Kbd(keys: item.hint) }
            if selected {
                Image(systemName: "return").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(T.text2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).frame(height: 42)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(T.selected)
                    .overlay(alignment: .leading) { Capsule().fill(T.accent).frame(width: 3, height: 18).padding(.leading, 1) }
            }
        }
        .contentShape(Rectangle())
    }

    /// The title with every query word bold.
    func lit(_ s: String) -> AttributedString {
        var out = AttributedString(s)
        for w in query.split(separator: " ") where !w.isEmpty {
            var from = s.startIndex
            while let r = s.range(of: w, options: .caseInsensitive, range: from..<s.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: out), let hi = AttributedString.Index(r.upperBound, within: out) {
                    out[lo..<hi].font = T.ui(13.5, .bold)
                }
                from = r.upperBound
            }
        }
        return out
    }
}

// MARK: - New task

// ComposeSheet lives in Composer.swift.
