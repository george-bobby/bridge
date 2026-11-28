import AppKit
import SwiftUI

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clears the traffic lights and the sidebar/back/forward row.
            Color.clear.frame(height: Chrome.top + 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ActionRow(icon: "square.and.pencil", label: "New task", keys: "⌘N", on: model.route == .compose) { model.compose(in: model.projectFilter) }
                    ActionRow(icon: "magnifyingglass", label: "Search", keys: "⌘K") { model.paletteOpen = true }

                    SideLabel("Overview")
                    NavItem(icon: "house", label: "Home", route: .home)
                    NavItem(icon: "tray", label: "Inbox", route: .inbox, badge: model.decisions.count + model.todos.count, hot: !model.decisions.isEmpty)
                    NavItem(icon: "rectangle.stack", label: "Sessions", route: model.sessionsRoute, also: [.board, .sessions],
                            count: model.boardSessions.filter { model.inFilter($0) && model.column(of: $0) != .done }.count)

                    let sources = SourceKind.allCases.filter(model.sourceShown)
                    if !sources.isEmpty {
                        SideLabel("Sources")
                        ForEach(sources) { k in sourceItem(k).transition(.opacity) }
                    }

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
                        ActionRow(icon: "plus.rectangle.on.folder", label: "Add a project…", keys: "") { model.addProject() }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            NavItem(icon: "gearshape", label: "Settings", route: .settings)
                .padding(.horizontal, 10).padding(.top, 6)
            SidebarFooter()
        }
        .animation(M.snappy, value: model.route)
    }

    /// A source's row: what needs you as the badge, what's open as the count.
    @ViewBuilder func sourceItem(_ k: SourceKind) -> some View {
        switch k {
        case .slack:
            // Watched-channel posts nobody started count too: the Inbox no longer shows them.
            let posts = model.slackItems.filter { $0["kind"].string == "channel" && $0["verdict"].string != "skip" }.count
            NavItem(icon: k.icon, label: k.label, route: k.route, badge: model.slackUnread + posts, count: model.mentions.filter { model.session(forPermalink: $0.permalink) == nil }.count, hot: model.slackUnread + posts > 0)
        case .github:
            NavItem(icon: k.icon, label: k.label, route: k.route, count: model.openPulls.count, hot: model.openPulls.contains(where: \.needsAttention))
        case .linear:
            NavItem(icon: k.icon, label: k.label, route: k.route, count: model.issues.filter(\.active).count)
        case .vercel:
            let building = model.vercelDeployments.filter { $0["state"].string == "building" }.count
            let failed = model.vercelDeployments.prefix(10).contains { $0["state"].string == "failed" }
            NavItem(icon: k.icon, label: k.label, route: k.route, count: building, hot: failed)
        case .incidents:
            NavItem(icon: k.icon, label: k.label, route: k.route, badge: model.liveIncidents.count, hot: !model.liveIncidents.isEmpty)
        case .datadog:
            NavItem(icon: k.icon, label: k.label, route: k.route, badge: model.alertingMonitors.count, count: model.datadog["issues"].array.count, hot: !model.alertingMonitors.isEmpty)
        case .models:
            NavItem(icon: k.icon, label: k.label, route: k.route, count: model.models["providers"].array.reduce(0) { $0 + $1["models"].array.count }, hot: model.models["providers"].array.contains { $0["error"].nonEmpty != nil })
        case .granola:
            NavItem(icon: k.icon, label: k.label, route: k.route, count: model.granolaNotes.filter { Calendar.current.isDateInToday(Date(timeIntervalSince1970: Fmt.iso($0["createdAt"].string))) }.count)
        }
    }
}

struct ActionRow: View {
    let icon: String
    let label: String
    let keys: String
    var on = false
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
            .background(NavHighlight(on: on, hover: hover.v))
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
                Text(model.connected ? "\(model.sessions.filter(model.isLive).count) running" : "Offline").font(T.ui(11.5)).foregroundStyle(T.text3)
                    .contentTransition(.numericText())
                Spacer()
                IconButton(icon: "gauge.with.dots.needle.50percent", help: "Usage", on: model.route == .usage) { model.route = .usage }
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


/// One repo in the sidebar: its live sessions, and its orchestrator as the
/// sparkles button at the right end of the header. Drop a
/// session (from the sidebar or the Board) on the header to move it here.
struct ProjectSection: View {
    @Environment(AppModel.self) var model
    let project: Project
    static let dragPrefix = "bridge-project:"
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
                ProjectBadge(project: project)
                Text(project.name).font(T.ui(13.5, .medium)).foregroundStyle(model.projectFilter == project.id ? T.text : T.text2).lineLimit(1)
                Spacer(minLength: 4)
                if !sessions.isEmpty {
                    Text(verbatim: "\(sessions.count)").font(T.ui(11.5)).foregroundStyle(T.text3)
                }
                // New task, memory, archived chats and the rest are in the right-click menu.
                OrchestratorButton(project: project)
            }
            .padding(.leading, 10).padding(.trailing, 3)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(targeted.v ? T.accentSoft : hover.v ? T.sideHover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(targeted.v ? T.accent.opacity(0.6) : .clear, lineWidth: 1))
            .scaleEffect(targeted.v ? 1.02 : 1)
            .animation(M.pop, value: targeted.v)
            .contentShape(Rectangle())
            .hoverBox(hover)
            .onTapGesture { withAnimation(M.snappy) { toggle() } }
            // Drag a project header onto another to reorder the sidebar (Default stays first).
            .onDrag { NSItemProvider(object: (project.root ? "" : ProjectSection.dragPrefix + project.id) as NSString) }
            .contextMenu { ProjectMenu(project: project) }
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                if id.hasPrefix(ProjectSection.dragPrefix) {
                    let moved = String(id.dropFirst(ProjectSection.dragPrefix.count))
                    guard moved != project.id, !project.root, let to = model.projects.firstIndex(where: { $0.id == project.id }) else { return false }
                    Task { await model.moveProject(moved, to: to) }
                    return true
                }
                guard model.sessions.contains(where: { $0.id == id }) else { return false }
                Task { await model.setProject(id, project.id) }
                return true
            } isTargeted: { targeted.v = $0 }

            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(showAll.v ? sessions : Array(sessions.prefix(8))) { s in
                        SessionNavItem(session: s)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    if sessions.count > 8 && !showAll.v {
                        LinkButton("Show \(sessions.count - 8) more") { withAnimation(M.snappy) { showAll.v = true } }.padding(.leading, 34).frame(height: 24)
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

/// A project's orchestrator, at the right end of its sidebar header: purple
/// sparkles, a live spinner while it works, a dot for an unread reply.
struct OrchestratorButton: View {
    @Environment(AppModel.self) var model
    let project: Project
    @StateObject private var hover = Box(false)
    var body: some View {
        let id = model.orchestratorId(project.id)
        let on = model.route == .session(id)
        let s = model.sessions.first { $0.id == id }
        ZStack {
            if let s, model.isLive(s) { LiveIcon(size: 11) }
            else { Image(systemName: "sparkles").font(.system(size: 11.5, weight: .medium)).foregroundStyle(T.purple) }
        }
        .frame(width: B.small, height: B.small)
        .background(RoundedRectangle(cornerRadius: B.radius(B.small), style: .continuous).fill(on ? T.sideSelected : hover.v ? T.hover : .clear))
        .overlay(alignment: .topTrailing) {
            if let s, s.unread && !on && !model.isLive(s) { Circle().fill(T.accent).frame(width: 6, height: 6).offset(x: -2, y: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if s != nil && NSEvent.modifierFlags.contains(.option) { model.openToSide(id) } else { model.openOrchestrator(project.id) }
        }
        .hoverBox(hover)
        .help("\(project.name) orchestrator (⌥-click to open to the side)")
        .onDrag { NSItemProvider(object: (s == nil ? "" : id) as NSString) }
        .contextMenu {
            Button { model.openOrchestrator(project.id) } label: { Label("Open Orchestrator", systemImage: "sparkles") }
            if let s {
                Button { model.openToSide(id) } label: { Label("Open to the Side", systemImage: "rectangle.split.2x1") }
                Divider()
                Button(role: .destructive) { Task { await model.clearChat(id) } } label: { Label("Clear Chat…", systemImage: "eraser") }
                    .disabled(model.isLive(s))
            }
        }
    }
}

/// A project's right-click menu: everything its header doesn't show.
struct ProjectMenu: View {
    @Environment(AppModel.self) var model
    let project: Project
    var body: some View {
        Section {
            Button { model.compose(in: project.id) } label: { Label("New Task in \(project.name)…", systemImage: "square.and.pencil") }
            Button { model.openImport(into: project.id) } label: { Label("Import a Chat…", systemImage: "square.and.arrow.down.on.square") }
            Button { model.openOrchestrator(project.id) } label: { Label("Open Orchestrator", systemImage: "sparkles") }
        }
        Section {
            Button { model.openMemory(project.id) } label: { Label("Memory", systemImage: "book.closed") }
            let archived = model.archivedSessions.filter { $0.project == project.id }.count
            Button {
                withAnimation(M.snappy) {
                    model.projectFilter = project.id
                    model.showArchived = true
                    model.route = .sessions
                }
            } label: { Label(archived == 0 ? "Archived Chats" : "Archived Chats (\(archived))", systemImage: "archivebox") }
            .disabled(archived == 0)
            let only = model.projectFilter == project.id
            Button {
                model.projectFilter = only ? nil : project.id
                if model.route != .board && model.route != .sessions { model.navigate(.sessions) }
            } label: { Label(only ? "Show All Projects" : "Show Only \(project.name)", systemImage: only ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
        }
        if !project.root {
            Section {
                let i = model.projects.firstIndex(where: { $0.id == project.id }) ?? 0
                let first = model.projects.first?.root == true ? 1 : 0
                Button { Task { await model.moveProject(project.id, to: i - 1) } } label: { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(i <= first)
                Button { Task { await model.moveProject(project.id, to: i + 1) } } label: { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(i >= model.projects.count - 1)
            }
        }
        Section {
            Button { model.renameProject(project) } label: { Label("Rename…", systemImage: "pencil") }
            if project.root { Button { model.chooseRootFolder() } label: { Label("Change Folder…", systemImage: "folder.badge.gearshape") } }
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button { copyToPasteboard(project.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
        if !project.root {
            Section {
                Button(role: .destructive) { model.confirmRemoveProject(project) } label: { Label("Remove from Bridge…", systemImage: "trash") }
            }
        }
    }
}

/// A project's square: its initial on a color, or a house for Default.
struct ProjectBadge: View {
    let project: Project
    var size: CGFloat = 18
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(project.root ? T.text3.opacity(0.35) : Avatar.color(for: project.name))
            .overlay {
                if project.root { Image(systemName: "house.fill").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white) }
                else { Text(project.name.prefix(1).uppercased()).font(.system(size: size * 0.58, weight: .bold)).foregroundStyle(.white) }
            }
            .frame(width: size, height: size)
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
                if model.slack["configured"].bool { SlackWatchBar() } else {
                    IconButton(icon: "arrow.clockwise", help: "Refresh") { Task { await model.loadSlack() } }
                }
            }
            if !model.slack["configured"].bool {
                SlackSetup()
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if !model.slackItems.isEmpty { watched }
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

    /// What the Slack watch found that no session has picked up yet: start it or dismiss it.
    var watched: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "Not started", count: model.slackOpenCount)
            ForEach(model.slackItems, id: \.self) { SlackItemRow(item: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
            Spacer().frame(height: 10)
            GroupHeader(title: "Mentions", count: model.mentions.count)
        }
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
                                    MarkdownText(text: m["text"].string, size: 13, color: NT.text)
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

/// The watcher's state, and a way to poll now, in the Slack page's header.
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
        .padding(14)
        .opacity(skip ? 0.6 : 1)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.line, lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 10)
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
                Button { model.openThread(link) } label: { Label("Read", systemImage: "text.bubble") }.buttonStyle(LButton())
                Button { openURL(link) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(LButton(square: true)).help("Open in Slack")
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
