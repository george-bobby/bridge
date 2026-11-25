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
                Picker("", selection: Binding(get: { model.inbox["mode"].nonEmpty ?? "normal" }, set: { m in Task { await model.setMode(m) } })) {
                    Text("Normal").tag("normal")
                    Text("Quiet").tag("quiet")
                    Text("Away").tag("away")
                }
                .pickerStyle(.segmented).frame(width: 200).controlSize(.small)
                .help("Normal relays everything to the orchestrator; quiet only what needs you; away holds it all for one catch-up")
                Button("Brief me") {
                    Task {
                        await model.send("Catch me up on the last \(since.v): what needs me first, then what moved. A few lines.", to: "orchestrator")
                        model.open("orchestrator")
                    }
                }
                .buttonStyle(LButton())
            }
            HStack(spacing: 2) {
                TabButton(label: "Needs you", count: model.decisions.count, hot: true, on: tab.v == "decisions") { tab.v = "decisions" }
                TabButton(label: "To-dos", count: model.todos.count, on: tab.v == "todos") { tab.v = "todos" }
                TabButton(label: "Workers", count: tasks.v["tasks"].array.filter { $0["status"].string != "cleaned" }.count, on: tab.v == "tasks") { tab.v = "tasks"; load() }
                TabButton(label: "Activity", count: 0, on: tab.v == "activity") { tab.v = "activity"; load() }
                Spacer()
                if tab.v == "activity" {
                    Picker("", selection: $since.v) { ForEach(["3h", "8h", "24h", "3d"], id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 170).controlSize(.small)
                        .onChange(of: since.v) { load() }
                }
            }
            .padding(.horizontal, 12).frame(height: 40)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch tab.v {
                    case "decisions":
                        if model.decisions.isEmpty { EmptyState(icon: "checkmark.circle", title: "You're all caught up", detail: "Questions and requests from workers land here.") }
                        ForEach(model.decisions, id: \.self) { DecisionRow(d: $0) }
                    case "todos":
                        if model.todos.isEmpty { EmptyState(icon: "checklist", title: "No to-dos", detail: "Things only you can do, like merging a PR, show up here.") }
                        ForEach(model.todos, id: \.self) { TodoRow(t: $0) }
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
    }

    func load() {
        Task {
            if let t = try? await API.get("/api/tasks") { tasks.v = t }
            if let a = try? await API.get("/api/catchup?since=\(since.v)") { activity.v = a }
        }
    }
}

struct TabButton: View {
    let label: String
    let count: Int
    var hot = false
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(T.ui(12.5, on ? .medium : .regular)).foregroundStyle(on ? T.text : T.text2)
                if count > 0 {
                    Text(verbatim: "\(count)").font(T.ui(11, .semibold)).foregroundStyle(hot ? .white : T.text2)
                        .padding(.horizontal, 5).frame(minHeight: 16)
                        .background(Capsule().fill(hot ? T.orange : T.raised))
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? T.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .padding(16)
        .overlay(alignment: .bottom) { Hairline() }
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
        HoverRow(height: 40) {
            HStack(spacing: 10) {
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
        HoverRow(height: 40) {
            HStack(spacing: 10) {
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

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Memory", subtitle: list.v["project"].nonEmpty.map { "what Claude Code remembers about \($0)" } ?? "", icon: "book.closed") {
                if text.v != saved.v && !selected.v.isEmpty {
                    Button("Revert") { text.v = saved.v }.buttonStyle(LButton())
                    Button("Save") { save() }.buttonStyle(LButton(primary: true)).keyboardShortcut("s")
                }
                IconButton(icon: "folder", help: "Show in Finder") { if let d = list.v["dir"].nonEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: d)) } }
            }
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
                }
            }
        }
        .onAppear { Task { list.v = (try? await API.get("/api/memory")) ?? .null } }
    }

    func open(_ name: String) {
        selected.v = name
        Task {
            let f = (try? await API.get("/api/memory/file?name=\(API.q(name))")) ?? .null
            text.v = f["text"].string
            saved.v = text.v
        }
    }

    func save() {
        let name = selected.v
        let body = text.v
        Task {
            await model.act {
                try await API.post("/api/memory/file", ["name": name, "text": body])
                self.saved.v = body
                self.model.say("Saved \(name)")
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        TabView {
            Form {
                Section("Slack pipeline") {
                    toggle("Draft the reply in the thread", "reply", hint: "Posted only after you approve it")
                    toggle("Offer a Linear ticket", "createLinearIssue", hint: "Created only after you approve it")
                    toggle("Wait for bot review, then resolve", "botReview")
                    toggle("Propose memories", "saveToMemory", hint: "Nothing is saved without your approval")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Pipeline", systemImage: "arrow.triangle.branch") }

            Form {
                Section("New sessions start with") {
                    ForEach(JobOption.all, id: \.key) { opt in
                        Picker(opt.label, selection: Binding(get: { model.config["followup"][opt.key].string }, set: { v in save(["followup": [opt.key: v]]) })) {
                            ForEach(opt.choices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                    Toggle("1M context", isOn: Binding(get: { model.config["followup"]["context1m"].bool }, set: { v in save(["followup": ["context1m": v]]) }))
                    LabeledContent("Repository") {
                        HStack {
                            Text(model.config["followup"]["workdir"].nonEmpty ?? "Not set").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            Button("Choose…") {
                                let p = NSOpenPanel()
                                p.canChooseDirectories = true
                                p.canChooseFiles = false
                                if p.runModal() == .OK, let u = p.url { save(["followup": ["workdir": u.path]]) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Sessions", systemImage: "cpu") }

            Form {
                Section("Workers") {
                    Toggle("Relay outcomes to the orchestrator", isOn: Binding(get: { model.config["harness"]["relay"].bool }, set: { v in save(["harness": ["relay": v]]) }))
                    Stepper("At most \(model.config["harness"]["maxWorkers"].int) workers", value: Binding(get: { model.config["harness"]["maxWorkers"].int }, set: { v in save(["harness": ["maxWorkers": v]]) }), in: 1...12)
                    Stepper("At most \(model.config["harness"]["maxPerRepo"].int) per repo", value: Binding(get: { model.config["harness"]["maxPerRepo"].int }, set: { v in save(["harness": ["maxPerRepo": v]]) }), in: 1...12)
                    Stepper("Stalled after \(model.config["harness"]["stallMinutes"].int) min of silence", value: Binding(get: { model.config["harness"]["stallMinutes"].int }, set: { v in save(["harness": ["stallMinutes": v]]) }), in: 5...120, step: 5)
                }
                Section("Server") {
                    LabeledContent("Address", value: API.base.absoluteString)
                    LabeledContent("Status", value: model.connected ? "Connected" : "Offline")
                    Button("Open the legacy web UI") { openURL(API.base.absoluteString) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Harness", systemImage: "gearshape.2") }
        }
        .frame(width: 520, height: 400)
    }

    func toggle(_ label: String, _ key: String, hint: String = "") -> some View {
        Toggle(isOn: Binding(get: { model.config[key].bool }, set: { v in save([key: v]) })) {
            VStack(alignment: .leading) {
                Text(label)
                if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    func save(_ patch: [String: Any]) { Task { await model.saveConfig(patch) } }
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

    var body: some View {
        let items = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { close() }
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
                                .background(RoundedRectangle(cornerRadius: 6).fill(i == sel.v ? T.selected : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { sel.v = i; pick(items) }
                                .id(i)
                            }
                            if items.isEmpty { Text("No results").font(T.ui(12.5)).foregroundStyle(T.text3).padding(20) }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: sel.v) { proxy.scrollTo(sel.v) }
                }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 12).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
            .padding(.top, 110)
        }
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
            PaletteItem(id: "home", icon: sym("house"), title: "Go to Home", hint: "⌘1") { model.route = .home },
            PaletteItem(id: "inbox", icon: sym("tray"), title: "Go to Inbox", hint: "⌘2") { model.route = .inbox },
            PaletteItem(id: "board", icon: sym("rectangle.split.3x1"), title: "Go to Board", hint: "⌘3") { model.route = .board },
            PaletteItem(id: "sessions", icon: sym("bubble.left.and.text.bubble.right"), title: "Go to Sessions", hint: "⌘4") { model.route = .sessions },
            PaletteItem(id: "pulls", icon: sym("arrow.triangle.pull"), title: "Go to Pull requests", hint: "⌘5") { model.route = .pulls },
            PaletteItem(id: "linear", icon: sym("circle.lefthalf.filled"), title: "Go to Linear", hint: "⌘6") { model.route = .linear },
            PaletteItem(id: "memory", icon: sym("book.closed"), title: "Go to Memory", hint: "⌘7") { model.route = .memory },
            PaletteItem(id: "orch", icon: sym("sparkles", T.purple), title: "Open the orchestrator", hint: "⌘O") { model.open("orchestrator") },
            PaletteItem(id: "refresh", icon: sym("arrow.clockwise"), title: "Refresh GitHub and Linear", hint: "⌘R") { Task { await model.loadSources(refresh: true) } },
        ]
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

struct ComposeSheet: View {
    @Environment(AppModel.self) var model
    @StateObject private var text = Box("")
    @StateObject private var direct = Box(false)
    @StateObject private var repo = Box("")
    @StateObject private var busy = Box(false)
    @FocusState private var focused: Bool

    var isSlack: Bool { text.v.trimmingCharacters(in: .whitespaces).range(of: #"^https://[^/]*slack\.com/archives/"#, options: .regularExpression) != nil }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.composeOpen = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Logo(size: 16)
                    Text("New task").font(T.ui(13, .medium))
                    Spacer()
                    IconButton(icon: "xmark", help: "Close (Esc)") { model.composeOpen = false }
                }
                .padding(.horizontal, 16).padding(.top, 14)
                ZStack(alignment: .topLeading) {
                    if text.v.isEmpty {
                        Text("Describe what you want built, or paste a Slack thread link…").font(T.ui(15)).foregroundStyle(T.text3).padding(.horizontal, 5)
                    }
                    TextEditor(text: $text.v).font(T.ui(15)).scrollContentBackground(.hidden).focused($focused)
                }
                .frame(height: 150)
                .padding(.horizontal, 12).padding(.top, 12)
                Hairline()
                HStack(spacing: 8) {
                    if isSlack {
                        Chip(text: "Slack thread: runs the pipeline", icon: "number", tint: T.slack)
                    } else {
                        Picker("", selection: $direct.v) {
                            Text("Orchestrator writes the brief").tag(false)
                            Text("Start a worker now").tag(true)
                        }
                        .pickerStyle(.segmented).controlSize(.small).fixedSize()
                        if direct.v {
                            Button {
                                let p = NSOpenPanel()
                                p.canChooseDirectories = true
                                p.canChooseFiles = false
                                if p.runModal() == .OK, let u = p.url { repo.v = u.path }
                            } label: {
                                ComposerChip(icon: "folder", text: URL(fileURLWithPath: repo.v.isEmpty ? model.defaultWorkdir : repo.v).lastPathComponent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    Button {
                        busy.v = true
                        Task {
                            if await model.create(text.v, direct: direct.v, repo: repo.v) { model.composeOpen = false }
                            busy.v = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if busy.v { ProgressView().controlSize(.mini) }
                            Text(isSlack ? "Run" : direct.v ? "Start worker" : "Send")
                            Text("⌘↩").opacity(0.6)
                        }
                    }
                    .buttonStyle(LButton(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy.v || text.v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
            }
            .frame(width: 680)
            .background(RoundedRectangle(cornerRadius: 12).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
            .padding(.top, 110)
        }
        .onAppear { focused = true; text.v = model.composeText; model.composeText = "" }
        .onKeyPress(.escape) { model.composeOpen = false; return .handled }
    }
}
