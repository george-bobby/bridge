import AppKit
import SwiftUI

// MARK: - Memory

/// One project's shared memory (`model.memoryProject`): the MEMORY.md index and
/// topic files every agent reads, plus the proposals agents filed, which become
/// memories only when approved here. Pick the project in the header.
struct MemoryView: View {
    @Environment(AppModel.self) var model
    @StateObject private var projectOpen = Box(false)
    @StateObject private var list = Box(JSON.null)
    /// "m:<file>" for a memory, "p:<file>" for a proposal.
    @StateObject private var selected = Box("")
    @StateObject private var text = Box("")
    @StateObject private var saved = Box("")
    @StateObject private var loading = Box(false)

    var name: String { String(selected.v.dropFirst(2)) }
    var isProposal: Bool { selected.v.hasPrefix("p:") }
    var dirty: Bool { text.v != saved.v && !selected.v.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Memory", subtitle: "shared by Claude, Codex, Cursor and Devin in \(model.project(model.memoryProject)?.name ?? "this project")", icon: "book.closed") {
                projectPicker
                actions
                IconButton(icon: "folder", help: "Show in Finder") { if let d = list.v["dir"].nonEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: d)) } }
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 300)
                Rectangle().fill(T.line).frame(width: 1)
                editor
            }
        }
        .onAppear { if model.project(model.memoryProject) == nil { model.openMemory() } }
        .task(id: model.memoryProject) { if !model.memoryProject.isEmpty { await reload() } }
    }

    var projectPicker: some View {
        Button { projectOpen.v.toggle() } label: {
            PickerChip(text: model.project(model.memoryProject)?.name ?? "Project", open: projectOpen.v) {
                if let p = model.project(model.memoryProject) { ProjectBadge(project: p, size: 14) }
            }
        }
        .buttonStyle(Pressable(scale: 0.97))
        .popover(isPresented: $projectOpen.v, arrowEdge: .bottom) {
            ProjectPanel(current: model.memoryProject) { id in projectOpen.v = false; switchProject(id) } add: { projectOpen.v = false; model.addProject() }
                .environment(model)
        }
    }

    @ViewBuilder var actions: some View {
        if !selected.v.isEmpty && !loading.v {
            if isProposal {
                Button("Discard") { discard() }.buttonStyle(LButton(kind: .danger))
                Button("Approve") { approve() }.buttonStyle(LButton(kind: .primary)).keyboardShortcut("s")
            } else {
                if dirty {
                    Button("Revert") { text.v = saved.v }.buttonStyle(LButton())
                    Button("Save") { save() }.buttonStyle(LButton(kind: .primary)).keyboardShortcut("s")
                }
                if name != "MEMORY.md" { IconButton(icon: "trash", help: "Delete this memory") { delete() } }
            }
        }
    }

    var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let proposals = list.v["proposals"].array
                if !proposals.isEmpty {
                    SectionLabel(text: "Proposed", count: proposals.count)
                    ForEach(proposals, id: \.self) { row($0, key: "p:") }
                    SectionLabel(text: "Memories")
                }
                if !list.v.isNull && list.v["files"].array.isEmpty {
                    Text("No memories yet. Agents propose them as they learn this project; approve them here.").font(T.ui(12)).foregroundStyle(T.text3).padding(16)
                }
                ForEach(list.v["files"].array, id: \.self) { row($0, key: "m:") }
            }
        }
    }

    func row(_ f: JSON, key: String) -> some View {
        let file = f["name"].string
        return HoverRow(selected: selected.v == key + file, height: 46) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f["title"].nonEmpty ?? file).font(T.ui(12.5, .medium)).foregroundStyle(T.text).lineLimit(1)
                    if key == "p:" { Chip(text: f["updates"].bool ? "update" : "new") }
                    if !f["type"].string.isEmpty { Chip(text: f["type"].string) }
                }
                Text(f["desc"].nonEmpty ?? file).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onTapGesture { open(key + file) }
    }

    @ViewBuilder var editor: some View {
        if selected.v.isEmpty {
            EmptyState(icon: "book.closed", title: "Pick a memory", detail: "Every agent reads these. Edit one and press ⌘S; approve a proposal to keep it.")
        } else {
            TextEditor(text: $text.v)
                .font(T.mono(12.5))
                .scrollContentBackground(.hidden)
                .padding(18)
                .disabled(loading.v)
                .opacity(loading.v ? 0.5 : 1)
        }
    }

    var q: String { "project=\(API.q(model.memoryProject))" }

    func reload() async {
        let out = (try? await API.get("/api/memory?\(q)")) ?? .null
        list.v = out.isNull ? .obj(["files": .arr([]), "proposals": .arr([])]) : out
    }

    /// Asks before throwing away unsaved edits; true when it's fine to move on.
    func leave() -> Bool {
        guard dirty else { return true }
        let a = NSAlert()
        a.messageText = "Discard your changes to \(name)?"
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Keep Editing")
        return a.runModal() == .alertFirstButtonReturn
    }

    func clear() { selected.v = ""; text.v = ""; saved.v = "" }

    func switchProject(_ id: String) {
        guard id != model.memoryProject, leave() else { return }
        clear()
        list.v = .null
        model.memoryProject = id
    }

    /// The buffer always belongs to the file it was read from: a read is
    /// applied only if that file is still selected, and editing waits for it.
    func open(_ key: String) {
        guard key != selected.v, leave() else { return }
        selected.v = key
        loading.v = true
        let proposed = key.hasPrefix("p:") ? "&proposed=1" : ""
        Task {
            guard let f = try? await API.get("/api/memory/file?name=\(API.q(String(key.dropFirst(2))))\(proposed)&\(q)"), selected.v == key else { return }
            text.v = f["text"].string
            saved.v = text.v
            loading.v = false
        }
    }

    func post(_ verb: String, _ extra: [String: String] = [:], done: String, keep: Bool = false) {
        let file = name
        var body = ["name": file, "project": model.memoryProject]
        body.merge(extra) { $1 }
        Task {
            await model.act {
                try await API.post("/api/memory/\(verb)", body)
                if keep { if self.name == file { self.saved.v = body["text"] ?? "" } } else { self.clear() }
                await self.reload()
                self.model.say("\(done) \(file)")
            }
        }
    }

    func save() { guard !loading.v, !name.isEmpty else { return }; post("file", ["text": text.v], done: "Saved", keep: true) }
    func approve() { post("approve", ["text": text.v], done: "Approved") }
    func discard() { post("discard", done: "Discarded") }

    func delete() {
        let a = NSAlert()
        a.messageText = "Delete \(name)?"
        a.informativeText = "Every agent stops seeing it. This can't be undone."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { post("delete", done: "Deleted") }
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
    /// More words it's found by, not shown (a setting's search words).
    var words: String = ""
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

    static let groups = ["Suggestions", "Actions", "Go to", "Settings", "Sessions", "Pull requests", "Issues", "Transcripts"]

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
        .onAppear {
            focused = true
            // Dev aid: BRIDGE_SNAPSHOT_PALETTE_QUERY=theme snapshots a search.
            if let q = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_PALETTE_QUERY"], ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_DIR"] != nil { query.v = q }
        }
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
                            .id(it.id)
                    }
                    if items.isEmpty { empty }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: sel.v) { if items.indices.contains(sel.v) { withAnimation(M.hover) { proxy.scrollTo(items[sel.v].id) } } }
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
            let out = (try? await API.get("/api/search?q=\(API.q(q))"))?["hits"].array ?? []
            // A slower answer to an older query never replaces a newer one.
            guard q == query.v.trimmingCharacters(in: .whitespaces) else { return }
            hits.v = out
            searching.v = false
        }
    }

    var results: [PaletteItem] {
        let q = query.v.lowercased().trimmingCharacters(in: .whitespaces)
        func sym(_ s: String, _ c: Color = T.text2) -> AnyView { AnyView(Image(systemName: s).font(.system(size: 12, weight: .medium)).foregroundStyle(c)) }
        var all: [PaletteItem] = [
            PaletteItem(id: "new", icon: sym("square.and.pencil"), title: "New task", hint: "⌘N", group: "Suggestions") { model.composeOpen = true },
            PaletteItem(id: "import", icon: sym("square.and.arrow.down.on.square"), title: "Import chat", detail: "Claude Code, Codex, Cursor or Devin", hint: "⇧⌘I", group: "Suggestions") { model.openImport() },
            PaletteItem(id: "project", icon: sym("folder.badge.plus"), title: "Add a project…") { model.addProject() },
            PaletteItem(id: "refresh", icon: sym("arrow.clockwise"), title: "Refresh GitHub and Linear", hint: "⌘R") { Task { await model.loadSources(refresh: true) } },
        ]
        all.append(PaletteItem(id: "term-toggle", icon: sym("terminal"), title: "Toggle terminal", hint: "⌃`", group: "Suggestions") { ConsoleStore.shared.toggle(model) })
        all.append(PaletteItem(id: "term-new", icon: sym("plus.rectangle"), title: "New terminal", hint: "⌃⇧`") { ConsoleStore.shared.add(model.contextFolder) })
        all.append(PaletteItem(id: "panel", icon: sym("rectangle.bottomthird.inset.filled"), title: "Toggle panel", hint: "⌘J") { ConsoleStore.shared.togglePanel(model) })
        if !ConsoleStore.shared.shells.isEmpty {
            all.append(PaletteItem(id: "term-kill", icon: sym("trash"), title: "Kill the active terminal") { ConsoleStore.shared.kill() })
            all.append(PaletteItem(id: "term-max", icon: sym("arrow.up.left.and.arrow.down.right"), title: "Maximize panel size") { ConsoleStore.shared.show(); ConsoleStore.shared.toggleMaximized() })
        }
        all.append(PaletteItem(id: "sidebar", icon: sym("sidebar.left"), title: "Toggle sidebar", hint: "⌘B") { model.toggleSidebar() })
        for (i, n) in navOrder.enumerated() where model.routeLive(n.route) {
            all.append(PaletteItem(id: "go-\(n.label)", icon: sym(n.icon), title: n.label, hint: i < 9 ? "⌘\(i + 1)" : "", group: "Go to") { model.navigate(n.route) })
        }
        all.append(PaletteItem(id: "go-settings", icon: sym("gearshape"), title: "Settings", hint: "⌘,", group: "Go to") { model.navigate(.settings) })
        all.append(PaletteItem(id: "board-view", icon: sym("rectangle.split.3x1"), title: "Sessions as a board", group: "Go to") { model.route = .board })
        all.append(PaletteItem(id: "list-view", icon: sym("list.bullet"), title: "Sessions as a list", group: "Go to") { model.showArchived = false; model.route = .sessions })
        all.append(PaletteItem(id: "archived-view", icon: sym("archivebox"), title: "Archived sessions", group: "Go to") { model.showArchived = true; model.route = .sessions })
        for a in ["light", "dark", "system"] where a != model.appearance {
            all.append(PaletteItem(id: "theme-\(a)", icon: sym(a == "light" ? "sun.max" : a == "dark" ? "moon" : "circle.lefthalf.filled"), title: "Theme: \(a.capitalized)", words: "appearance mode") { model.appearance = a })
        }
        if case .session(let id) = model.route {
            all.append(PaletteItem(id: "split", icon: sym("rectangle.split.2x1"), title: "Split right", hint: "⌘\\") { model.splitRight() })
            all.append(PaletteItem(id: "details", icon: sym("sidebar.right"), title: "Toggle details", hint: "⌥⌘I") { model.toggleDetails() })
            if let s = model.sessions.first(where: { $0.id == id }), !s.isOrchestrator {
                all.append(PaletteItem(id: "pin", icon: sym(s.pinned ? "pin.slash" : "pin"), title: s.pinned ? "Unpin this chat" : "Pin this chat") { Task { await model.setPinned(id, !s.pinned) } })
            }
            all.append(PaletteItem(id: "web", icon: sym("globe"), title: "New browser tab", hint: "⌘T") { model.openBrowser(id, url: "") })
            all.append(PaletteItem(id: "prev", icon: sym("chevron.up"), title: "Previous chat", hint: "⌥⌘↑") { model.stepChat(-1) })
            all.append(PaletteItem(id: "next", icon: sym("chevron.down"), title: "Next chat", hint: "⌥⌘↓") { model.stepChat(1) })
            all.append(PaletteItem(id: "next-tab", icon: sym("arrow.right.square"), title: "Next tab", hint: "⌃⇥") { model.stepTab(1) })
            all.append(PaletteItem(id: "prev-tab", icon: sym("arrow.left.square"), title: "Previous tab", hint: "⌃⇧⇥") { model.stepTab(-1) })
            all.append(PaletteItem(id: "changes", icon: sym("plusminus"), title: "Show changes", hint: "⇧⌘G") { withAnimation(M.snappy) { model.showTab("changes", of: id) } })
            all.append(PaletteItem(id: "session-term", icon: sym("terminal.fill"), title: "Resume this session in a Terminal tab") { model.openTerminalTab(id) })
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
        for pr in model.openPulls + model.reviewPulls where model.sourceLive(.github) {
            all.append(PaletteItem(id: "p-\(pr.url)", icon: AnyView(PRStateIcon(pr: pr)), title: pr.title, detail: "\(pr.repoName)#\(pr.number)", group: "Pull requests") { openURL(pr.url) })
        }
        for e in SettingEntry.all {
            all.append(PaletteItem(id: "set-\(e.pane.rawValue)-\(e.title)", icon: sym(e.pane.icon), title: e.title, detail: "Settings › \(e.pane.label)", group: "Settings", words: e.words) { model.openSettings(e.pane, query: e.query) })
        }
        for p in SettingsPane.allCases {
            all.append(PaletteItem(id: "set-\(p.rawValue)", icon: sym(p.icon), title: "\(p.label) settings", detail: p.blurb, group: "Settings") { model.openSettings(p) })
        }
        for i in model.issues where model.sourceLive(.linear) && i.active {
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
            let hay = "\(it.title) \(it.detail) \(it.group) \(it.words)".lowercased()
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
