import AppKit
import SwiftUI

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clears the traffic lights and the sidebar/back/forward row, so the
            // first item starts just under the page header's bottom edge.
            Color.clear.frame(height: T.panelInset + T.headerHeight - 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ActionRow(icon: "square.and.pencil", label: "New task", keys: "⌘N") { model.compose(in: model.projectFilter) }
                    ActionRow(icon: "magnifyingglass", label: "Search", keys: "⌘K") { model.paletteOpen = true }

                    SideLabel("Overview")
                    NavItem(icon: "house", label: "Home", route: .home)
                    NavItem(icon: "tray", label: "Inbox", route: .inbox, badge: model.decisions.count + model.todos.count, hot: !model.decisions.isEmpty)
                    NavItem(icon: "rectangle.stack", label: "Sessions", route: model.sessionsRoute, also: [.board, .sessions],
                            count: model.boardSessions.filter { model.inFilter($0) && model.column(of: $0) != .done }.count)

                    SideLabel("Sources")
                    NavItem(icon: "number", label: "Slack", route: .slack, count: model.mentions.filter { model.session(forPermalink: $0.permalink) == nil }.count)
                    NavItem(icon: "arrow.triangle.pull", label: "GitHub", route: .pulls, count: model.openPulls.count, hot: model.openPulls.contains(where: \.needsAttention))
                    NavItem(icon: "circle.lefthalf.filled", label: "Linear", route: .linear, count: model.issues.filter(\.active).count)

                    let pinned = model.boardSessions.filter(\.pinned).sorted { $0.updatedAt > $1.updatedAt }
                    if !pinned.isEmpty {
                        SideLabel("Pinned")
                        ForEach(pinned) { s in
                            SessionNavItem(session: s)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }

                    HStack(spacing: 0) {
                        SideLabel("Projects")
                        Spacer()
                        IconButton(icon: "plus", help: "Add a project (a git checkout)") { model.addProject() }.padding(.top, 12)
                    }
                    ForEach(model.projects) { p in ProjectSection(project: p) }
                    if model.projects.isEmpty {
                        ActionRow(icon: "plus.rectangle.on.folder", label: "Add a project…", keys: "⇧⌘P") { model.addProject() }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            SidebarFooter()
        }
        .animation(M.snappy, value: model.route)
    }
}

struct ActionRow: View {
    let icon: String
    let label: String
    let keys: String
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13.5, weight: .medium)).foregroundStyle(T.text2).frame(width: 18)
                Text(label).font(T.ui(13.5)).foregroundStyle(T.text2)
                Spacer()
                Text(keys).font(T.ui(11.5)).foregroundStyle(T.text3).opacity(hover.v ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(NavHighlight(on: false, hover: hover.v))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
        .hoverBox(hover)
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) var model
    @StateObject private var usageOpen = Box(false)

    var body: some View {
        VStack(spacing: 6) {
            let providers = model.usageProviders.filter { $0.ok && $0.tightest != nil }
            if !providers.isEmpty { usageButton(providers) }
            HStack(spacing: 6) {
                Circle().fill(model.connected ? T.green : T.red).frame(width: 7, height: 7)
                    .shadow(color: (model.connected ? T.green : T.red).opacity(0.6), radius: 3)
                Text(model.connected ? "\(model.liveCount) running" : "Offline").font(T.ui(11.5)).foregroundStyle(T.text3)
                    .contentTransition(.numericText())
                Spacer()
                FooterButton(icon: "book.closed", help: "Memory (⌘7)", on: model.route == .memory) { model.route = .memory }
                FooterButton(icon: "gauge.with.dots.needle.50percent", help: "Usage (⌘8)", on: model.route == .usage, fill: false) { model.route = .usage }
                FooterButton(icon: "gearshape", help: "Settings (⌘,)", on: model.route == .settings) { model.navigate(.settings) }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    func usageButton(_ providers: [UsageProvider]) -> some View {
        Button { usageOpen.v.toggle() } label: {
            HStack(spacing: 10) {
                ForEach(providers) { p in
                    if let w = p.tightest { UsageGauge(provider: p, window: w) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(usageOpen.v || model.route == .usage ? T.sideSelected : T.sideHover))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
        .help("Plan usage")
        .popover(isPresented: $usageOpen.v, arrowEdge: .trailing) {
            UsageCard(providers: model.usageProviders) { usageOpen.v = false; model.route = .usage }
        }
    }
}

/// "Open Settings" at a given section, for setup screens elsewhere.
struct OpenSettingsButton: View {
    @Environment(AppModel.self) var model
    var pane = "general"
    var label = "Open Settings"
    var body: some View {
        Button { model.settingsPane = pane; model.navigate(.settings) } label: { Text(label) }.buttonStyle(LButton())
    }
}

struct FooterButton: View {
    let icon: String
    let help: String
    let on: Bool
    var fill = true
    let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            Image(systemName: on && fill ? icon + ".fill" : icon).font(.system(size: 13)).foregroundStyle(on ? T.accent : hover.v ? T.text : T.text2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? T.sideSelected : hover.v ? T.sideHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.9))
        .help(help)
        .hoverBox(hover)
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
        let sessions = model.sidebarSessions(in: project.id)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text3).frame(width: 10)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Avatar.color(for: project.name))
                    .overlay(Text(project.name.prefix(1).uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white))
                    .frame(width: 18, height: 18)
                Text(project.name).font(T.ui(13.5, .medium)).foregroundStyle(model.projectFilter == project.id ? T.text : T.text2).lineLimit(1)
                if project.id == model.defaultProject?.id { Text("default").font(T.ui(10.5)).foregroundStyle(T.text3) }
                Spacer(minLength: 4)
                if hover.v {
                    Button { model.compose(in: project.id) } label: { Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(T.text2) }
                        .buttonStyle(.plain).help("New task in \(project.name)")
                } else if !sessions.isEmpty {
                    Text(verbatim: "\(sessions.count)").font(T.ui(11.5)).foregroundStyle(T.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(targeted.v ? T.accentSoft : hover.v ? T.sideHover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(targeted.v ? T.accent.opacity(0.6) : .clear, lineWidth: 1))
            .scaleEffect(targeted.v ? 1.02 : 1)
            .animation(M.pop, value: targeted.v)
            .contentShape(Rectangle())
            .hoverBox(hover)
            .onTapGesture { withAnimation(M.snappy) { toggle() } }
            .contextMenu { ProjectMenu(project: project) }
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, model.sessions.contains(where: { $0.id == id }) else { return false }
                Task { await model.setProject(id, project.id) }
                return true
            } isTargeted: { targeted.v = $0 }

            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    OrchestratorNavItem(project: project)
                    ForEach(showAll.v ? sessions : Array(sessions.prefix(8))) { s in
                        SessionNavItem(session: s)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    if sessions.count > 8 && !showAll.v {
                        Button("Show \(sessions.count - 8) more") { withAnimation(M.snappy) { showAll.v = true } }.buttonStyle(.plain).font(T.ui(12)).foregroundStyle(T.text3).padding(.leading, 34).frame(height: 24)
                    }
                }
                .padding(.leading, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
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
        HStack(spacing: 9) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .medium)).foregroundStyle(T.purple).frame(width: 18)
            Text("Orchestrator").font(T.ui(13, on ? .medium : .regular)).foregroundStyle(on ? T.text : T.text2)
            Spacer()
            if let s, model.isLive(s) { LiveIcon(size: 11) }
            else if let s, s.unread && !on { Circle().fill(T.accent).frame(width: 6, height: 6) }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(NavHighlight(on: on, hover: hover.v))
        .contentShape(Rectangle())
        .onTapGesture {
            if s != nil && NSEvent.modifierFlags.contains(.option) { model.openToSide(id) } else { model.openOrchestrator(project.id) }
        }
        .hoverBox(hover)
        .onDrag { NSItemProvider(object: (s == nil ? "" : id) as NSString) }
    }
}

struct ProjectMenu: View {
    @Environment(AppModel.self) var model
    let project: Project
    var body: some View {
        Section {
            Button { model.compose(in: project.id) } label: { Label("New Task in \(project.name)…", systemImage: "square.and.pencil") }
            Button { model.openOrchestrator(project.id) } label: { Label("Open Orchestrator", systemImage: "sparkles") }
        }
        Section {
            let only = model.projectFilter == project.id
            Button {
                model.projectFilter = only ? nil : project.id
                if model.route != .board && model.route != .sessions { model.navigate(.sessions) }
            } label: { Label(only ? "Show All Projects" : "Show Only \(project.name)", systemImage: only ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
            Button { model.projectFilter = project.id; model.navigate(.sessions) } label: { Label("View Sessions", systemImage: "rectangle.stack") }
        }
        Section {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button { copyToPasteboard(project.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
        Section {
            if project.id != model.defaultProject?.id {
                Button { Task { await model.updateProject(project.id, ["makeDefault": true]) } } label: { Label("Make Default", systemImage: "star") }
            }
            Button {
                let a = NSAlert()
                a.messageText = "Rename \(project.name)"
                let f = NSTextField(string: project.name)
                f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
                a.accessoryView = f
                a.addButton(withTitle: "Rename")
                a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { Task { await model.updateProject(project.id, ["name": f.stringValue]) } }
            } label: { Label("Rename…", systemImage: "pencil") }
        }
        Section {
            Button(role: .destructive) { Task { await model.removeProject(project.id) } } label: { Label("Remove from Bridge", systemImage: "trash") }
                .disabled(model.projects.count <= 1)
        }
    }
}

/// The project scope of the Board and Sessions, in their header.
struct ProjectFilterMenu: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if model.projects.count > 1 {
            Menu {
                Button { model.projectFilter = nil } label: { Label("All Projects", systemImage: model.projectFilter == nil ? "checkmark" : "square.stack.3d.up") }
                Divider()
                ForEach(model.projects) { p in
                    Button { model.projectFilter = p.id } label: { Label(p.name, systemImage: model.projectFilter == p.id ? "checkmark" : "folder") }
                }
            } label: {
                HeaderPill(icon: "folder", text: model.projectFilter.flatMap { model.project($0)?.name } ?? "All projects", active: model.projectFilter != nil, chevron: true)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
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
            Text("Bridge reads Slack as you, with a user token: no bot to invite and nothing to add to any channel. Create a small Slack app from the manifest once, install it to yourself, and paste its User OAuth Token (xoxp-…) into Settings → Integrations → Slack.")
                .font(T.ui(13)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { openURL("https://api.slack.com/apps?new_app=1") } label: { Label("Create the app", systemImage: "arrow.up.right") }.buttonStyle(LButton(primary: true))
                Button { openURL("https://github.com/george-bobby/bridge/blob/main/docs/slack.md") } label: { Label("Step-by-step guide", systemImage: "book") }.buttonStyle(LButton())
                OpenSettingsButton(pane: "integrations")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
