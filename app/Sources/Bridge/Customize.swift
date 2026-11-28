import AppKit
import SwiftUI

// MARK: - Settings › Customize
//
// What each agent loads, in two tabs (`model.customizeTab`): MCP servers
// (Servers.swift) and skills (server/customize.js). Skills are edited in
// place, created in any agent's folder, opened in Finder and deleted to the
// Trash. Plugins have their own pane (Settings › Plugins, below).

struct CustomizeSettings: View {
    @Environment(AppModel.self) var model
    let q: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if q.isEmpty {
                SlidingTabs(tabs: [
                    .init(id: "mcp", label: "MCP servers", icon: "server.rack"),
                    .init(id: "skills", label: "Skills", icon: "wand.and.stars"),
                ], selection: Binding(get: { model.customizeTab }, set: { model.customizeTab = $0 }))
            }
            switch q.isEmpty ? model.customizeTab : "mcp" {
            case "skills": SkillsSettings()
            default: MCPSettings(q: q)
            }
        }
        .animation(M.snappy, value: model.customizeTab)
    }
}

// MARK: Skills

struct SkillItem: Identifiable, Hashable {
    let j: JSON
    var id: String { j["dir"].string }
    var name: String { j["name"].string }
    var folder: String { j["folder"].string }
    var description: String { j["description"].string }
    var agent: String { j["agent"].string }
    var agentLabel: String { j["agentLabel"].string }
    var scope: String { j["scope"].string }
    var dir: String { j["dir"].string }
    var file: String { j["file"].string }
    var shown: String { j["shown"].string }
    var link: String { j["link"].string }
}

/// An agent's mark, or two people for the shared (.agents) folder.
struct SkillAgentMark: View {
    let agent: String
    var size: CGFloat = 22
    var body: some View {
        if agent == "shared" {
            RoundedRectangle(cornerRadius: size * 0.27).fill(T.raised)
                .overlay(RoundedRectangle(cornerRadius: size * 0.27).stroke(T.line, lineWidth: 1))
                .overlay(Image(systemName: "person.2.fill").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(T.text2))
                .frame(width: size, height: size)
        } else {
            AgentMark(agent: AgentKind.of(agent), size: size)
        }
    }
}

struct SkillsSettings: View {
    @Environment(AppModel.self) var model
    @StateObject private var data = Box(JSON.null)
    @StateObject private var agent = Box("")
    @StateObject private var query = Box("")
    @StateObject private var project = Box("")
    @StateObject private var projectOpen = Box(false)
    @StateObject private var newOpen = Box(false)
    @StateObject private var editing = Box<SkillItem?>(nil)

    var skills: [SkillItem] { data.v["skills"].array.map(SkillItem.init) }
    var shown: [SkillItem] {
        let words = query.v.lowercased().split(separator: " ").map(String.init)
        return skills.filter { s in
            (agent.v.isEmpty || s.agent == agent.v) && words.allSatisfy { "\(s.name) \(s.description) \(s.shown)".lowercased().contains($0) }
        }
    }

    var body: some View {
        Group {
            if let s = editing.v {
                SkillEditor(skill: s, project: project.v) { withAnimation(M.snappy) { editing.v = nil }; Task { await load() } }
                    .transition(.opacity)
            } else {
                list.transition(.opacity)
            }
        }
        .animation(M.snappy, value: editing.v?.id)
        .task(id: project.v) { await load() }
        .onAppear { if project.v.isEmpty { project.v = model.projectFilter ?? AppModel.rootId } }
        .task(id: model.snapshotSkillEdit) {
            guard model.snapshotSkillEdit, editing.v == nil else { return }
            await load()
            editing.v = skills.first
        }
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { projectOpen.v.toggle() } label: {
                    PickerChip(text: model.project(project.v).map { $0.root ? "Your skills" : $0.name } ?? "Your skills", open: projectOpen.v) {
                        if let p = model.project(project.v) { ProjectBadge(project: p, size: 14) }
                    }
                }
                .buttonStyle(Pressable(scale: B.press))
                .help("Your own skills, plus a project's skills when you pick one")
                .popover(isPresented: $projectOpen.v, arrowEdge: .bottom) {
                    ProjectPanel(current: project.v) { id in projectOpen.v = false; project.v = id } add: { projectOpen.v = false; model.addProject() }
                        .environment(model)
                }
                SearchField(placeholder: "Filter skills", text: $query.v).frame(maxWidth: 240)
                Spacer()
                IconButton(icon: "arrow.clockwise", help: "Read the folders again") { Task { await load() } }
                Button { newOpen.v = true } label: { Label("New skill", systemImage: "plus") }
                    .buttonStyle(LButton(primary: true))
                    .popover(isPresented: $newOpen.v, arrowEdge: .bottom) {
                        NewSkillForm(project: project.v) { made in
                            newOpen.v = false
                            Task {
                                await load()
                                if let s = skills.first(where: { $0.dir == made }) { editing.v = s }
                            }
                        }
                        .environment(model)
                    }
            }
            filters
            if data.v.isNull {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
            } else if shown.isEmpty {
                SRow(title: skills.isEmpty ? "No skills yet" : "No skills match", detail: skills.isEmpty ? "Create one with New skill: it's a folder with a SKILL.md the agent reads." : "Try another agent or filter.") { EmptyView() }
                    .card()
            } else {
                let groups = Dictionary(grouping: shown) { $0.agent }
                ForEach(["claude", "codex", "cursor", "devin", "shared"].filter { groups[$0] != nil }, id: \.self) { a in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SkillAgentMark(agent: a, size: 16)
                            Text(groups[a]?.first?.agentLabel ?? a).font(T.ui(12.5, .semibold)).foregroundStyle(T.text)
                            Text(verbatim: "\(groups[a]?.count ?? 0)").font(T.ui(12)).foregroundStyle(T.text3)
                            if a == "shared" { Text("~/.agents/skills: read by several agents").font(T.ui(11.5)).foregroundStyle(T.text3) }
                        }
                        VStack(spacing: 0) {
                            ForEach(groups[a] ?? []) { s in
                                SkillRow(skill: s) { editing.v = s } delete: { delete(s) }
                                if s.id != groups[a]?.last?.id { RowDivider(inset: 16) }
                            }
                        }
                        .card()
                    }
                }
            }
        }
    }

    var filters: some View {
        HStack(spacing: 4) {
            filter("", "All", skills.count)
            ForEach(["claude", "codex", "cursor", "devin", "shared"], id: \.self) { a in
                filter(a, a == "shared" ? "Shared" : AgentKind.of(a).label, skills.filter { $0.agent == a }.count)
            }
        }
    }

    func filter(_ id: String, _ label: String, _ count: Int) -> some View {
        let on = agent.v == id
        return Button { withAnimation(M.snappy) { agent.v = id } } label: {
            HStack(spacing: 5) {
                if !id.isEmpty { SkillAgentMark(agent: id, size: 14) }
                Text(label)
                Text(verbatim: "\(count)").foregroundStyle(T.text3).monospacedDigit()
            }
        }
        .buttonStyle(LButton(kind: on ? .secondary : .ghost, small: true))
        .opacity(count == 0 && !id.isEmpty ? 0.45 : 1)
    }

    func load() async {
        let q = project.v.isEmpty ? "" : "?project=\(API.q(project.v))"
        data.v = (try? await API.get("/api/customize/skills\(q)")) ?? .obj(["skills": .arr([])])
    }

    func delete(_ s: SkillItem) {
        let a = NSAlert()
        a.messageText = s.link.isEmpty ? "Delete the \(s.name) skill?" : "Remove the link to \(s.name)?"
        a.informativeText = s.link.isEmpty ? "Its folder (\(s.shown)) moves to the Trash, so you can put it back from Finder." : "Only the link in \(s.shown) goes; the skill itself stays in \(s.link)."
        a.addButton(withTitle: s.link.isEmpty ? "Move to Trash" : "Remove Link")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await model.act {
                try await API.post("/api/customize/skills/delete", ["path": s.dir, "project": project.v])
                self.model.say(s.link.isEmpty ? "Moved \(s.name) to the Trash" : "Removed the link to \(s.name)")
            }
            await load()
        }
    }
}

struct SkillRow: View {
    let skill: SkillItem
    let edit: () -> Void
    let delete: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name).font(T.ui(13, .medium)).foregroundStyle(T.text)
                    if skill.scope == "project" { Chip(text: "Project", tint: T.accent) }
                    if !skill.link.isEmpty { Chip(text: "Linked", icon: "link").help("A link to \(skill.link)") }
                }
                if !skill.description.isEmpty { Text(skill.description).font(T.ui(12)).foregroundStyle(T.text2).lineLimit(2) }
                Text(skill.shown).font(T.mono(10.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit", action: edit).buttonStyle(LButton(small: true))
            IconButton(icon: "folder", help: "Open the skill's folder", size: B.small) { NSWorkspace.shared.open(URL(fileURLWithPath: skill.dir)) }
            MoreMenu(size: B.small) {
                Button(action: edit) { Label("Edit SKILL.md", systemImage: "pencil") }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: skill.dir)) } label: { Label("Open Folder", systemImage: "folder") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.file)]) } label: { Label("Reveal SKILL.md in Finder", systemImage: "doc.text.magnifyingglass") }
                Button { copyToPasteboard(skill.dir) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                Divider()
                Button(role: .destructive, action: delete) { Label(skill.link.isEmpty ? "Move to Trash…" : "Remove Link…", systemImage: "trash") }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hover.v ? T.hover.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .hoverBox(hover)
    }
}

/// SKILL.md in a plain monospaced editor: ⌘S saves, leaving with changes asks first.
struct SkillEditor: View {
    @Environment(AppModel.self) var model
    let skill: SkillItem
    let project: String
    let close: () -> Void
    @StateObject private var text = Box("")
    @StateObject private var saved = Box("")
    @StateObject private var loading = Box(true)

    var dirty: Bool { text.v != saved.v }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconButton(icon: "chevron.left", help: "Back to skills") { leave() }
                SkillAgentMark(agent: skill.agent, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name).font(T.ui(14, .semibold)).foregroundStyle(T.text)
                        if dirty { Circle().fill(T.accent).frame(width: 6, height: 6).help("Unsaved") }
                    }
                    Text(skill.file.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                IconButton(icon: "folder", help: "Open the skill's folder") { NSWorkspace.shared.open(URL(fileURLWithPath: skill.dir)) }
                if dirty { Button("Revert") { text.v = saved.v }.buttonStyle(LButton()) }
                Button("Save") { save() }.buttonStyle(LButton(primary: true)).keyboardShortcut("s").disabled(!dirty || loading.v)
            }
            TextEditor(text: $text.v)
                .font(T.mono(12.5))
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(minHeight: 480)
                .background(T.codeBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.line, lineWidth: 1))
                .disabled(loading.v)
                .opacity(loading.v ? 0.5 : 1)
            Text("Agents read the front matter's name and description to decide when to use the skill; the rest is its instructions.")
                .font(T.ui(11.5)).foregroundStyle(T.text3)
        }
        .task {
            guard let out = try? await API.get("/api/customize/skills/file?path=\(API.q(skill.file))&project=\(API.q(project))") else {
                if Task.isCancelled { return }
                model.say("Couldn't read \(skill.name)'s SKILL.md", bad: true)
                return close()
            }
            text.v = out["text"].string
            saved.v = text.v
            loading.v = false
        }
    }

    func save() {
        let body = text.v
        Task {
            await model.act {
                try await API.post("/api/customize/skills/file", ["path": self.skill.file, "text": body, "project": self.project])
                self.saved.v = body
                self.model.say("Saved \(self.skill.name)")
            }
        }
    }

    func leave() {
        if dirty {
            let a = NSAlert()
            a.messageText = "Discard your changes to \(skill.name)?"
            a.addButton(withTitle: "Discard")
            a.addButton(withTitle: "Keep Editing")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        close()
    }
}

/// Name, description, which agent's folder and user or project.
struct NewSkillForm: View {
    @Environment(AppModel.self) var model
    let project: String
    let made: (String) -> Void
    @StateObject private var name = Box("")
    @StateObject private var desc = Box("")
    @StateObject private var agent = Box("claude")
    @StateObject private var scope = Box("user")
    @StateObject private var busy = Box(false)

    var canProject: Bool { !(model.project(project)?.root ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New skill").font(T.ui(14, .semibold))
            field("Name", "release-notes", $name.v)
            field("When to use it", "Write release notes from the merged PRs", $desc.v)
            VStack(alignment: .leading, spacing: 6) {
                Text("For").font(T.ui(11.5, .medium)).foregroundStyle(T.text3)
                HStack(spacing: 4) {
                    ForEach(["claude", "codex", "cursor", "devin", "shared"], id: \.self) { a in
                        Button { agent.v = a } label: {
                            HStack(spacing: 5) { SkillAgentMark(agent: a, size: 14); Text(a == "shared" ? "Shared" : AgentKind.of(a).label) }
                        }
                        .buttonStyle(LButton(kind: agent.v == a ? .secondary : .ghost, small: true))
                    }
                }
            }
            if canProject && agent.v != "codex" {
                SlidingTabs(tabs: [
                    .init(id: "user", label: "Just me", icon: "person"),
                    .init(id: "project", label: model.project(project)?.name ?? "Project", icon: "folder"),
                ], selection: $scope.v)
            }
            HStack {
                Spacer()
                Button {
                    busy.v = true
                    Task {
                        var made = ""
                        await model.act {
                            let out = try await API.post("/api/customize/skills", ["agent": self.agent.v, "scope": self.canProject && self.agent.v != "codex" ? self.scope.v : "user", "name": self.name.v, "description": self.desc.v, "project": self.project])
                            made = out["dir"].string
                        }
                        busy.v = false
                        if !made.isEmpty { self.made(made) }
                    }
                } label: { Text("Create") }
                .buttonStyle(LButton(primary: true))
                .disabled(name.v.trimmingCharacters(in: .whitespaces).isEmpty || busy.v)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(T.ui(11.5, .medium)).foregroundStyle(T.text3)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(T.text3))
                .textFieldStyle(.plain).font(T.ui(13))
                .padding(.horizontal, 10).frame(height: B.regular)
                .background(RoundedRectangle(cornerRadius: B.radius(B.regular), style: .continuous).fill(T.raised))
                .overlay(RoundedRectangle(cornerRadius: B.radius(B.regular), style: .continuous).stroke(T.line, lineWidth: 1))
        }
    }
}

// MARK: Plugins
//
// Settings › Plugins, one section per agent (server/customize.js). Claude
// Code's install, uninstall, enable and disable through its CLI, with its
// marketplace; Codex's and Devin's are removed through theirs (install them
// there: Codex from its marketplaces, Devin from a repo); Cursor's are
// read-only, Cursor manages them itself.

struct PluginsSettings: View {
    @Environment(AppModel.self) var model
    let q: String
    @StateObject private var data = Box(JSON.null)
    @StateObject private var query = Box("")
    @StateObject private var busy = Box(Set<String>())
    @StateObject private var refreshing = Box(false)

    var claude: JSON { data.v["claude"] }
    var available: [JSON] {
        let words = (q.isEmpty ? query.v : q).lowercased().split(separator: " ").map(String.init)
        return claude["available"].array.filter { p in words.allSatisfy { "\(p["name"].string) \(p["description"].string)".lowercased().contains($0) } }
    }
    func hits(_ list: [JSON], _ agent: String) -> [JSON] {
        list.filter { Prefs.hit(q, $0["name"].string, $0["description"].string, $0["marketplace"].string, agent, "plugin plugins") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if data.v.isNull {
                if q.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30) }
            } else {
                claudeSection
                if q.isEmpty || !available.isEmpty { marketplace }
                codexSection
                cursorSection
                devinSection
            }
        }
        .task { await load() }
    }

    var claudeSection: some View {
        SSection(title: "Claude Code", detail: "Installed through Claude Code's plugin command; a plugin can add skills, commands, agents, hooks and MCP servers") {
            if q.isEmpty, let e = claude["error"].nonEmpty { SRow(title: "Couldn't list plugins", detail: e) { EmptyView() } }
            if q.isEmpty && claude["installed"].array.isEmpty && claude["error"].string.isEmpty {
                SRow(title: "No plugins installed", detail: "Browse the marketplace below") { EmptyView() }
            }
            ForEach(hits(claude["installed"].array, "claude code"), id: \.self) { p in installedRow(p) }
        } trailing: {
            if q.isEmpty { IconButton(icon: "arrow.clockwise", help: "List again from the marketplaces", spinning: refreshing.v) { Task { await load(refresh: true) } } }
        }
    }

    var marketplace: some View {
        SSection(title: "Claude Code marketplace", detail: "\(claude["available"].array.count) plugins from your marketplaces, most installed first") {
            if q.isEmpty {
                HStack { SearchField(placeholder: "Search plugins", text: $query.v); Spacer() }
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            ForEach(Array(available.prefix(q.isEmpty && query.v.isEmpty ? 25 : q.isEmpty ? 60 : 8)), id: \.self) { p in availableRow(p) }
            if q.isEmpty && available.isEmpty { SRow(title: "No plugins match", detail: "") { EmptyView() } }
        }
    }

    var codexSection: some View {
        let j = data.v["codex"]
        return SSection(title: "Codex", detail: "Installed with codex plugin add, from Codex's marketplaces; listed from ~/.codex/config.toml") {
            if q.isEmpty && j["plugins"].array.isEmpty { SRow(title: "No Codex plugins", detail: j["error"].nonEmpty ?? "Codex lists them in ~/.codex/config.toml") { EmptyView() } }
            ForEach(hits(j["plugins"].array, "codex"), id: \.self) { p in
                agentRow(p, agent: "codex", chips: p["enabled"].bool ? [] : ["Off"])
            }
        }
    }

    var cursorSection: some View {
        SSection(title: "Cursor", detail: "Plugins Cursor has fetched. Install, remove and switch them off in Cursor itself") {
            if q.isEmpty && data.v["cursor"]["plugins"].array.isEmpty { SRow(title: "No Cursor plugins", detail: "Cursor keeps them in ~/.cursor/plugins") { EmptyView() } }
            ForEach(hits(data.v["cursor"]["plugins"].array, "cursor"), id: \.self) { p in cursorRow(p) }
        }
    }

    var devinSection: some View {
        let j = data.v["devin"]
        return SSection(title: "Devin", detail: "Installed with devin plugins install, from a GitHub repo; your org's required plugins come back if removed") {
            if q.isEmpty && j["plugins"].array.isEmpty { SRow(title: j["error"].nonEmpty == nil ? "No Devin plugins" : "Couldn't list plugins", detail: j["error"].nonEmpty ?? "devin plugins list shows none") { EmptyView() } }
            ForEach(hits(j["plugins"].array, "devin"), id: \.self) { p in
                agentRow(p, agent: "devin", chips: p["blocked"].bool ? ["Blocked"] : [])
            }
        }
    }

    func meta(_ p: JSON) -> String {
        [p["description"].string, [p["marketplace"].string, p["version"].nonEmpty.map { "v\($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func installedRow(_ p: JSON) -> some View {
        let id = p["id"].string
        return SRow(title: p["name"].string, detail: meta(p), icon: AnyView(PluginIcon(name: p["name"].string))) {
            HStack(spacing: 6) {
                if busy.v.contains(id) { ProgressView().controlSize(.small) }
                SToggle(on: Binding(get: { p["enabled"].bool }, set: { on in act("claude", on ? "enable" : "disable", id) }))
                    .help(p["enabled"].bool ? "Turn off" : "Turn on")
                MoreMenu(size: B.small) {
                    if let d = p["dir"].nonEmpty { Button { NSWorkspace.shared.open(URL(fileURLWithPath: d)) } label: { Label("Open Folder", systemImage: "folder") } }
                    Button { copyToPasteboard(id) } label: { Label("Copy Plugin ID", systemImage: "doc.on.doc") }
                    Divider()
                    Button(role: .destructive) { confirmRemove(p, agent: "claude", action: "uninstall") } label: { Label("Uninstall…", systemImage: "trash") }
                }
            }
        }
    }

    /// A Codex or Devin plugin: what it is, and Remove through the agent's CLI.
    func agentRow(_ p: JSON, agent: String, chips: [String]) -> some View {
        let id = p["id"].string
        return SRow(title: p["name"].string, detail: meta(p), icon: AnyView(PluginIcon(name: p["name"].string))) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { Chip(text: $0) }
                if busy.v.contains(id) { ProgressView().controlSize(.small) }
                MoreMenu(size: B.small) {
                    if let d = p["dir"].nonEmpty { Button { NSWorkspace.shared.open(URL(fileURLWithPath: d)) } label: { Label("Open Folder", systemImage: "folder") } }
                    Button { copyToPasteboard(id) } label: { Label("Copy Plugin ID", systemImage: "doc.on.doc") }
                    Divider()
                    Button(role: .destructive) { confirmRemove(p, agent: agent, action: "remove") } label: { Label("Remove…", systemImage: "trash") }
                }
            }
        }
    }

    func availableRow(_ p: JSON) -> some View {
        let id = p["id"].string
        return SRow(title: p["name"].string, detail: p["description"].string, icon: AnyView(PluginIcon(name: p["name"].string))) {
            HStack(spacing: 8) {
                if p["installs"].int > 0 { Text(Fmt.tokens(p["installs"].int) + " installs").font(T.ui(11.5)).foregroundStyle(T.text3).monospacedDigit() }
                if busy.v.contains(id) { ProgressView().controlSize(.small) }
                Button("Install") { act("claude", "install", id) }.buttonStyle(LButton(small: true)).disabled(busy.v.contains(id))
            }
        }
    }

    func cursorRow(_ p: JSON) -> some View {
        SRow(title: p["name"].string, detail: meta(p), icon: AnyView(PluginIcon(name: p["name"].string))) {
            HStack(spacing: 6) {
                if p["mcp"].bool { Chip(text: "MCP") }
                if p["skills"].int > 0 { Chip(text: "\(p["skills"].int) skills") }
                if let d = p["dir"].nonEmpty { IconButton(icon: "folder", help: "Open the plugin's folder", size: B.small) { NSWorkspace.shared.open(URL(fileURLWithPath: d)) } }
                if let h = p["homepage"].nonEmpty { IconButton(icon: "arrow.up.right", help: h, size: B.small) { openURL(h) } }
            }
        }
    }

    func load(refresh: Bool = false) async {
        refreshing.v = refresh
        data.v = (try? await API.get("/api/customize/plugins\(refresh ? "?refresh=1" : "")")) ?? .obj(["claude": .obj(["error": .str("Bridge's server didn't answer")])])
        refreshing.v = false
    }

    /// `id` is what the agent's CLI takes; `key` the row's id while it's busy.
    func act(_ agent: String, _ action: String, _ id: String, key: String? = nil, name: String = "") {
        let key = key ?? id
        busy.v.insert(key)
        Task {
            await model.act {
                try await API.post("/api/customize/plugins/\(agent)", ["action": action, "id": id])
                let verb = ["install": "Installed", "uninstall": "Uninstalled", "remove": "Removed", "enable": "Turned on", "disable": "Turned off"][action] ?? "Done:"
                self.model.say("\(verb) \(name.isEmpty ? id.split(separator: "@").first.map(String.init) ?? id : name)")
            }
            busy.v.remove(key)
            await load(refresh: true)
        }
    }

    func confirmRemove(_ p: JSON, agent: String, action: String) {
        let who = ["claude": "Claude Code", "codex": "Codex", "devin": "Devin"][agent] ?? agent
        let a = NSAlert()
        a.messageText = "\(action == "uninstall" ? "Uninstall" : "Remove") \(p["name"].string)?"
        a.informativeText = "\(who) removes the plugin and what it adds: its skills, commands, hooks and MCP servers."
        a.addButton(withTitle: action == "uninstall" ? "Uninstall" : "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // Devin removes by name (`remove`); the id only keeps same-named installs apart in the list.
        act(agent, action, p["remove"].nonEmpty ?? p["id"].string, key: p["id"].string, name: p["name"].string)
    }
}

/// A plugin's square: its initial on a color from its name.
struct PluginIcon: View {
    let name: String
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Avatar.color(for: name).opacity(0.16))
            .overlay(Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 12)).foregroundStyle(Avatar.color(for: name)))
            .frame(width: 28, height: 28)
    }
}
