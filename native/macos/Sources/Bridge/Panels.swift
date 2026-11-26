import AppKit
import SwiftUI

// MARK: - Inbox

struct InboxView: View {
    @Environment(AppModel.self) var model
    @StateObject private var tab = Box("decisions")
    @StateObject private var tasks = Box(JSON.null)
    @StateObject private var activity = Box(JSON.null)
    @StateObject private var since = Box("24h")

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Inbox", icon: "tray") {
                SlidingTabs(tabs: [
                    .init(id: "normal", label: "Normal", icon: "bell"),
                    .init(id: "quiet", label: "Quiet", icon: "moon"),
                    .init(id: "away", label: "Away", icon: "airplane"),
                ], selection: Binding(get: { model.inbox["mode"].nonEmpty ?? "normal" }, set: { m in Task { await model.setMode(m) } }))
                .help("Normal relays everything to the orchestrator; quiet only what needs you; away holds it all for one catch-up")
                Button {
                    Task {
                        await model.send("Catch me up on the last \(since.v): what needs me first, then what moved. A few lines.", to: "orchestrator")
                        model.open("orchestrator")
                    }
                } label: { Label("Brief me", systemImage: "sparkles") }
                .buttonStyle(LButton())
            }
            HStack(spacing: 8) {
                SlidingTabs(tabs: [
                    .init(id: "decisions", label: "Needs you", count: model.decisions.count, hot: true),
                    .init(id: "todos", label: "To-dos", count: model.todos.count),
                    .init(id: "tasks", label: "Workers", count: tasks.v["tasks"].array.filter { $0["status"].string != "cleaned" }.count),
                    .init(id: "activity", label: "Activity"),
                ], selection: $tab.v)
                Spacer()
                if tab.v == "activity" {
                    SlidingTabs(tabs: ["3h", "8h", "24h", "3d"].map { .init(id: $0, label: $0) }, selection: $since.v)
                        .onChange(of: since.v) { load() }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(M.snappy, value: tab.v)
            .padding(.horizontal, 20).frame(height: 50)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch tab.v {
                    case "decisions":
                        if model.decisions.isEmpty { EmptyState(icon: "checkmark.circle", title: "You're all caught up", detail: "Questions and requests from workers land here.") }
                        ForEach(model.decisions, id: \.self) { DecisionRow(d: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
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
        .onChange(of: tab.v) { if tab.v == "tasks" || tab.v == "activity" { load() } }
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
            MarkdownText(text: d["text"].string, size: 12.5, color: T.text2)
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
    let run: () -> Void
}

struct CommandPalette: View {
    @Environment(AppModel.self) var model
    @StateObject private var query = Box("")
    @StateObject private var sel = Box(0)
    @StateObject private var hits = Box([JSON]())
    @FocusState private var focused: Bool
    @Namespace private var ns

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(T.text3)
                    TextField("Type a command or search sessions, PRs, issues and transcripts…", text: $query.v)
                        .textFieldStyle(.plain).font(T.ui(14)).focused($focused)
                        .onSubmit { pick(items) }
                }
                .padding(.horizontal, 16).frame(height: 50)
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                                HStack(spacing: 10) {
                                    it.icon.frame(width: 16)
                                    Text(it.title).font(T.ui(13)).foregroundStyle(T.text).lineLimit(1)
                                    if !it.detail.isEmpty { Text(it.detail).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1) }
                                    Spacer()
                                    if !it.hint.isEmpty { Kbd(keys: it.hint) }
                                }
                                .padding(.horizontal, 14).frame(height: 36)
                                .background {
                                    if i == sel.v {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.accent.opacity(0.22))
                                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.accent.opacity(0.35), lineWidth: 1))
                                            .matchedGeometryEffect(id: "palette-sel", in: ns)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { sel.v = i; pick(items) }
                                .onHover { if $0 { sel.v = i } }
                                .id(i)
                            }
                            if items.isEmpty { Text("No results").font(T.ui(12.5)).foregroundStyle(T.text3).padding(20) }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 400)
                    .animation(M.snappy, value: sel.v)
                    .onChange(of: sel.v) { proxy.scrollTo(sel.v) }
                }
            }
            .frame(width: 640)
            .floatingPanel()
            .padding(.top, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { sel.v = min(sel.v + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { sel.v = max(sel.v - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onChange(of: query.v) { sel.v = 0; search() }
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
        guard q.count >= 3 else { hits.v = []; return }
        Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard q == query.v.trimmingCharacters(in: .whitespaces) else { return }
            hits.v = (try? await API.get("/api/search?q=\(API.q(q))"))?["hits"].array ?? []
        }
    }

    var results: [PaletteItem] {
        let q = query.v.lowercased().trimmingCharacters(in: .whitespaces)
        func sym(_ s: String, _ c: Color = T.text2) -> AnyView { AnyView(Image(systemName: s).font(.system(size: 12)).foregroundStyle(c)) }
        var all: [PaletteItem] = [
            PaletteItem(id: "new", icon: sym("square.and.pencil"), title: "New task", hint: "⌘N") { model.composeOpen = true },
            PaletteItem(id: "project", icon: sym("folder.badge.plus"), title: "Add a project…", hint: "⇧⌘P") { model.addProject() },
            PaletteItem(id: "refresh", icon: sym("arrow.clockwise"), title: "Refresh GitHub and Linear", hint: "⌘R") { Task { await model.loadSources(refresh: true) } },
        ]
        for (i, n) in navOrder.enumerated() {
            all.insert(PaletteItem(id: "go-\(n.label)", icon: sym(n.icon), title: "Go to \(n.label)", hint: "⌘\(i + 1)") { model.navigate(n.route) }, at: 1 + i)
        }
        all.insert(PaletteItem(id: "go-settings", icon: sym("gearshape"), title: "Go to Settings", hint: "⌘,") { model.navigate(.settings) }, at: 1 + navOrder.count)
        all.append(PaletteItem(id: "board-view", icon: sym("rectangle.split.3x1"), title: "Sessions as a board") { model.route = .board })
        all.append(PaletteItem(id: "list-view", icon: sym("list.bullet"), title: "Sessions as a list") { model.route = .sessions })
        if case .session(let id) = model.route {
            all.append(PaletteItem(id: "web", icon: sym("globe"), title: "New browser tab", hint: "⌘T") { model.openBrowser(id, url: "") })
            all.append(PaletteItem(id: "prev", icon: sym("chevron.up"), title: "Previous chat", hint: "⌥⌘↑") { model.stepChat(-1) })
            all.append(PaletteItem(id: "next", icon: sym("chevron.down"), title: "Next chat", hint: "⌥⌘↓") { model.stepChat(1) })
            if let s = model.sessions.first(where: { $0.id == id }), s.isOrchestrator, !model.isLive(s) {
                all.append(PaletteItem(id: "clear", icon: sym("eraser"), title: "Clear orchestrator chat") { Task { await model.clearChat(id) } })
            }
            if let nav = model.messageNavs[id] {
                all.append(PaletteItem(id: "prev-msg", icon: sym("arrow.up.to.line"), title: "Previous prompt", hint: "⌥↑") { nav.step(-1) })
                all.append(PaletteItem(id: "next-msg", icon: sym("arrow.down.to.line"), title: "Next prompt", hint: "⌥↓") { nav.step(1) })
            }
        }
        for p in model.projects {
            all.append(PaletteItem(id: "o-\(p.id)", icon: sym("sparkles", T.purple), title: "Orchestrator · \(p.name)") { model.openOrchestrator(p.id) })
            all.append(PaletteItem(id: "n-\(p.id)", icon: sym("square.and.pencil"), title: "New task in \(p.name)") { model.compose(in: p.id) })
        }
        for s in model.boardSessions {
            all.append(PaletteItem(id: "s-\(s.id)", icon: AnyView(SessionIcon(session: s, size: 13)), title: s.title, detail: [s.issueKey, s.snippet].filter { !$0.isEmpty }.joined(separator: " · ")) { model.open(s.id) })
        }
        for pr in model.openPulls + model.reviewPulls {
            all.append(PaletteItem(id: "p-\(pr.url)", icon: AnyView(PRStateIcon(pr: pr)), title: pr.title, detail: "\(pr.repoName)#\(pr.number)") { openURL(pr.url) })
        }
        for i in model.issues where i.active {
            all.append(PaletteItem(id: "i-\(i.key)", icon: AnyView(StatusIcon(kind: i.status, color: hexColor(i.stateColor), size: 13)), title: i.title, detail: i.key) { openURL(i.url) })
        }
        let matched = q.isEmpty ? Array(all.prefix(10)) : all.filter { "\($0.title) \($0.detail)".lowercased().contains(q) }
        let seen = Set(matched.map(\.id))
        let found = hits.v.filter { !seen.contains("s-\($0["runId"].string)") }.map { h in
            PaletteItem(id: "h-\(h["runId"].string)", icon: sym("text.magnifyingglass"), title: h["who"].string, detail: h["snippet"].string) { model.open(h["runId"].string) }
        }
        return Array((matched + found).prefix(40))
    }
}

// MARK: - New task

// ComposeSheet lives in Composer.swift.
