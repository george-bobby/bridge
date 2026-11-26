import AppKit
import SwiftUI

// The composer's pieces, shared by the chat composer and the New task sheet:
// the agent + model picker, the access-mode picker, the context meter with
// its compact action, and the prompt editor whose `@` / `#` / `/` menus list
// files, sessions and skills.

// MARK: - Data

/// Files and commands the composers look up, kept across composers so a
/// second `@` in the same folder is instant.
@MainActor
final class ComposerData: ObservableObject {
    static let shared = ComposerData()

    struct FileIndex {
        let root: String
        let entries: [Entry]
        let at: Date
        struct Entry {
            let path: String
            let dir: Bool
            let bytes: [UInt8]
            let base: [UInt8]
        }
    }

    @Published var files: [String: FileIndex] = [:]
    @Published var loadingFiles: Set<String> = []
    @Published var fileErrors: [String: String] = [:]
    @Published var commands: [String: [JSON]] = [:]
    @Published var refreshingModels = false
    /// Snapshot hook: which picker to open ("model", "access", "context").
    @Published var snapshotOpen = ""

    func loadFiles(_ key: String, path: String) async {
        if let f = files[key], Date().timeIntervalSince(f.at) < 30 { return }
        guard !loadingFiles.contains(key) else { return }
        loadingFiles.insert(key)
        defer { loadingFiles.remove(key) }
        let j: JSON
        do { j = try await API.get(path) } catch {
            fileErrors[key] = error.localizedDescription
            return
        }
        fileErrors[key] = nil
        let dirs = j["dirs"].array.map { FileIndex.Entry(path: $0.string + "/", dir: true, bytes: Array($0.string.lowercased().utf8), base: Array(URL(fileURLWithPath: $0.string).lastPathComponent.lowercased().utf8)) }
        let fs = j["files"].array.map { f -> FileIndex.Entry in
            let s = f.string
            return FileIndex.Entry(path: s, dir: false, bytes: Array(s.lowercased().utf8), base: Array((s.split(separator: "/").last.map(String.init) ?? s).lowercased().utf8))
        }
        files[key] = FileIndex(root: j["root"].string, entries: fs + dirs, at: Date())
    }

    func loadCommands(project: String) async {
        commands[project] = (try? await API.get("/api/commands?project=\(API.q(project))"))?["commands"].array ?? []
    }
}

/// Subsequence matching with bonuses for runs and word starts, the way
/// editors' quick-open ranks: `expjs` finds `src/api/export.js`.
enum Fuzzy {
    static func score(_ q: [UInt8], _ s: [UInt8]) -> Int? {
        if q.isEmpty { return 0 }
        var qi = 0, score = 0, last = -2, first = -1
        var i = 0
        while i < s.count && qi < q.count {
            if s[i] == q[qi] {
                if first < 0 { first = i }
                var b = 1
                if i == last + 1 { b += 6 }
                if i == 0 || [47, 95, 45, 46, 32].contains(s[i - 1]) { b += 5 }
                score += b
                last = i
                qi += 1
            }
            i += 1
        }
        guard qi == q.count else { return nil }
        return score * 8 - s.count / 4 - first
    }

    static func score(_ q: String, _ s: String) -> Int? { score(Array(q.lowercased().utf8), Array(s.lowercased().utf8)) }
}

// MARK: - Search field with list keys

/// A borderless text field that hands ↑ ↓ ↩ ⇥ and esc to its list.
struct PickerField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onTab: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = placeholder
        f.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerField
        init(_ p: PickerField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            case #selector(NSResponder.insertTab(_:)): parent.onTab(true)
            case #selector(NSResponder.insertBacktab(_:)): parent.onTab(false)
            default: return false
            }
            return true
        }
    }
}

// MARK: - Shared rows

/// One row of a picker: leading mark, title over a hint, trailing detail,
/// a checkmark on the current choice, and a highlight that follows keys and hover.
struct PickRow<Lead: View, Trail: View>: View {
    let title: String
    var subtitle = ""
    var mono = false
    var checked = false
    var highlighted = false
    var dim = false
    var height: CGFloat = 40
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var trail: () -> Trail

    var body: some View {
        HStack(spacing: 10) {
            lead().frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(mono ? T.mono(12.5, .medium) : T.ui(13, .medium)).foregroundStyle(dim ? T.text3 : T.text).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.tail) }
            }
            Spacer(minLength: 8)
            trail()
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(T.accent)
                .opacity(checked ? 1 : 0).frame(width: 14)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? T.selected : .clear))
        .contentShape(Rectangle())
    }
}

struct SectionLabel: View {
    let text: String
    var agent: AgentKind? = nil
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let agent { AgentMark(agent: agent, size: 12) }
            Text(text.uppercased()).font(T.ui(10.5, .semibold)).tracking(0.4).foregroundStyle(T.text3)
            if let count { Text(verbatim: "\(count)").font(T.ui(10.5)).foregroundStyle(T.text3.opacity(0.8)).monospacedDigit() }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }
}

struct KeyHints: View {
    let hints: [(String, String)]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(hints, id: \.0) { k, v in
                HStack(spacing: 4) {
                    Text(k).font(T.ui(10.5, .semibold)).foregroundStyle(T.text2)
                        .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(T.hover))
                    Text(v).font(T.ui(11)).foregroundStyle(T.text3)
                }
            }
            Spacer()
        }
    }
}

/// The trigger chip the pickers open from.
struct PickerChip<Lead: View>: View {
    let text: String
    var detail = ""
    var warn = false
    var open = false
    @ViewBuilder var lead: () -> Lead
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 6) {
            lead()
            Text(text).font(T.ui(12, .medium)).lineLimit(1)
            if !detail.isEmpty { Text(detail).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1) }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .foregroundStyle(warn ? T.orange : T.text2)
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(open ? T.selected : hover.v ? T.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(warn ? T.orange.opacity(0.35) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .hoverBox(hover)
        .animation(M.snappy, value: open)
    }
}

// MARK: - Agent + model picker

struct ModelItem: Identifiable, Hashable {
    let agent: AgentKind
    let modelId: String
    let label: String
    let hint: String
    let efforts: [String]
    let group: String
    var id: String { agent.rawValue + "/" + modelId }
}

extension AppModel {
    func modelItems(_ agent: AgentKind) -> [ModelItem] {
        var out: [ModelItem] = []
        if agent != .claude { out.append(ModelItem(agent: agent, modelId: "", label: "Default", hint: "Whatever \(agent.label) is set to", efforts: agent == .codex ? Effort.levels : [], group: "")) }
        out += models(for: agent).map { m in
            ModelItem(agent: agent, modelId: m["id"].string, label: m["label"].nonEmpty ?? m["id"].string, hint: m["hint"].nonEmpty ?? m["id"].string, efforts: m["efforts"].array.map(\.string), group: m["group"].string)
        }
        return out
    }

    func modelLabel(_ agent: AgentKind, _ id: String) -> String {
        if id.isEmpty { return agent == .claude ? "Default" : agent.label }
        return models(for: agent).first { $0["id"].string == id }?["label"].nonEmpty ?? id
    }

    func refreshAgents() async {
        ComposerData.shared.refreshingModels = true
        if let c = try? await API.get("/api/agents?refresh=1") { agentCatalog = c }
        ComposerData.shared.refreshingModels = false
    }
}

enum Effort {
    /// What the server accepts (server/store.js EFFORT_LEVELS).
    static let levels = ["low", "medium", "high", "xhigh", "max"]
    static func label(_ e: String) -> String {
        switch e {
        case "": return "Auto"
        case "xhigh": return "X-High"
        default: return e.prefix(1).uppercased() + e.dropFirst()
        }
    }
}

/// Agent and model in one chip, picked together from one panel: provider
/// tabs, search across every model each CLI lists, and the thinking level.
struct AgentModelPicker: View {
    @Environment(AppModel.self) var model
    let agent: AgentKind
    let modelId: String
    let effort: String
    let pick: (AgentKind, String) -> Void
    let setEffort: (String) -> Void
    @StateObject private var open = Box(false)
    @ObservedObject private var data = ComposerData.shared

    var body: some View {
        Button { open.v.toggle() } label: {
            PickerChip(text: model.modelLabel(agent, modelId), detail: effort.isEmpty || !(agent == .claude || agent == .codex) ? "" : Effort.label(effort), open: open.v) {
                HStack(spacing: 4) {
                    AgentMark(agent: agent, size: 15)
                    if agent != .claude { Image(systemName: "shield.slash").font(.system(size: 9.5)).foregroundStyle(T.orange) }
                }
            }
        }
        .buttonStyle(Pressable(scale: 0.97))
        .help("\(agent.label) · \(model.modelLabel(agent, modelId)). \(agent.hint)")
        .popover(isPresented: $open.v, arrowEdge: .top) {
            ModelPanel(agent: agent, modelId: modelId, effort: effort, pick: { a, m in open.v = false; pick(a, m) }, setEffort: setEffort, close: { open.v = false })
                .environment(model)
        }
        .onChange(of: data.snapshotOpen) { if data.snapshotOpen == "model" { open.v = true } else if open.v && !data.snapshotOpen.isEmpty { open.v = false } }
    }
}

struct ModelPanel: View {
    @Environment(AppModel.self) var model
    let agent: AgentKind
    let modelId: String
    let effort: String
    let pick: (AgentKind, String) -> Void
    let setEffort: (String) -> Void
    let close: () -> Void
    @StateObject private var query = Box("")
    @StateObject private var tab = Box("")
    @StateObject private var hi = Box(0)
    @ObservedObject private var data = ComposerData.shared

    enum Entry: Identifiable {
        case header(String, AgentKind?, Int?)
        case item(Int, ModelItem)
        case empty(AgentKind)
        var id: String {
            switch self {
            case .header(let t, let a, _): return "h-\(a?.rawValue ?? "")-\(t)"
            case .item(_, let m): return m.id
            case .empty(let a): return "e-\(a.rawValue)"
            }
        }
    }

    var providers: [AgentKind] { tab.v == "all" ? AgentKind.allCases : [AgentKind.of(tab.v)] }

    /// Rows to show and the selectable items among them, in order.
    func build() -> ([Entry], [ModelItem]) {
        let q = Array(query.v.lowercased().utf8)
        var entries: [Entry] = []
        var items: [ModelItem] = []
        for a in providers {
            guard model.installed(a) else {
                if tab.v != "all" { entries.append(.empty(a)) }
                continue
            }
            var hits = model.modelItems(a)
            if !q.isEmpty {
                hits = hits.compactMap { m -> (ModelItem, Int)? in
                    let s = max(Fuzzy.score(q, Array(m.label.lowercased().utf8)).map { $0 + 20 } ?? Int.min, Fuzzy.score(q, Array(m.modelId.lowercased().utf8)) ?? Int.min)
                    return s == Int.min ? nil : (m, s)
                }
                .sorted { $0.1 > $1.1 }.map(\.0)
            }
            if hits.isEmpty { continue }
            if tab.v == "all" || !q.isEmpty && tab.v == "all" {
                entries.append(.header(a.label, a, hits.count))
                for m in hits.prefix(q.isEmpty ? 8 : 40) { entries.append(.item(items.count, m)); items.append(m) }
            } else {
                var group = "\u{0}"
                for m in hits {
                    if q.isEmpty && m.group != group && !m.group.isEmpty { entries.append(.header(m.group, nil, nil)) }
                    group = m.group
                    entries.append(.item(items.count, m))
                    items.append(m)
                }
            }
        }
        return (entries, items)
    }

    var body: some View {
        let (entries, items) = build()
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(T.text3)
                PickerField(placeholder: tab.v == "all" ? "Search every agent's models…" : "Search \(AgentKind.of(tab.v).label) models…", text: $query.v,
                            onMove: { d in move(d, items.count) },
                            onSubmit: { if items.indices.contains(hi.v) { choose(items[hi.v]) } },
                            onCancel: close,
                            onTab: { fwd in cycle(fwd) })
                    .frame(height: 20)
                IconButton(icon: "arrow.clockwise", help: "Fetch every agent's model list again", spinning: data.refreshingModels) {
                    Task { await model.refreshAgents() }
                }
            }
            .padding(.horizontal, 12).frame(height: 44)
            tabs.padding(.horizontal, 10).padding(.bottom, 8)
            Hairline()
            list(entries, items)
            if agent == .claude || agent == .codex { Hairline(); effortStrip }
            Hairline()
            KeyHints(hints: [("↑↓", "navigate"), ("↩", "select"), ("⇥", "agent"), ("esc", "close")])
                .padding(.horizontal, 12).frame(height: 32)
        }
        .frame(width: 440)
        .background(T.raised)
        .onAppear { tab.v = agent.rawValue; hi.v = 0; if let i = build().1.firstIndex(where: { $0.agent == agent && $0.modelId == modelId }) { hi.v = i } }
        .onChange(of: query.v) { hi.v = 0 }
        .onChange(of: tab.v) { hi.v = 0 }
    }

    var tabs: some View {
        HStack(spacing: 2) {
            tabButton("all", label: "All", mark: nil)
            ForEach(AgentKind.allCases) { a in tabButton(a.rawValue, label: a.label, mark: a) }
            Spacer()
        }
    }

    func tabButton(_ id: String, label: String, mark: AgentKind?) -> some View {
        let on = tab.v == id
        let installed = mark.map { model.installed($0) } ?? true
        return Button { withAnimation(M.snappy) { tab.v = id } } label: {
            HStack(spacing: 5) {
                if let mark { AgentMark(agent: mark, size: 13).saturation(installed ? 1 : 0).opacity(installed ? 1 : 0.5) }
                Text(label).font(T.ui(12, .medium))
                if let mark, mark == agent { Circle().fill(T.accent).frame(width: 4, height: 4) }
            }
            .foregroundStyle(on ? T.text : T.text2)
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? T.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mark.map { installed ? "\($0.label): \(model.models(for: $0).count) models" : "\($0.label) isn't installed" } ?? "Every agent")
    }

    func list(_ entries: [Entry], _ items: [ModelItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if items.isEmpty && !entries.contains(where: { if case .empty = $0 { return true }; return false }) {
                        Text(model.agentCatalog.isNull ? "Loading models…" : "No models match \"\(query.v)\"").font(T.ui(12.5)).foregroundStyle(T.text3)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(entries) { e in entryView(e).id(e.id) }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(height: min(340, max(120, entries.reduce(CGFloat(12)) { h, e in
                if case .item = e { return h + 41 }
                if case .empty = e { return h + 170 }
                return h + 30
            })))
            .onChange(of: hi.v) { if items.indices.contains(hi.v) { withAnimation(M.hover) { proxy.scrollTo(items[hi.v].id) } } }
        }
    }

    @ViewBuilder func entryView(_ e: Entry) -> some View {
        switch e {
        case .header(let t, let a, let n):
            SectionLabel(text: t, agent: a, count: n)
        case .empty(let a):
            VStack(spacing: 8) {
                AgentMark(agent: a, size: 28).saturation(0).opacity(0.6)
                Text("\(a.label) isn't installed").font(T.ui(13, .medium)).foregroundStyle(T.text2)
                Text(a.hint).font(T.ui(11.5)).foregroundStyle(T.text3).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
        case .item(let i, let m):
            Button { choose(m) } label: {
                PickRow(title: m.label, subtitle: m.hint, checked: m.agent == agent && m.modelId == modelId, highlighted: hi.v == i) {
                    AgentMark(agent: m.agent, size: 18)
                } trail: {
                    if !m.efforts.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "brain").font(.system(size: 9.5))
                            Text(m.efforts.count > 1 ? "\(Effort.label(m.efforts.first!))–\(Effort.label(m.efforts.last!))" : Effort.label(m.efforts[0])).font(T.ui(10.5))
                        }
                        .foregroundStyle(T.text3)
                        .help("Thinking levels: \(m.efforts.map(Effort.label).joined(separator: ", "))")
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { if $0 { hi.v = i } }
        }
    }

    /// Thinking level for the model in use.
    var effortStrip: some View {
        let current = model.modelItems(agent).first { $0.modelId == modelId }
        let allowed = (current?.efforts.isEmpty == false ? current!.efforts : Effort.levels).filter { Effort.levels.contains($0) }
        return HStack(spacing: 8) {
            Image(systemName: "brain").font(.system(size: 11)).foregroundStyle(T.text3)
            Text("Thinking").font(T.ui(12, .medium)).foregroundStyle(T.text2)
            Spacer()
            HStack(spacing: 2) {
                ForEach([""] + allowed, id: \.self) { e in
                    let on = effort == e
                    Button { setEffort(e) } label: {
                        Text(Effort.label(e)).font(T.ui(11.5, .medium))
                            .foregroundStyle(on ? T.text : T.text3)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? T.selected : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.panel))
            .animation(M.snappy, value: effort)
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    func move(_ d: Int, _ n: Int) {
        guard n > 0 else { return }
        hi.v = (hi.v + d + n) % n
    }

    func cycle(_ fwd: Bool) {
        let order = ["all"] + AgentKind.allCases.map(\.rawValue)
        let i = order.firstIndex(of: tab.v) ?? 0
        withAnimation(M.snappy) { tab.v = order[(i + (fwd ? 1 : order.count - 1)) % order.count] }
    }

    func choose(_ m: ModelItem) { pick(m.agent, m.modelId) }
}

// MARK: - Access mode

/// The four permission modes, and what each means for the agent at hand:
/// Claude runs them through Bridge's permission prompts; the other CLIs map
/// them onto their own flags (server/agents.js `command`).
enum AccessMode: String, CaseIterable, Identifiable {
    case plan, manual, acceptEdits, bypassPermissions
    var id: String { rawValue }
    static func of(_ s: String) -> AccessMode { AccessMode(rawValue: s) ?? .bypassPermissions }

    var label: String {
        switch self {
        case .plan: return "Plan mode"
        case .manual: return "Ask before acting"
        case .acceptEdits: return "Accept edits"
        case .bypassPermissions: return "Bypass permissions"
        }
    }
    var short: String {
        switch self {
        case .plan: return "Plan"
        case .manual: return "Ask first"
        case .acceptEdits: return "Accept edits"
        case .bypassPermissions: return "Bypass permissions"
        }
    }
    var icon: String {
        switch self {
        case .plan: return "map"
        case .manual: return "hand.raised"
        case .acceptEdits: return "pencil.and.outline"
        case .bypassPermissions: return "bolt.shield"
        }
    }
    var tint: Color {
        switch self {
        case .plan: return T.purple
        case .manual: return T.text2
        case .acceptEdits: return T.green
        case .bypassPermissions: return T.orange
        }
    }

    func detail(_ a: AgentKind) -> String {
        switch (a, self) {
        case (.claude, .plan): return "Reads and plans, changes nothing. Ends by asking you to approve its plan, then builds it."
        case (.claude, .manual): return "Asks you before every tool call it isn't already allowed to make."
        case (.claude, .acceptEdits): return "Edits files freely. Shell commands still come to you as Allow / Deny cards."
        case (.claude, .bypassPermissions): return "Runs everything without asking. Bridge's guard still holds outward writes (Slack, PRs, Linear) for you."
        case (.codex, .plan): return "Read-only sandbox: reads and runs read-only commands, writes nothing."
        case (.codex, .manual), (.codex, .acceptEdits): return "Workspace-write sandbox: edits inside the folder, no network. Codex doesn't stop to ask in headless runs."
        case (.codex, .bypassPermissions): return "No sandbox and no approvals. Bridge's guard doesn't apply to Codex."
        case (.cursor, .plan): return "Cursor's plan mode: analyses and proposes, no edits."
        case (.cursor, .manual): return "Without --force: Cursor refuses commands it isn't allowed to run."
        case (.cursor, .acceptEdits): return "--force: edits and runs commands (Cursor has no edits-only mode)."
        case (.cursor, .bypassPermissions): return "--force: everything runs unless explicitly denied."
        case (.devin, .plan), (.devin, .manual): return "auto: only read-only tools run; anything else is refused headless. Devin has no plan mode."
        case (.devin, .acceptEdits): return "accept-edits: read-only tools and workspace edits run without asking."
        case (.devin, .bypassPermissions): return "dangerous: every tool is auto-approved."
        }
    }

    func flag(_ a: AgentKind) -> String {
        switch (a, self) {
        case (.claude, .bypassPermissions): return "--dangerously-skip-permissions"
        case (.claude, _): return "--permission-mode \(rawValue)"
        case (.codex, .plan): return "--sandbox read-only"
        case (.codex, .bypassPermissions): return "--dangerously-bypass-approvals-and-sandbox"
        case (.codex, _): return "--sandbox workspace-write"
        case (.cursor, .plan): return "--mode plan"
        case (.cursor, .manual): return "no --force"
        case (.cursor, _): return "--force"
        case (.devin, .acceptEdits): return "--permission-mode accept-edits"
        case (.devin, .bypassPermissions): return "--permission-mode dangerous"
        case (.devin, _): return "--permission-mode auto"
        }
    }
}

struct AccessPicker: View {
    let agent: AgentKind
    let mode: String
    let pick: (String) -> Void
    @StateObject private var open = Box(false)
    @ObservedObject private var data = ComposerData.shared

    var body: some View {
        let m = AccessMode.of(mode)
        Button { open.v.toggle() } label: {
            PickerChip(text: m.short, warn: m == .bypassPermissions, open: open.v) {
                Image(systemName: m.icon).font(.system(size: 11, weight: .medium)).foregroundStyle(m == .bypassPermissions ? T.orange : m.tint)
            }
        }
        .buttonStyle(Pressable(scale: 0.97))
        .help("\(m.label): \(m.detail(agent))")
        .popover(isPresented: $open.v, arrowEdge: .top) {
            AccessPanel(agent: agent, mode: m, pick: { open.v = false; pick($0.rawValue) }, close: { open.v = false })
        }
        .onChange(of: data.snapshotOpen) { if data.snapshotOpen == "access" { open.v = true } else if open.v && !data.snapshotOpen.isEmpty { open.v = false } }
    }
}

struct AccessPanel: View {
    let agent: AgentKind
    let mode: AccessMode
    let pick: (AccessMode) -> Void
    let close: () -> Void
    @StateObject private var hi = Box(0)
    @FocusState private var focused: Bool

    var body: some View {
        let all = AccessMode.allCases
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                AgentMark(agent: agent, size: 14)
                Text("Access for \(agent.label)").font(T.ui(12, .semibold)).foregroundStyle(T.text2)
                Spacer()
                if agent != .claude { Chip(text: "own sandbox", icon: "shield.slash", tint: T.orange) }
            }
            .padding(.horizontal, 14).frame(height: 38)
            Hairline()
            VStack(spacing: 2) {
                ForEach(Array(all.enumerated()), id: \.offset) { i, m in
                    Button { pick(m) } label: { row(m, highlighted: hi.v == i) }
                        .buttonStyle(.plain)
                        .onHover { if $0 { hi.v = i } }
                }
            }
            .padding(6)
            Hairline()
            KeyHints(hints: [("↑↓", "navigate"), ("↩", "select"), ("esc", "close")]).padding(.horizontal, 14).frame(height: 32)
        }
        .frame(width: 400)
        .background(T.raised)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { hi.v = (hi.v + all.count - 1) % all.count; return .handled }
        .onKeyPress(.downArrow) { hi.v = (hi.v + 1) % all.count; return .handled }
        .onKeyPress(.return) { pick(all[hi.v]); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear { hi.v = all.firstIndex(of: mode) ?? 0; DispatchQueue.main.async { focused = true } }
    }

    func row(_ m: AccessMode, highlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: m.icon).font(.system(size: 13, weight: .medium)).foregroundStyle(m.tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(m.tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(m.label).font(T.ui(13, .medium)).foregroundStyle(m == .bypassPermissions ? T.orange : T.text)
                Text(m.detail(agent)).font(T.ui(11.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
                Text(m.flag(agent)).font(T.mono(10)).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(T.accent).opacity(m == mode ? 1 : 0).padding(.top, 7)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(highlighted ? T.selected : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Context + compact

extension AppModel {
    func compact(_ runId: String, instructions: String = "") async {
        await act {
            let out = try await API.post("/api/runs/\(API.q(runId))/compact", ["instructions": instructions])
            self.say(out["native"].bool ? "Compacting the conversation…" : "Compacted: the next turn starts fresh from a summary")
        }
        await refreshOpen()
    }
}

/// How full the context window was on the last turn; click to compact it.
struct ContextButton: View {
    @Environment(AppModel.self) var model
    let runId: String
    let run: JSON
    let agent: AgentKind
    let live: Bool
    @StateObject private var open = Box(false)
    @StateObject private var focus = Box("")
    @StateObject private var hover = Box(false)
    @ObservedObject private var data = ComposerData.shared

    var body: some View {
        let msgs = run["messages"].array
        let last = msgs.last { $0["role"].string == "assistant" && $0["usage"]["input"].int + $0["usage"]["cacheRead"].int > 0 }
        let window = msgs.last { $0["contextWindow"].double > 0 }?["contextWindow"].double ?? 200_000
        let worked = msgs.contains { $0["role"].string == "assistant" && ["done", "stopped"].contains($0["state"].string) }
        if last != nil || worked {
            let m = last ?? .null
            let used = m["usage"]["input"].double + m["usage"]["cacheRead"].double + m["usage"]["cacheWrite"].double
            let f = min(1, used / max(window, 1))
            let tone = f > 0.85 ? T.red : f > 0.65 ? T.orange : T.text2
            Button { open.v.toggle() } label: {
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(T.line, lineWidth: 2)
                        Circle().trim(from: 0, to: f).stroke(tone, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    Text(verbatim: last == nil ? "Context" : "\(Int(f * 100))%").font(T.ui(11, .medium)).foregroundStyle(f > 0.65 ? tone : T.text3).monospacedDigit()
                }
                .padding(.horizontal, 7).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(open.v ? T.selected : hover.v ? T.hover : .clear))
                .contentShape(Rectangle())
                .animation(M.snappy, value: f)
            }
            .buttonStyle(Pressable(scale: 0.95))
            .hoverBox(hover)
            .help("Context: \(Fmt.tokens(Int(used))) of \(Fmt.tokens(Int(window))) tokens. Click to compact.")
            .popover(isPresented: $open.v, arrowEdge: .top) { panel(used: used, window: window, f: f, tone: tone, compacted: m["compact"]) }
            .onChange(of: data.snapshotOpen) { if data.snapshotOpen == "context" { open.v = true } else if open.v && !data.snapshotOpen.isEmpty { open.v = false } }
        }
    }

    func panel(used: Double, window: Double, f: Double, tone: Color, compacted: JSON) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Context window").font(T.ui(13, .semibold))
                Spacer()
                Text(verbatim: "\(Int(f * 100))%").font(T.ui(13, .semibold)).foregroundStyle(tone).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(T.line)
                    Capsule().fill(tone).frame(width: max(6, g.size.width * f))
                }
            }
            .frame(height: 6)
            Text(verbatim: used == 0 ? "\(agent.label) didn't report context usage for the last turn" : "\(Fmt.tokens(Int(used))) of \(Fmt.tokens(Int(window))) tokens on the last turn" + (compacted.isNull ? "" : " · compacted from \(Fmt.tokens(compacted["pre"].int))"))
                .font(T.ui(11.5)).foregroundStyle(T.text3)
            Hairline()
            VStack(alignment: .leading, spacing: 6) {
                Text("Compact the conversation").font(T.ui(12.5, .medium))
                Text(agent == .claude
                     ? "Claude replaces the conversation with its own summary (/compact). The session keeps going with far less context."
                     : "\(agent.label) has no headless /compact: Bridge summarises the session and \(agent.label)'s next turn starts a fresh session from that summary.")
                    .font(T.ui(11.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
                LField(placeholder: "Focus the summary on… (optional)", text: $focus.v) { go() }
            }
            HStack {
                if live { Text("Waits for the running turn to finish").font(T.ui(11)).foregroundStyle(T.text3) }
                Spacer()
                Button { go() } label: { Label("Compact now", systemImage: "arrow.down.right.and.arrow.up.left").font(T.ui(12.5, .medium)) }
                    .buttonStyle(LButton(primary: true))
                    .disabled(live)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(T.raised)
    }

    func go() {
        open.v = false
        let i = focus.v
        focus.v = ""
        Task { await model.compact(runId, instructions: i) }
    }
}

// MARK: - Prompt editor with @ # / menus

enum TriggerKind: Equatable {
    case file, session, command
    var icon: String {
        switch self {
        case .file: return "at"
        case .session: return "number"
        case .command: return "slash.circle"
        }
    }
}

struct Trigger: Equatable {
    let kind: TriggerKind
    let query: String
    let range: NSRange
    let token: String
}

struct TriggerItem: Identifiable {
    enum Lead { case symbol(String, Color), session(Session), agent(AgentKind) }
    let id: String
    let lead: Lead
    let title: String
    var subtitle = ""
    var trailing = ""
    var mono = false
    let insert: String
    var session: Session? = nil
}

/// Where an editor's `@` and `/` look: a session's folder, or a project's.
enum TriggerSource: Equatable {
    case run(String)
    case project(String)
    var filesKey: String {
        switch self {
        case .run(let id): return "run:\(id)"
        case .project(let id): return "project:\(id)"
        }
    }
    var filesPath: String {
        switch self {
        case .run(let id): return "/api/runs/\(API.q(id))/files"
        case .project(let id): return "/api/files?project=\(API.q(id))"
        }
    }
}

@MainActor
final class TriggerController: ObservableObject {
    @Published var active: Trigger? = nil
    @Published var highlight = 0
    var items: [TriggerItem] = []
    var choose: (TriggerItem) -> Void = { _ in }
    var suppressed = ""
    var focused = false
    var monitor: Any? = nil

    /// ↑ ↓ ↩ ⇥ esc while a menu is open; everything else goes to the text.
    func handle(_ e: NSEvent) -> NSEvent? {
        guard focused, active != nil else { return e }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard mods.isEmpty || mods == .shift else { return e }
        let n = items.count
        switch e.keyCode {
        case 125: if n > 0 { highlight = (highlight + 1) % n }; return nil
        case 126: if n > 0 { highlight = (highlight + n - 1) % n }; return nil
        case 36, 76, 48:
            guard n > 0 else { return e }
            choose(items[min(highlight, n - 1)])
            return nil
        case 53:
            suppressed = active?.token ?? ""
            withAnimation(M.snappy) { active = nil }
            return nil
        default: return e
        }
    }
}

/// The composer's text area: `@` lists the folder's files, `#` other
/// sessions, `/` (at the start) skills and commands. Arrow keys and ↩ work
/// the menu while it's open; the text view keeps focus throughout.
struct PromptEditor: View {
    @Environment(AppModel.self) var model
    @Binding var text: String
    let placeholder: String
    let source: TriggerSource
    var fontSize: CGFloat = 13.5
    var minHeight: CGFloat = 44
    var maxHeight: CGFloat = 180
    var menuAbove = true
    var exclude = ""
    var focused: FocusState<Bool>.Binding
    let attach: (Attachment) -> Void
    @StateObject private var ctl = TriggerController()
    @ObservedObject private var data = ComposerData.shared

    var body: some View {
        let items = ctl.active.map(items(for:)) ?? []
        let _ = bind(items)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(T.ui(fontSize)).foregroundStyle(T.text3).padding(.horizontal, 5).padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(T.ui(fontSize))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused(focused)
                    .frame(minHeight: minHeight, maxHeight: maxHeight)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .overlay(alignment: .topLeading) {
                if menuAbove, let t = ctl.active {
                    menu(t, items)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                        .frame(height: 0, alignment: .bottom)
                        .offset(x: -6, y: -16)
                }
            }
            if !menuAbove, let t = ctl.active {
                menu(t, items).padding(.top, 8).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(M.snappy, value: ctl.active?.kind)
        .onChange(of: text) { detect() }
        .onChange(of: focused.wrappedValue) { ctl.focused = focused.wrappedValue; if !focused.wrappedValue { ctl.active = nil } }
        .onAppear {
            ctl.focused = focused.wrappedValue
            guard ctl.monitor == nil else { return }
            ctl.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak ctl] e in ctl?.handle(e) ?? e }
        }
        .onDisappear { if let m = ctl.monitor { NSEvent.removeMonitor(m); ctl.monitor = nil } }
    }

    func bind(_ items: [TriggerItem]) {
        ctl.items = items
        ctl.choose = { item in choose(item) }
        if ctl.highlight >= items.count { DispatchQueue.main.async { ctl.highlight = 0 } }
    }

    func menu(_ t: Trigger, _ items: [TriggerItem]) -> some View {
        TriggerMenu(trigger: t, items: items, highlight: ctl.highlight,
                    loading: t.kind == .file && data.loadingFiles.contains(source.filesKey),
                    error: t.kind == .file ? data.fileErrors[source.filesKey] ?? "" : "",
                    root: data.files[source.filesKey]?.root ?? "",
                    pick: { choose($0) }, hover: { ctl.highlight = $0 })
    }

    // MARK: detection

    var textView: NSTextView? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.string == text else { return nil }
        return tv
    }

    func detect() {
        let ns = text as NSString
        var cursor = ns.length
        if let tv = textView { cursor = min(tv.selectedRange().location, ns.length) }
        let prefix = ns.substring(to: cursor) as NSString
        let ws = prefix.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
        let start = ws.location == NSNotFound ? 0 : ws.location + 1
        let token = prefix.substring(from: start)
        var kind: TriggerKind? = nil
        if token.hasPrefix("@") { kind = .file }
        else if token.hasPrefix("#") && !token.hasPrefix("##") { kind = .session }
        else if token.hasPrefix("/") && start == 0 { kind = .command }
        guard let kind, token != ctl.suppressed else {
            if ctl.active != nil { withAnimation(M.snappy) { ctl.active = nil } }
            if !token.hasPrefix("@") && !token.hasPrefix("#") && !token.hasPrefix("/") { ctl.suppressed = "" }
            return
        }
        let t = Trigger(kind: kind, query: String(token.dropFirst()), range: NSRange(location: start, length: cursor - start), token: token)
        if ctl.active?.kind != t.kind || ctl.active?.query != t.query { ctl.highlight = 0 }
        if ctl.active == nil { withAnimation(M.snappy) { ctl.active = t } } else { ctl.active = t }
        if kind == .file { Task { await data.loadFiles(source.filesKey, path: source.filesPath) } }
        if kind == .command, case .project(let p) = source, data.commands[p] == nil { Task { await data.loadCommands(project: p) } }
    }

    func choose(_ item: TriggerItem) {
        guard let t = ctl.active else { return }
        insert(item.insert, over: t.range)
        ctl.suppressed = ""
        withAnimation(M.snappy) { ctl.active = nil }
        if let s = item.session {
            Task {
                guard let r = try? await API.get("/api/runs/\(API.q(s.id))/reference") else { return model.say("Couldn't read that session", bad: true) }
                attach(Attachment(id: "session-\(s.id)", kind: .session, name: s.title, path: r["path"].string))
            }
        }
    }

    func insert(_ s: String, over range: NSRange) {
        if let tv = textView, NSMaxRange(range) <= (tv.string as NSString).length {
            tv.insertText(s, replacementRange: range)
        } else if NSMaxRange(range) <= (text as NSString).length {
            text = (text as NSString).replacingCharacters(in: range, with: s)
        }
    }

    // MARK: items

    func items(for t: Trigger) -> [TriggerItem] {
        switch t.kind {
        case .file: return fileItems(t.query)
        case .session: return sessionItems(t.query)
        case .command: return commandItems(t.query)
        }
    }

    func fileItems(_ q: String) -> [TriggerItem] {
        guard let idx = data.files[source.filesKey] else { return [] }
        let qb = Array(q.lowercased().utf8)
        var scored: [(ComposerData.FileIndex.Entry, Int)] = []
        if qb.isEmpty {
            scored = idx.entries.filter { !$0.path.dropLast($0.dir ? 1 : 0).contains("/") }.map { ($0, $0.dir ? 1 : 0) }
        } else {
            for e in idx.entries {
                guard var s = Fuzzy.score(qb, e.bytes) else { continue }
                if let b = Fuzzy.score(qb, e.base) { s += 40 + b }
                if e.dir { s -= 5 }
                scored.append((e, s))
            }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path.count < $1.0.path.count }
        return scored.prefix(60).map { e, _ in
            let p = e.dir ? String(e.path.dropLast()) : e.path
            let base = URL(fileURLWithPath: p).lastPathComponent
            let dir = (p as NSString).deletingLastPathComponent
            return TriggerItem(id: e.path, lead: .symbol(e.dir ? "folder" : FileIcon.symbol(base), e.dir ? T.accent : T.text2), title: base + (e.dir ? "/" : ""), subtitle: dir.isEmpty ? "" : dir, insert: "@\(e.path) ")
        }
    }

    func sessionItems(_ q: String) -> [TriggerItem] {
        let pool = model.sessions.filter { $0.id != exclude }
        let ranked: [Session]
        if q.isEmpty {
            ranked = pool.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            ranked = pool.compactMap { s -> (Session, Int)? in
                let a = Fuzzy.score(q, s.title).map { $0 + 30 }
                let b = Fuzzy.score(q, s.issueKey)
                let c = s.text.lowercased().contains(q.lowercased()) ? 5 : nil
                let best = [a, b, c].compactMap { $0 }.max()
                return best.map { (s, $0) }
            }
            .sorted { $0.1 > $1.1 }.map(\.0)
        }
        return ranked.prefix(30).map { s in
            let key = s.issueKey
            let tag = key.isEmpty ? String(s.title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32)) : key
            let agent = AgentKind.of(s.j["agent"].nonEmpty ?? model.config["followup"]["agent"].nonEmpty ?? "claude")
            let bits = [key, s.isOrchestrator ? "Orchestrator" : model.column(of: s).label, model.project(s.project)?.name ?? "", Fmt.ago(s.updatedAt)].filter { !$0.isEmpty }
            return TriggerItem(id: s.id, lead: .session(s), title: s.title, subtitle: bits.joined(separator: " · "), trailing: agent.rawValue, insert: "#\(tag.isEmpty ? s.id : tag) ", session: s)
        }
    }

    func commandItems(_ q: String) -> [TriggerItem] {
        let all: [JSON]
        if case .project(let p) = source { all = data.commands[p] ?? [] } else { all = model.commands }
        let rank: (JSON) -> Int = { c in
            switch c["source"].string {
            case "skill": return c["scope"].string == "project" ? 0 : 1
            case "command": return 1
            case "built-in": return 2
            default: return 3
            }
        }
        let hits: [JSON]
        if q.isEmpty {
            hits = all.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0["name"].string < $1["name"].string }
        } else {
            hits = all.compactMap { c -> (JSON, Int)? in
                let n = Fuzzy.score(q, c["name"].string).map { $0 + 50 }
                let d = c["description"].string.lowercased().contains(q.lowercased()) ? 1 : nil
                return (n ?? d).map { (c, $0) }
            }
            .sorted { $0.1 > $1.1 }.map(\.0)
        }
        return hits.prefix(60).map { c in
            let src = c["source"].string
            let icon = src == "built-in" ? "command" : src == "plugin" ? "puzzlepiece.extension" : src == "command" ? "terminal" : "sparkles"
            let tint = src == "built-in" ? T.text2 : src == "plugin" ? T.purple : T.yellow
            let scope = c["scope"].string
            return TriggerItem(id: c["name"].string, lead: .symbol(icon, tint), title: "/" + c["name"].string, subtitle: c["description"].string,
                               trailing: [c["hint"].string.count < 28 ? c["hint"].string : "", scope == "built-in" ? "" : scope].filter { !$0.isEmpty }.joined(separator: "  "),
                               mono: true, insert: "/\(c["name"].string) ")
        }
    }
}

enum FileIcon {
    static func symbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "ts", "tsx", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m", "cpp": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "md", "txt", "rst": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "ico": return "photo"
        case "sh", "zsh", "bash": return "terminal"
        case "css", "scss", "html": return "paintbrush"
        case "lock": return "lock"
        default: return "doc"
        }
    }
}

struct TriggerMenu: View {
    let trigger: Trigger
    let items: [TriggerItem]
    let highlight: Int
    let loading: Bool
    var error = ""
    let root: String
    let pick: (TriggerItem) -> Void
    let hover: (Int) -> Void

    var title: String {
        switch trigger.kind {
        case .file: return root.isEmpty ? "Files" : "Files in \(URL(fileURLWithPath: root).lastPathComponent)"
        case .session: return "Reference a session"
        case .command: return "Skills & commands"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: trigger.kind.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.accent)
                Text(title).font(T.ui(11.5, .semibold)).foregroundStyle(T.text2)
                if !trigger.query.isEmpty { Text(trigger.query).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1) }
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
                Text(verbatim: "\(items.count)\(items.count >= 60 ? "+" : "")").font(T.ui(10.5)).foregroundStyle(T.text3).monospacedDigit()
            }
            .padding(.horizontal, 12).frame(height: 32)
            Hairline()
            if items.isEmpty {
                Text(loading ? "Indexing files…" : !error.isEmpty ? "Can't list this folder: \(error)" : trigger.kind == .session ? "No other sessions match" : "No matches").font(T.ui(12)).foregroundStyle(T.text3)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                                Button { pick(it) } label: { row(it, on: i == highlight) }
                                    .buttonStyle(.plain)
                                    .onHover { if $0 { hover(i) } }
                            }
                        }
                        .padding(4)
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(CGFloat(items.count) * 39 + 8, 290))
                    .onChange(of: highlight) { if items.indices.contains(highlight) { proxy.scrollTo(items[highlight].id) } }
                }
            }
            Hairline()
            KeyHints(hints: [("↑↓", "navigate"), ("↩", trigger.kind == .session ? "reference" : "insert"), ("esc", "dismiss")])
                .padding(.horizontal, 12).frame(height: 28)
        }
        .frame(width: 500)
        .background(T.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
    }

    func row(_ it: TriggerItem, on: Bool) -> some View {
        PickRow(title: it.title, subtitle: it.subtitle, mono: it.mono, highlighted: on, height: 38) {
            switch it.lead {
            case .symbol(let s, let c): Image(systemName: s).font(.system(size: 12, weight: .medium)).foregroundStyle(c)
            case .session(let s): SessionIcon(session: s, size: 13)
            case .agent(let a): AgentMark(agent: a, size: 16)
            }
        } trail: {
            if it.session != nil {
                AgentMark(agent: AgentKind.of(it.trailing), size: 15)
            } else if !it.trailing.isEmpty {
                Text(it.trailing).font(T.ui(10.5)).foregroundStyle(T.text3).lineLimit(1)
            }
        }
    }
}

// MARK: - New task sheet

extension AppModel {
    /// The sheet's create: like `create(_:direct:project:)`, plus the
    /// worker's job options for a worker started directly.
    func createTask(_ text: String, direct: Bool, project: String?, opts: [String: Any], workspace: [String: Any] = [:]) async -> Bool {
        let repo = project.flatMap { self.project($0)?.path } ?? ""
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if !direct || t.range(of: #"^https://[^/]*slack\.com/archives/"#, options: .regularExpression) != nil {
            return await create(t, direct: direct, project: project)
        }
        var ok = false
        await act {
            var body: [String: Any] = ["brief": t, "opts": opts]
            if !repo.isEmpty { body["repo"] = repo }
            body.merge(workspace) { $1 }
            let out = try await API.post("/api/tasks", body)
            self.say(out["state"].string == "queued" ? "Queued: every worker slot is busy." : "Worker started on \(out["branch"].string)")
            self.open(out["taskId"].string)
            ok = true
        }
        return ok
    }
}

/// ⌘N: a Linear-style new-issue modal. Project in the header, the brief in
/// a roomy editor with `@` `#` `/`, who writes the brief as two cards, and
/// the worker's agent, model and access in the footer.
struct ComposeSheet: View {
    @Environment(AppModel.self) var model
    @StateObject private var text = Box("")
    @StateObject private var direct = Box(false)
    @StateObject private var project = Box("")
    @StateObject private var busy = Box(false)
    @StateObject private var items = Box<[Attachment]>([])
    @StateObject private var agent = Box("claude")
    @StateObject private var modelId = Box("")
    @StateObject private var effort = Box("")
    @StateObject private var mode = Box("bypassPermissions")
    @StateObject private var projectOpen = Box(false)
    @StateObject private var git = Box<JSON>(.null)
    @StateObject private var workspace = Box("worktree")
    @StateObject private var base = Box("")
    @StateObject private var branchName = Box("")
    @ObservedObject private var data = ComposerData.shared
    @FocusState private var focused: Bool

    var isSlack: Bool { text.v.trimmingCharacters(in: .whitespaces).range(of: #"^https://[^/]*slack\.com/archives/"#, options: .regularExpression) != nil }
    var empty: Bool { text.v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && items.v.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if direct.v && !isSlack && !git.v.isNull {
                    WorkspaceBar(git: git.v, workspace: $workspace.v, base: $base.v, branchName: $branchName.v)
                        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                PromptEditor(text: $text.v, placeholder: "Describe what you want built, or paste a Slack thread link…  @ files · # sessions · / skills",
                             source: .project(project.v), fontSize: 15, minHeight: 96, maxHeight: 280, menuAbove: false,
                             focused: $focused) { a in withAnimation(M.snappy) { items.v.append(a) } }
                    .padding(.horizontal, 14).padding(.top, 4)
                if !items.v.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(items.v) { a in
                                AttachmentChip(item: a) { withAnimation(M.snappy) { items.v.removeAll { $0.id == a.id } } }
                                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 8)
                    }
                }
                modes.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
                Hairline()
                footer
            }
            .frame(width: 700)
            .floatingPanel()
            .padding(.top, 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(M.snappy, value: direct.v)
        .animation(M.snappy, value: isSlack)
        .onAppear {
            focused = true
            text.v = model.composeText
            model.composeText = ""
            project.v = model.composeProject ?? model.projectFilter ?? model.defaultProject?.id ?? ""
            let d = model.config["followup"]
            agent.v = d["agent"].nonEmpty ?? "claude"
            modelId.v = agent.v == "claude" ? d["model"].string : d["agentModel"].string
            effort.v = d["effort"].string
            mode.v = d["permissionMode"].nonEmpty ?? "bypassPermissions"
        }
        .onKeyPress(.escape) { model.composeOpen = false; return .handled }
        .onChange(of: data.snapshotOpen) { if data.snapshotOpen.hasPrefix("compose-") { direct.v = true } }
        .task(id: project.v) {
            // A new project: its own branches, and back to a fresh worktree.
            let q = project.v.isEmpty ? "" : "?project=\(API.q(project.v))"
            let out = (try? await API.get("/api/git\(q)")) ?? .null
            withAnimation(M.snappy) {
                git.v = out
                workspace.v = "worktree"
                base.v = ""
                branchName.v = ""
            }
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Logo(size: 16)
            Text("New task").font(T.ui(13, .semibold))
            if !model.projects.isEmpty {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3)
                Button { projectOpen.v.toggle() } label: {
                    PickerChip(text: model.project(project.v)?.name ?? "Project", open: projectOpen.v) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(T.accent)
                    }
                }
                .buttonStyle(Pressable(scale: 0.97))
                .help(model.project(project.v)?.path ?? "Project")
                .popover(isPresented: $projectOpen.v, arrowEdge: .bottom) {
                    ProjectPanel(current: project.v) { id in projectOpen.v = false; project.v = id } add: { projectOpen.v = false; model.addProject() }
                        .environment(model)
                }
            }
            Spacer()
            IconButton(icon: "xmark", help: "Close (Esc)") { model.composeOpen = false }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder var modes: some View {
        if isSlack {
            ModeCard(icon: "number", tint: T.slack, title: "Slack thread", detail: "Runs the pipeline on the thread: triage, fix or reply, and a PR if it needs one.", on: true) {}
                .transition(.opacity)
        } else {
            HStack(spacing: 10) {
                ModeCard(icon: "point.3.connected.trianglepath.dotted", tint: T.accent, title: "Plan with the orchestrator",
                         detail: "It writes the brief, picks the agent and starts a worker in a fresh worktree.", on: !direct.v) { direct.v = false }
                ModeCard(icon: "hammer", tint: T.green, title: "Start a worker now",
                         detail: "This text is the brief. A worker starts on it right away in its own worktree.", on: direct.v) { direct.v = true }
            }
            .transition(.opacity)
        }
    }

    var footer: some View {
        HStack(spacing: 4) {
            Button { pickFiles() } label: { ComposerChip(icon: "paperclip", text: "") }
                .buttonStyle(.plain).help("Attach images or files")
            if direct.v && !isSlack {
                let a = AgentKind.of(agent.v)
                AgentModelPicker(agent: a, modelId: modelId.v, effort: effort.v, pick: { na, m in agent.v = na.rawValue; modelId.v = m }, setEffort: { effort.v = $0 })
                AccessPicker(agent: a, mode: mode.v) { mode.v = $0 }
                    .transition(.opacity)
            } else if !isSlack {
                HStack(spacing: 6) {
                    AgentMark(agent: AgentKind.of(model.config["followup"]["agent"].nonEmpty ?? "claude"), size: 14)
                    Text("The orchestrator chooses the worker's agent").font(T.ui(11.5)).foregroundStyle(T.text3)
                }
                .padding(.horizontal, 6)
                .transition(.opacity)
            }
            Spacer()
            Text("⌘↩").font(T.ui(11)).foregroundStyle(T.text3).padding(.trailing, 4)
            Button { submit() } label: {
                HStack(spacing: 6) {
                    if busy.v { ProgressView().controlSize(.mini) }
                    Text(isSlack ? "Run pipeline" : direct.v ? "Start worker" : "Send to orchestrator")
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                }
            }
            .buttonStyle(LButton(primary: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(busy.v || empty)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(T.panel.opacity(0.35))
    }

    func submit() {
        let full = Attachment.compose(text.v, items.v)
        guard !full.isEmpty else { return }
        busy.v = true
        let isClaude = agent.v == "claude"
        var opts: [String: Any] = ["agent": agent.v, "permissionMode": mode.v, "effort": effort.v]
        opts[isClaude ? "model" : "agentModel"] = modelId.v
        if isClaude && modelId.v.isEmpty { opts.removeValue(forKey: "model") }
        var ws: [String: Any] = ["workspace": workspace.v]
        if workspace.v == "worktree" {
            if !base.v.isEmpty { ws["base"] = base.v }
            let b = branchName.v.trimmingCharacters(in: .whitespaces)
            if !b.isEmpty { ws["branch"] = b }
        }
        Task {
            if await model.createTask(full, direct: direct.v, project: project.v.isEmpty ? nil : project.v, opts: opts, workspace: ws) { model.composeOpen = false }
            busy.v = false
        }
    }

    func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = "Attach"
        guard p.runModal() == .OK else { return }
        withAnimation(M.snappy) { items.v += p.urls.map { Attachment.file($0) } }
    }
}

struct ModeCard: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let on: Bool
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? tint : T.text3)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill((on ? tint : T.text3).opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(T.ui(12.5, .medium)).foregroundStyle(on ? T.text : T.text2)
                    Text(detail).font(T.ui(11.5)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(on ? T.accent : T.line, lineWidth: 1.5)
                    Circle().fill(T.accent).padding(3.5).scaleEffect(on ? 1 : 0.2).opacity(on ? 1 : 0)
                }
                .frame(width: 14, height: 14).padding(.top, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? T.accentSoft.opacity(0.55) : hover.v ? T.hover : T.panel.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? T.accent.opacity(0.55) : T.line, lineWidth: 1))
            .contentShape(Rectangle())
            .animation(M.snappy, value: on)
        }
        .buttonStyle(Pressable(scale: 0.985))
        .hoverBox(hover)
    }
}

struct ProjectPanel: View {
    @Environment(AppModel.self) var model
    let current: String
    let pick: (String) -> Void
    let add: () -> Void
    @StateObject private var query = Box("")
    @StateObject private var hi = Box(0)

    var body: some View {
        let hits = model.projects.filter { query.v.isEmpty || Fuzzy.score(query.v, $0.name) != nil || $0.path.lowercased().contains(query.v.lowercased()) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(T.text3)
                PickerField(placeholder: "Search projects…", text: $query.v,
                            onMove: { d in if !hits.isEmpty { hi.v = (hi.v + d + hits.count) % hits.count } },
                            onSubmit: { if hits.indices.contains(hi.v) { pick(hits[hi.v].id) } })
                    .frame(height: 20)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Hairline()
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, p in
                        Button { pick(p.id) } label: {
                            PickRow(title: p.name, subtitle: p.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), checked: p.id == current, highlighted: hi.v == i) {
                                Image(systemName: "square.stack.3d.up").font(.system(size: 12)).foregroundStyle(T.accent)
                            } trail: { EmptyView() }
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { hi.v = i } }
                    }
                }
                .padding(5)
            }
            .frame(height: min(CGFloat(hits.count) * 41 + 10, 280))
            Hairline()
            Button(action: add) {
                PickRow(title: "Add project…", dim: true, height: 34) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text3) } trail: { EmptyView() }
            }
            .buttonStyle(.plain).padding(5)
        }
        .frame(width: 340)
        .background(T.raised)
        .onAppear { hi.v = hits.firstIndex { $0.id == current } ?? 0 }
    }
}

// MARK: - Snapshot hook

/// `BRIDGE_SNAPSHOT_COMPOSER=/tmp/dir`: with a chat open, render the
/// composer's menus and pickers (popovers are their own windows, so the
/// page snapshots can't see them) and the New task sheet to PNGs.
enum ComposerSnapshots {
    @MainActor static func run(model: AppModel, setText: @escaping (String) -> Void) {
        guard let dir = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_COMPOSER"], !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let data = ComposerData.shared
            let focus = { (NSApp.windows.first { $0.isVisible && $0.frame.width > 800 })?.makeKey() }
            for (name, text) in [("at", "@"), ("at-query", "@readme"), ("hash", "#"), ("slash", "/")] {
                focus()
                setText(text)
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                shoot(dir, name)
            }
            setText("")
            for name in ["model", "access", "context", "mcp", "tasks"] {
                data.snapshotOpen = name
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                shoot(dir, name)
                data.snapshotOpen = "none"
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            data.snapshotOpen = ""
            model.composeText = "Add a dark mode toggle to settings, see @"
            model.composeOpen = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            shoot(dir, "compose")
            for name in ["compose-direct", "compose-workspace", "compose-base"] {
                data.snapshotOpen = name
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                shoot(dir, name)
            }
            data.snapshotOpen = ""
            model.composeOpen = false
        }
    }

    @MainActor static var started = false

    /// Every visible window: the main one and any popover on top of it.
    @MainActor static func shoot(_ dir: String, _ name: String) {
        for (i, w) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
            guard let view = w.contentView?.superview ?? w.contentView, view.bounds.width > 200,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let suffix = w.frame.width > 800 ? "" : "-pop\(i)"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/composer-\(name)\(suffix).png"))
        }
    }
}
