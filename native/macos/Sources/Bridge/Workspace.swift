import AppKit
import SwiftUI

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 34) // traffic lights
            HStack(spacing: 8) {
                Logo(size: 20)
                Text("Bridge").font(T.ui(13, .semibold)).foregroundStyle(T.text)
                Spacer()
                IconButton(icon: "magnifyingglass", help: "Command menu (⌘K)") { model.paletteOpen = true }
                IconButton(icon: "square.and.pencil", help: "New task (⌘N)") { model.compose(in: model.projectFilter) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    NavItem(icon: "house", label: "Home", route: .home)
                    NavItem(icon: "tray", label: "Inbox", route: .inbox, badge: model.decisions.count + model.todos.count, hot: !model.decisions.isEmpty)
                    NavItem(icon: "number", label: "Slack", route: .slack, count: model.mentions.filter { model.session(forPermalink: $0.permalink) == nil }.count)

                    SideLabel("Workspace")
                    NavItem(icon: "rectangle.split.3x1", label: "Board", route: .board, count: model.boardSessions.filter { model.inFilter($0) && model.column(of: $0) != .done }.count)
                    NavItem(icon: "bubble.left.and.text.bubble.right", label: "Sessions", route: .sessions)
                    NavItem(icon: "arrow.triangle.pull", label: "Pull requests", route: .pulls, count: model.openPulls.count, hot: model.openPulls.contains(where: \.needsAttention))
                    NavItem(icon: "circle.lefthalf.filled", label: "Linear", route: .linear, count: model.issues.filter(\.active).count)
                    NavItem(icon: "book.closed", label: "Memory", route: .memory)

                    let pinned = model.boardSessions.filter(\.pinned).sorted { $0.updatedAt > $1.updatedAt }
                    if !pinned.isEmpty {
                        SideLabel("Pinned")
                        ForEach(pinned) { s in SessionNavItem(session: s).draggable(s.id) }
                    }

                    HStack {
                        SideLabel("Projects")
                        Spacer()
                        IconButton(icon: "plus", help: "Add a project (a git checkout)") { model.addProject() }.padding(.top, 10)
                    }
                    ForEach(model.projects) { p in ProjectSection(project: p) }
                    if model.projects.isEmpty {
                        Button("Add a project…") { model.addProject() }.buttonStyle(.plain).font(T.ui(12.5)).foregroundStyle(T.text3).padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            Hairline()
            HStack(spacing: 8) {
                Circle().fill(model.connected ? T.green : T.red).frame(width: 7, height: 7)
                Text(model.connected ? "\(model.liveCount) running" : "Offline").font(T.ui(11.5)).foregroundStyle(T.text3)
                Text("·").foregroundStyle(T.text3)
                Text(Fmt.money(model.cost["today"].double) + " today").font(T.ui(11.5)).foregroundStyle(T.text3)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 12.5)).foregroundStyle(T.text2).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .background(T.bg)
    }
}

/// One repo in the sidebar: its orchestrator and its live sessions. Drop a
/// session (from the sidebar or the Board) on the header to move it here.
struct ProjectSection: View {
    @Environment(AppModel.self) var model
    let project: Project
    @AppStorage("sidebar.collapsed") private var collapsedRaw = ""
    @StateObject private var targeted = Box(false)
    @StateObject private var hover = Box(false)
    @StateObject private var showAll = Box(false)

    var collapsed: Bool { collapsedRaw.split(separator: ",").contains(Substring(project.id)) }

    var body: some View {
        let sessions = model.sessions(in: project.id).filter { !$0.pinned && model.column(of: $0) != .done }.sorted { $0.updatedAt > $1.updatedAt }
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text3).frame(width: 10)
                RoundedRectangle(cornerRadius: 4).fill(Avatar.color(for: project.name))
                    .overlay(Text(project.name.prefix(1).uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white))
                    .frame(width: 16, height: 16)
                Text(project.name).font(T.ui(12.5, .medium)).foregroundStyle(model.projectFilter == project.id ? T.text : T.text2).lineLimit(1)
                if project.id == model.defaultProject?.id { Text("default").font(T.ui(10.5)).foregroundStyle(T.text3) }
                Spacer(minLength: 4)
                if hover.v {
                    Button { model.compose(in: project.id) } label: { Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(T.text2) }
                        .buttonStyle(.plain).help("New task in \(project.name)")
                } else if !sessions.isEmpty {
                    Text(verbatim: "\(sessions.count)").font(T.ui(11.5)).foregroundStyle(T.text3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(targeted.v ? T.accentSoft : hover.v ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(targeted.v ? T.accent.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hover.v = $0 }
            .onTapGesture { toggle() }
            .contextMenu { ProjectMenu(project: project) }
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, model.sessions.contains(where: { $0.id == id }) else { return false }
                Task { await model.setProject(id, project.id) }
                return true
            } isTargeted: { targeted.v = $0 }

            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    OrchestratorNavItem(project: project)
                    ForEach(showAll.v ? sessions : Array(sessions.prefix(8))) { s in SessionNavItem(session: s).draggable(s.id) }
                    if sessions.count > 8 && !showAll.v {
                        Button("Show \(sessions.count - 8) more") { showAll.v = true }.buttonStyle(.plain).font(T.ui(12)).foregroundStyle(T.text3).padding(.leading, 34).frame(height: 24)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    func toggle() {
        var set = Set(collapsedRaw.split(separator: ",").map(String.init))
        if set.contains(project.id) { set.remove(project.id) } else { set.insert(project.id) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }
}

struct OrchestratorNavItem: View {
    @Environment(AppModel.self) var model
    let project: Project
    @StateObject private var hover = Box(false)
    var body: some View {
        let id = model.orchestratorId(project.id)
        let on = model.route == .session(id)
        let s = model.sessions.first { $0.id == id }
        Button { model.openOrchestrator(project.id) } label: {
            HStack(spacing: 9) {
                Image(systemName: "sparkles").font(.system(size: 11.5, weight: .medium)).foregroundStyle(T.purple).frame(width: 16)
                Text("Orchestrator").font(T.ui(12.5)).foregroundStyle(on ? T.text : T.text2)
                Spacer()
                if let s, model.isLive(s) { LiveIcon(size: 11) }
                else if let s, s.unread && !on { Circle().fill(T.accent).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 8).frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? T.selected : hover.v ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.v = $0 }
    }
}

struct ProjectMenu: View {
    @Environment(AppModel.self) var model
    let project: Project
    var body: some View {
        Button("New Task in \(project.name)…") { model.compose(in: project.id) }
        Button("Open Orchestrator") { model.openOrchestrator(project.id) }
        Button(model.projectFilter == project.id ? "Show All Projects" : "Show Only \(project.name)") {
            model.projectFilter = model.projectFilter == project.id ? nil : project.id
            if model.route != .board { model.route = .sessions }
        }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
        Button("Copy Path") { copyToPasteboard(project.path) }
        if project.id != model.defaultProject?.id {
            Button("Make Default") { Task { await model.updateProject(project.id, ["makeDefault": true]) } }
        }
        Button("Rename…") {
            let a = NSAlert()
            a.messageText = "Rename \(project.name)"
            let f = NSTextField(string: project.name)
            f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            a.accessoryView = f
            a.addButton(withTitle: "Rename")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { Task { await model.updateProject(project.id, ["name": f.stringValue]) } }
        }
        Divider()
        Button("Remove from Bridge", role: .destructive) { Task { await model.removeProject(project.id) } }
            .disabled(model.projects.count <= 1)
    }
}

/// The project scope of the Board and Sessions, in their header.
struct ProjectFilterMenu: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if model.projects.count > 1 {
            Menu {
                Button("All projects") { model.projectFilter = nil }
                Divider()
                ForEach(model.projects) { p in Button(p.name) { model.projectFilter = p.id } }
            } label: {
                ComposerChip(icon: "folder", text: model.projectFilter.flatMap { model.project($0)?.name } ?? "All projects")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

struct ProjectChip: View {
    @Environment(AppModel.self) var model
    let session: Session
    var body: some View {
        if model.projects.count > 1, model.projectFilter == nil, let p = model.project(session.project) {
            Text(p.name).font(T.ui(10.5, .medium)).foregroundStyle(T.text3)
        }
    }
}

// MARK: - Slack

struct SlackView: View {
    @Environment(AppModel.self) var model
    @StateObject private var reply = Box("")
    @StateObject private var sending = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Slack", subtitle: model.slack["configured"].bool ? "\(model.slack["team"].string) · mentions of @\(model.slack["user"].string)" : "", icon: "number") {
                IconButton(icon: "arrow.clockwise", help: "Refresh") { Task { await model.loadSlack() } }
            }
            if !model.slack["configured"].bool {
                SlackSetup()
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if model.mentions.isEmpty { EmptyState(icon: "at", title: "No mentions", detail: "Messages that mention you show up here.") }
                            ForEach(model.mentions) { m in MentionRow(mention: m, selected: model.slackSelected == m.permalink) }
                        }
                    }
                    .frame(width: 420)
                    Rectangle().fill(T.line).frame(width: 1)
                    thread
                }
            }
        }
        .onAppear { Task { await model.loadSlack() } }
    }

    @ViewBuilder var thread: some View {
        if model.slackSelected.isEmpty {
            EmptyState(icon: "bubble.left.and.bubble.right", title: "Pick a thread", detail: "Read it here, reply as yourself, or hand it to Claude.")
        } else if model.slackThread.isNull {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(model.slackThread["channel"].string).font(T.ui(13, .medium))
                    Text(verbatim: "\(model.slackThread["messages"].array.count) messages").font(T.ui(12)).foregroundStyle(T.text3)
                    Spacer()
                    Button { openURL(model.slackSelected) } label: { Label("Open in Slack", systemImage: "arrow.up.right") }.buttonStyle(LButton())
                    if let s = model.session(forPermalink: model.slackSelected) {
                        Button { model.open(s.id) } label: { Label("Open session", systemImage: "bubble.left") }.buttonStyle(LButton())
                    } else {
                        Menu {
                            ForEach(model.projects) { p in Button(p.name) { Task { await model.runPipeline(model.slackSelected, project: p.id) } } }
                        } label: { Label("Hand to Claude", systemImage: "sparkles") } primaryAction: {
                            Task { await model.runPipeline(model.slackSelected, project: model.projectFilter) }
                        }
                        .menuStyle(.button).buttonStyle(LButton(primary: true)).fixedSize()
                    }
                }
                .padding(.horizontal, 16).frame(height: 48)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(model.slackThread["messages"].array.enumerated()), id: \.offset) { _, m in
                            HStack(alignment: .top, spacing: 10) {
                                Avatar(name: m["who"].string, url: m["avatar"].string, size: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 7) {
                                        Text(m["who"].string).font(T.ui(13, .semibold))
                                        Text(Fmt.clock(m["ts"].double)).font(T.ui(11.5)).foregroundStyle(T.text3)
                                    }
                                    MarkdownText(text: m["text"].string, size: 13, color: T.text)
                                    ForEach(m["files"].array, id: \.self) { f in Chip(text: f.string, icon: "paperclip") }
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                HStack(spacing: 8) {
                    LField(placeholder: "Reply in the thread as @\(model.slack["user"].string)…", text: $reply.v) { send() }
                    Button("Reply") { send() }.buttonStyle(LButton(primary: true)).disabled(reply.v.trimmingCharacters(in: .whitespaces).isEmpty || sending.v)
                }
                .padding(12)
                .overlay(alignment: .top) { Hairline() }
            }
        }
    }

    func send() {
        let t = reply.v
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sending.v = true
        Task {
            if await model.replyInThread(t) { reply.v = "" }
            sending.v = false
        }
    }
}

struct MentionRow: View {
    @Environment(AppModel.self) var model
    let mention: Mention
    let selected: Bool

    var body: some View {
        HoverRow(selected: selected, height: 64) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: mention.who, url: mention.avatar, size: 24).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mention.who).font(T.ui(12.5, .semibold)).foregroundStyle(T.text)
                        Text(mention.channel).font(T.ui(11.5)).foregroundStyle(T.text3)
                        Spacer()
                        if let s = model.session(forPermalink: mention.permalink) { SessionIcon(session: s, size: 12) }
                        Text(Fmt.ago(mention.ts)).font(T.ui(11)).foregroundStyle(T.text3)
                    }
                    Text(mention.text).font(T.ui(12.5)).foregroundStyle(T.text2).lineLimit(2)
                }
            }
            .padding(.vertical, 8)
        }
        .onTapGesture { model.openThread(mention.permalink) }
    }
}

struct SlackSetup: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "number").font(.system(size: 26, weight: .light)).foregroundStyle(T.text3)
            Text("Connect Slack").font(T.ui(16, .semibold))
            Text("Bridge reads Slack as you, with a user token: no bot to invite and nothing to add to any channel. Create a small Slack app from the manifest once, install it to yourself, and paste its User OAuth Token (xoxp-…) into Settings → Environment → SLACK_USER_TOKEN.")
                .font(T.ui(13)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { openURL("https://api.slack.com/apps?new_app=1") } label: { Label("Create the app", systemImage: "arrow.up.right") }.buttonStyle(LButton(primary: true))
                Button { openURL("https://github.com/george-bobby/bridge/blob/main/docs/slack.md") } label: { Label("Step-by-step guide", systemImage: "book") }.buttonStyle(LButton())
                SettingsLink { Text("Open Settings") }.buttonStyle(LButton())
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings: environment

struct EnvironmentSettings: View {
    @Environment(AppModel.self) var model
    @StateObject private var entries = Box([JSON]())
    @StateObject private var edits = Box([String: String]())
    @StateObject private var file = Box("")

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(sections, id: \.self) { section in
                    Section(section) {
                        ForEach(entries.v.filter { $0["section"].string == section }, id: \.self) { e in row(e) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text(file.v).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Discard") { edits.v = [:] }.disabled(edits.v.isEmpty)
                Button("Save") { Task { if await model.saveEnv(edits.v, restart: false) { edits.v = [:]; load() } } }.disabled(edits.v.isEmpty)
                Button("Save and Restart Server") { Task { if await model.saveEnv(edits.v, restart: true) { edits.v = [:]; load() } } }
                    .keyboardShortcut(.defaultAction).disabled(edits.v.isEmpty)
            }
            .padding(12)
        }
        .onAppear(perform: load)
    }

    var sections: [String] {
        var seen: [String] = []
        for e in entries.v where !seen.contains(e["section"].string) { seen.append(e["section"].string) }
        return seen
    }

    func load() {
        Task {
            let out = (try? await API.get("/api/env")) ?? .null
            entries.v = out["entries"].array
            file.v = out["file"].string
        }
    }

    @ViewBuilder func row(_ e: JSON) -> some View {
        let key = e["key"].string
        let binding = Binding(get: { edits.v[key] ?? e["value"].string }, set: { edits.v[key] = $0 })
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent {
                if e["secret"].bool {
                    SecureField(e["set"].bool ? "•••••••• (set; type to replace)" : "not set", text: Binding(get: { edits.v[key] ?? "" }, set: { edits.v[key] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 300)
                } else {
                    TextField(e["example"].string, text: binding).textFieldStyle(.roundedBorder).frame(width: 300)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(key).font(.system(size: 12, design: .monospaced))
                    if edits.v[key] != nil { Circle().fill(T.accent).frame(width: 6, height: 6) }
                }
            }
            if !e["hint"].string.isEmpty { Text(e["hint"].string).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Settings: develop Bridge with Bridge

struct DevelopSettings: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let root = model.bridgeRoot
        let bridgeProject = model.projects.first { $0.path == root }
        Form {
            Section("Bridge's own source") {
                LabeledContent("Repository", value: root.isEmpty ? "unknown" : root)
                Text("Bridge can work on itself: add its repo as a project, then start sessions on it like any other repo. When a change lands, rebuild the app from here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let p = bridgeProject {
                        Button("New Task on Bridge…") { bringMainWindow(); model.compose(in: p.id) }
                        Button("Open Bridge's Orchestrator") { bringMainWindow(); model.openOrchestrator(p.id) }
                    } else {
                        Button("Add Bridge as a Project") { Task { await model.addProject(path: root, name: "bridge") } }.disabled(root.isEmpty)
                    }
                    Button("Reveal in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: root)) }.disabled(root.isEmpty)
                }
            }
            Section("Apply changes") {
                HStack {
                    Button(model.building ? "Building…" : "Rebuild and Relaunch App") { model.rebuildApp() }.disabled(model.building || root.isEmpty)
                    Button("Restart Server") { Task { await model.restartServer() } }
                    if model.building { ProgressView().controlSize(.small) }
                }
                Text("Rebuild compiles native/macos, swaps the app in ~/Applications and reopens it. Restart Server reloads lib/, .env and the skill templates. Running workers are restarted with the server.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.buildLog.isEmpty {
                    Text(model.buildLog).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    func bringMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false }?.makeKeyAndOrderFront(nil)
    }
}
