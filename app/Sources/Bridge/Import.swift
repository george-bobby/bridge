import SwiftUI

// MARK: - Import a chat
//
// Every chat Claude Code, Codex, Cursor and Devin keep on this Mac, newest
// first, with a preview; importing one makes it a worker in the folder it ran
// in, filed under the project you import it into (`model.importProject`, from
// the New task page), and your next message carries on in the same agent
// session (server/history.js, harness.importChat). Scoped to that project's
// folders by default. A chat Bridge already has opens.

struct HistoryChat: Identifiable, Hashable {
    let j: JSON
    var id: String { "\(agent.rawValue):\(chatId)" }
    var chatId: String { j["id"].string }
    var agent: AgentKind { AgentKind.of(j["agent"].string) }
    var title: String { j["title"].string }
    var prompt: String { j["prompt"].string }
    var cwd: String { j["cwd"].string }
    var updatedAt: Double { j["updatedAt"].double }
    var runId: String { j["runId"].string }
    /// The folder it ran in no longer exists: its session can't carry on.
    var gone: Bool { j["gone"].bool }
    var folder: String {
        let parts = cwd.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

extension AgentKind {
    /// The product name, for a chat that came from the agent's own app or CLI.
    var product: String { self == .claude ? "Claude Code" : label }
}

struct ImportSheet: View {
    @Environment(AppModel.self) var model
    @StateObject private var query = Box("")
    @StateObject private var agent = Box("")
    @StateObject private var chats = Box([HistoryChat]())
    @StateObject private var counts = Box(JSON.null)
    @StateObject private var loading = Box(true)
    @StateObject private var sel = Box<String?>(nil)
    @StateObject private var preview = Box(JSON.null)
    @StateObject private var busy = Box(false)
    @StateObject private var sqlite = Box(true)
    /// Only chats that ran in the target project's checkout or its worktrees.
    @StateObject private var scoped = Box(true)
    @StateObject private var projectOpen = Box(false)
    @FocusState private var focused: Bool

    var target: Project? { model.project(model.importProject) }
    /// Scoping applies to a real project; Default (the root folder) lists everything.
    var scoping: Bool { scoped.v && !(target?.root ?? true) }

    func inTarget(_ c: HistoryChat) -> Bool {
        guard let p = target, !p.root, !c.cwd.isEmpty else { return true }
        return [p.path, p.path + "-worktrees"].contains { c.cwd == $0 || c.cwd.hasPrefix($0 + "/") }
    }

    var shown: [HistoryChat] {
        let words = query.v.lowercased().split(separator: " ").map(String.init)
        return chats.v.filter { c in
            (agent.v.isEmpty || c.agent.rawValue == agent.v) && (!scoping || inTarget(c)) && words.allSatisfy { "\(c.title) \(c.prompt) \(c.cwd)".lowercased().contains($0) }
        }
    }
    var selected: HistoryChat? { shown.first { $0.id == sel.v } ?? shown.first }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Hairline()
                HStack(spacing: 0) {
                    list.frame(width: 380)
                    Rectangle().fill(T.line).frame(width: 1)
                    detail.frame(maxWidth: .infinity)
                }
                .frame(height: 470)
                Hairline()
                footer
            }
            .frame(width: 900)
            .floatingPanel(radius: 16)
            .padding(.top, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .task { await load() }
        .onKeyPress(.escape) { model.importOpen = false; return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onChange(of: selected?.id) { Task { await loadPreview() } }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 14, weight: .medium)).foregroundStyle(T.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import a chat").font(T.ui(15, .semibold))
                    Text("Your chats with Claude Code, Codex, Cursor and Devin on this Mac. Importing one carries it on here, in the same session.")
                        .font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1)
                }
                Spacer()
                Text("Into").font(T.ui(12)).foregroundStyle(T.text3)
                Button { projectOpen.v.toggle() } label: {
                    PickerChip(text: target?.name ?? "Default", open: projectOpen.v) { if let t = target { ProjectBadge(project: t, size: 14) } }
                }
                .buttonStyle(Pressable(scale: 0.97))
                .help("The project the imported chat is filed under. It keeps running in its own folder.")
                .popover(isPresented: $projectOpen.v, arrowEdge: .bottom) {
                    ProjectPanel(current: model.importProject) { id in projectOpen.v = false; model.importProject = id } add: { projectOpen.v = false; model.addProject() }
                        .environment(model)
                }
                IconButton(icon: "xmark", help: "Close (Esc)") { model.importOpen = false }
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(query.v.isEmpty ? T.text3 : T.accent)
                    TextField("", text: $query.v, prompt: Text("Search titles, prompts and folders").foregroundStyle(T.text3))
                        .textFieldStyle(.plain).font(T.ui(13)).focused($focused)
                        .onSubmit { Task { await importSelected() } }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.bg.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(focused ? T.accent.opacity(0.6) : T.line, lineWidth: 1))
                .frame(minWidth: 220)
                if let t = target, !t.root {
                    Button { withAnimation(M.snappy) { scoped.v.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: scoped.v ? "folder.fill" : "folder").font(.system(size: 11))
                            Text(scoped.v ? "In \(t.name)" : "All folders").font(T.ui(12, .medium))
                        }
                        .foregroundStyle(scoped.v ? T.accent : T.text2)
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(scoped.v ? T.accentSoft : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).fixedSize()
                    .help(scoped.v ? "Only chats that ran in \(t.name) or its worktrees. Click for every folder." : "Every chat on this Mac. Click for \(t.name)'s only.")
                }
                filters.fixedSize()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    var filters: some View {
        HStack(spacing: 4) {
            filter("", "All", count: AgentKind.allCases.reduce(0) { $0 + counts.v[$1.rawValue].int }, mark: nil)
            ForEach(AgentKind.allCases) { a in filter(a.rawValue, a.product, count: counts.v[a.rawValue].int, mark: a) }
        }
    }

    func filter(_ id: String, _ label: String, count: Int, mark: AgentKind?) -> some View {
        let on = agent.v == id
        return Button { withAnimation(M.snappy) { agent.v = id } } label: {
            HStack(spacing: 5) {
                if let mark { AgentMark(agent: mark, size: 14) }
                Text(label).font(T.ui(12, .medium))
                Text(verbatim: "\(count)").font(T.ui(11)).foregroundStyle(T.text3).monospacedDigit()
            }
            .foregroundStyle(on ? T.text : T.text2)
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? T.selected : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(on ? T.line : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(count == 0 && !id.isEmpty ? 0.45 : 1)
    }

    var list: some View {
        let items = shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    if loading.v && chats.v.isEmpty {
                        ForEach(0..<6, id: \.self) { _ in RoundedRectangle(cornerRadius: 8).fill(T.raised.opacity(0.6)).frame(height: 54).shimmer() }
                    } else if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray").font(.system(size: 22, weight: .light)).foregroundStyle(T.text3)
                            Text(chats.v.isEmpty ? "No chats found on this Mac" : scoping ? "No chats in \(target?.name ?? "this project") match" : "No chats match").font(T.ui(13, .medium)).foregroundStyle(T.text2)
                            if scoping && !chats.v.isEmpty {
                                Button("Show every folder") { withAnimation(M.snappy) { scoped.v = false } }.buttonStyle(LButton())
                            }
                            if !sqlite.v { Text("Cursor and Devin chats need Node 22.5+ or the sqlite3 tool").font(T.ui(11.5)).foregroundStyle(T.text3) }
                        }
                        .padding(.top, 60)
                    }
                    ForEach(items) { c in
                        ImportRow(chat: c, selected: c.id == selected?.id)
                            .id(c.id)
                            .onTapGesture(count: 2) { sel.v = c.id; Task { await importSelected() } }
                            .onTapGesture { sel.v = c.id }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: sel.v) { if let s = sel.v { withAnimation(M.hover) { proxy.scrollTo(s) } } }
        }
    }

    @ViewBuilder var detail: some View {
        if let c = selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        AgentMark(agent: c.agent, size: 18)
                        Text(c.agent.product).font(T.ui(12, .medium)).foregroundStyle(T.text2)
                        Text(Fmt.ago(c.updatedAt)).font(T.ui(12)).foregroundStyle(T.text3)
                        if !c.runId.isEmpty { Chip(text: "In Bridge", icon: "checkmark") }
                        Spacer()
                    }
                    Text(c.title).font(T.ui(15, .semibold)).foregroundStyle(T.text).lineLimit(2)
                    if !c.cwd.isEmpty {
                        Label(c.cwd, systemImage: "folder").font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(16)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if preview.v.isNull {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
                        } else if !preview.v["error"].string.isEmpty {
                            Text(preview.v["error"].string).font(T.ui(12)).foregroundStyle(T.orange)
                        } else {
                            if preview.v["total"].int > preview.v["messages"].array.count {
                                Text(verbatim: "Last \(preview.v["messages"].array.count) of \(preview.v["total"].int) messages").font(T.ui(11.5)).foregroundStyle(T.text3)
                            }
                            ForEach(Array(preview.v["messages"].array.enumerated()), id: \.offset) { _, m in PreviewMessage(m: m) }
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
            }
        } else {
            EmptyState(icon: "bubble.left.and.bubble.right", title: "Pick a chat", detail: "Its conversation shows here before you import it.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) { Kbd(keys: "↑↓"); Text("Choose").font(T.ui(11.5)).foregroundStyle(T.text3) }
            HStack(spacing: 6) { Kbd(keys: "↩"); Text("Import").font(T.ui(11.5)).foregroundStyle(T.text3) }
            Spacer()
            if let c = selected {
                Text(!c.runId.isEmpty ? "Already imported" : c.gone ? "Its folder is gone, so it can't carry on" : "Into \(target?.name ?? "Default") · runs in \(c.folder.isEmpty ? "its folder" : c.folder)")
                    .font(T.ui(11.5)).foregroundStyle(c.gone && c.runId.isEmpty ? T.orange : T.text3).lineLimit(1)
                Button { Task { await importSelected() } } label: {
                    HStack(spacing: 6) {
                        if busy.v { ProgressView().controlSize(.mini) }
                        Text(c.runId.isEmpty ? "Import" : "Open chat").font(T.ui(12.5, .semibold))
                        Image(systemName: c.runId.isEmpty ? "arrow.down.circle" : "arrow.up.forward").font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(LButton(primary: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(busy.v || (c.gone && c.runId.isEmpty))
            }
        }
        .padding(.horizontal, 16).frame(height: 48)
    }

    func move(_ d: Int) {
        let items = shown
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == selected?.id } ?? 0
        sel.v = items[max(0, min(items.count - 1, i + d))].id
    }

    func load() async {
        loading.v = true
        let out = (try? await API.get("/api/history")) ?? .null
        chats.v = out["chats"].array.map(HistoryChat.init)
        counts.v = out["counts"]
        sqlite.v = out.isNull || out["sqlite"].bool
        loading.v = false
        await loadPreview()
    }

    func loadPreview() async {
        guard let c = selected else { return }
        preview.v = .null
        let out: JSON
        do { out = try await API.get("/api/history/\(c.agent.rawValue)/\(API.q(c.chatId))") } catch { out = .obj(["error": .str(error.localizedDescription)]) }
        if selected?.id == c.id { preview.v = out }
    }

    func importSelected() async {
        guard let c = selected, !busy.v, !(c.gone && c.runId.isEmpty) else { return }
        if !c.runId.isEmpty { model.importOpen = false; return model.open(c.runId) }
        busy.v = true
        await model.act {
            let out = try await API.post("/api/history/import", ["agent": c.agent.rawValue, "id": c.chatId, "project": self.model.importProject])
            await self.model.loadAll()
            self.model.importOpen = false
            self.model.open(out["taskId"].string)
            self.model.say(out["existing"].bool ? "Opened the chat you imported before" : "Imported from \(c.agent.product)")
        }
        busy.v = false
    }
}

struct ImportRow: View {
    let chat: HistoryChat
    let selected: Bool
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentMark(agent: chat.agent, size: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(chat.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if !chat.runId.isEmpty { Image(systemName: "checkmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(T.green).help("Already in Bridge") }
                    Text(Fmt.ago(chat.updatedAt)).font(T.ui(11)).foregroundStyle(T.text3).monospacedDigit()
                }
                if chat.prompt != chat.title { Text(chat.prompt).font(T.ui(12)).foregroundStyle(T.text2).lineLimit(1) }
                if !chat.folder.isEmpty {
                    HStack(spacing: 4) {
                        if chat.gone { Image(systemName: "folder.badge.minus").font(.system(size: 9.5)).foregroundStyle(T.orange).help("This folder no longer exists") }
                        Text(chat.folder).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.head).strikethrough(chat.gone, color: T.text3)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? T.selected : hover.v ? T.hover : .clear))
        .overlay(alignment: .leading) { if selected { Capsule().fill(T.accent).frame(width: 3, height: 22).padding(.leading, 1) } }
        .contentShape(Rectangle())
        .hoverBox(hover)
    }
}

/// One message of the preview: who, and the words (tools as a quiet count).
struct PreviewMessage: View {
    let m: JSON
    var body: some View {
        let user = m["role"].string == "user"
        let steps = m["steps"].array
        let tools = steps.filter { $0["kind"].string == "tool" }.count
        let text = user ? m["text"].string : steps.filter { $0["kind"].string == "text" }.map { $0["text"].string }.joined(separator: "\n\n")
        HStack(alignment: .top, spacing: 10) {
            if user { Avatar(name: "You", size: 20) } else { AgentMark(agent: AgentKind.of(m["agent"].string), size: 20) }
            VStack(alignment: .leading, spacing: 5) {
                if !text.isEmpty { RichText(markdown: String(text.prefix(3000)), size: 12.5, color: user ? NT.text : NT.text2) }
                if tools > 0 {
                    Label(tools == 1 ? "1 tool call" : "\(tools) tool calls", systemImage: "wrench.and.screwdriver").font(T.ui(11)).foregroundStyle(T.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
