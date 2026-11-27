import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        Appearance.apply(model.appearance)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompts are code: `--flag` must not become an em dash, nor "x" curly quotes.
        for k in ["NSAutomaticDashSubstitutionEnabled", "NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticTextReplacementEnabled", "NSAutomaticPeriodSubstitutionEnabled"] {
            UserDefaults.standard.set(false, forKey: k)
        }
        if Bundle.main.bundlePath.hasSuffix(".app") { UNUserNotificationCenter.current().delegate = self }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.boot()
        if let dir = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_DIR"] { snapshots(to: dir) }
    }

    /// Dev aid: render every page of the window to PNGs, for checking the UI
    /// without screen-recording permission. `BRIDGE_SNAPSHOT_DIR=/tmp/x Bridge`.
    private func snapshots(to dir: String) {
        let routes: [(String, Route)] = [("home", .home), ("board", .board), ("sessions", .sessions), ("archived", .sessions), ("pulls", .pulls), ("linear", .linear), ("vercel", .vercel), ("incidents", .incidents), ("granola", .granola), ("datadog", .datadog), ("models", .models), ("inbox", .inbox), ("inbox-slack", .inbox), ("inbox-todos", .inbox), ("memory", .memory), ("slack", .slack), ("usage", .usage), ("settings", .settings), ("compose", .compose), ("settings-agents", .settings), ("settings-rules", .settings), ("settings-pipeline", .settings), ("settings-mcp", .settings), ("settings-skills", .settings), ("skill-edit", .settings), ("settings-plugins", .settings), ("settings-tokens", .settings), ("mcp-tools", .settings), ("mcp-add", .settings), ("settings-integrations", .settings), ("settings-projects", .settings), ("settings-notifications", .settings), ("settings-advanced", .settings)]
        let browser = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_URL"]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            var pages = routes
            let chat = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_CHAT"]
            if let s = model.sessions.first(where: { $0.id == chat }) ?? model.boardSessions.first(where: { $0.worked }) ?? model.orchestrator { pages.append(("chat", .session(s.id))) }
            pages.append(("palette", .board))
            pages.append(("import", .home))
            pages += [("archive-dialog", .sessions), ("archive-dirty", .sessions)]
            if let last = pages.first(where: { $0.0 == "chat" }) {
                pages.append(("collapsed", last.1))
                if browser != nil { pages.append(("browser", last.1)) }
                pages.append(("preview", last.1))
                pages += [("split", last.1), ("split-details", last.1), ("split-wide", last.1), ("split4", last.1), ("messages", last.1), ("messages-split", last.1), ("messages-list", last.1), ("drop", last.1), ("terminal", last.1), ("console", last.1), ("task", last.1), ("task-live", last.1), ("task-bash", last.1), ("pinned", last.1), ("pinned-collapsed", last.1)]
            }
            // The Changes tree in a worker's chat; Source Control in an orchestrator's.
            if let last = pages.first(where: { $0.0 == "chat" }) { pages.append(("changes", last.1)) }
            if let o = model.orchestrator { pages.append(("scm", .session(o.id))) }
            let hidden = model.sidebarHidden
            let pin = (model.pinnedRun, model.pinnedCollapsed)
            if let only = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_PAGES"]?.split(separator: ",").map(String.init) {
                pages = pages.filter { only.contains($0.0) }
            }
            for (name, route) in pages {
                model.paletteOpen = name == "palette"
                model.importOpen = name == "import"
                model.sidebarHidden = name == "collapsed"
                model.showArchived = name == "archived"
                if route == .inbox { model.inboxTab = name == "inbox-slack" ? "slack" : name == "inbox-todos" ? "todos" : "decisions" }
                if route == .settings { model.settingsPane = name.hasPrefix("settings-") ? String(name.dropFirst(9)) : "general" }
                if name == "browser", case .session(let id) = route, let browser { model.open(id); model.openBrowser(id, url: browser) }
                // A PR's preview deployment, opened the way a click on it does.
                if name == "preview", case .session(let id) = route, let s = model.sessions.first(where: { $0.id == id }), let p = model.previews(for: s).first {
                    model.openPreview(p.url, run: id); model.openPreview(p.url, run: id)   // twice: the second reuses the tab
                }
                if name.hasPrefix("split") || name.hasPrefix("messages"), case .session(let id) = route { model.panes = [Pane(run: id)]; model.focusedPane = 0 }
                // The orchestrator pinned beside a worker's chat, open and folded.
                if name.hasPrefix("pinned") { model.pinnedRun = model.orchestrator?.id ?? "orchestrator"; model.pinnedCollapsed = name == "pinned-collapsed" }
                if case .session(let id) = route { model.open(id) } else { model.route = route }
                if name == "split" { model.splitRight(); model.splitRight() }
                if name == "split4" { for _ in 0..<3 { model.splitRight() } }
                // Two sessions side by side, the first with its details drawer.
                if name == "split-details", case .session(let id) = route {
                    let order = model.chatOrder
                    if let i = order.firstIndex(of: id), i + 1 < order.count { model.openToSide(order[i + 1]) }
                    model.toggleDetails(model.panes[0].id)
                }
                // A wide pane with its details column, a minimized one, and a third.
                if name == "split-wide" {
                    model.splitRight(); model.splitRight()
                    model.panes[0].weight = 2
                    model.collapsePane(model.panes[1].id)
                    model.toggleDetails(model.panes[0].id)
                    model.focusPane(2)
                }
                // A drag in flight over the last pane's middle, to check the drop highlight.
                if name == "drop" { model.paneDragActive = true; model.dropZone = model.panes.last.map { DropZone(pane: $0.id, edge: model.isSplit ? .center : .trailing) } }
                else if model.paneDragActive { model.paneDragActive = false; model.dropZone = nil }
                if name == "terminal", case .session(let id) = route { model.openTerminalTab(id) }
                if name == "changes" || name == "scm", case .session(let id) = route { model.panes = [Pane(run: id)]; model.focusedPane = 0; model.open(id); model.showTab("changes", of: id) }
                // The VS Code-style panel under the chat, with two shells.
                if name == "console" {
                    if ConsoleStore.shared.shells.isEmpty { ConsoleStore.shared.add(model.contextFolder); ConsoleStore.shared.add(NSHomeDirectory()) }
                    ConsoleStore.shared.show()
                } else if ConsoleStore.shared.open { ConsoleStore.shared.hide(model) }
                // A finished subagent, a running one and a background command, each in its tab.
                if name.hasPrefix("task"), case .session(let id) = route {
                    let tasks = model.agentTasks(id)
                    let pick = name == "task-bash" ? tasks.first { !$0.isAgent } : name == "task-live" ? tasks.first { $0.isAgent && $0.running } : tasks.first { $0.isAgent && !$0.running }
                    if let t = pick { model.openTaskTab(id, t.id) }
                }
                if name == "slack", let m = model.mentions.first { model.openThread(m.permalink) }
                if name == "mcp-tools" || name == "mcp-add" { model.settingsPane = "mcp" }
                // Customize's tabs: settings-skills, settings-plugins, and a skill open in the editor.
                if route == .settings && name.hasPrefix("settings-") || name == "skill-edit" || name.hasPrefix("mcp-") {
                    model.customizeTab = name == "settings-skills" || name == "skill-edit" ? "skills" : name == "settings-plugins" ? "plugins" : "mcp"
                    if name == "settings-skills" || name == "settings-plugins" || name == "skill-edit" { model.settingsPane = "mcp" }
                    model.snapshotSkillEdit = name == "skill-edit"
                }
                model.mcpSheet = name == "mcp-add" ? .add(.claude) : nil
                // The archive dialog: a clean worktree (box on), then one with work that isn't pushed (box off, warning).
                if name.hasPrefix("archive-"), let s = model.sessions.first(where: { $0.id.contains(name == "archive-dirty" ? "web-131" : "web-124") }) { model.confirmArchive(s.id) } else { model.archiveAsk = nil }
                if name == "mcp-tools", let s = MCPStore.shared.servers(.claude).first(where: { $0.toolCount != nil }) { model.mcpSheet = .tools(s, run: nil) }
                var wait: UInt64 = 2_500_000_000
                // A long chat stepped back six prompts, caught mid-flash;
                // split: the long chat beside another, stepped in its pane.
                if name.hasPrefix("messages"), let long = model.sessions.first(where: { $0.id.contains("web-124") }) {
                    model.panes = [Pane(run: long.id)]; model.focusedPane = 0
                    model.open(long.id)
                    if name == "messages-split", case .session(let id) = route { model.openToSide(id); model.focusPane(0) }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    for _ in 0..<6 { model.messageNavs[long.id]?.step(-1); try? await Task.sleep(nanoseconds: 450_000_000) }
                    if name == "messages-list" { model.messageNavs[long.id]?.list.show() }
                    wait = 500_000_000
                }
                try? await Task.sleep(nanoseconds: wait)
                guard let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 800 })?.contentView,
                      let view = content.superview ?? Optional(content),
                      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
            model.sidebarHidden = hidden
            (model.pinnedRun, model.pinnedCollapsed) = pin
            // The sidebar's usage popover lives in its own window: render it directly.
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let card = ImageRenderer(content: UsageCard(providers: model.usageProviders) {}.background(T.raised).environment(\.colorScheme, dark ? .dark : .light))
            card.scale = 2
            var image: NSImage?
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { image = card.nsImage }
            if let img = image, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/usage-popover.png"))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["runId"] as? String ?? "", link = info["slack"] as? String ?? ""
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if !link.isEmpty { self.model.openThread(link) } else if !id.isEmpty { self.model.open(id) }
        }
        done()
    }
}

@main
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Bridge", id: "main") {
            RootView()
                .environment(delegate.model)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1480, height: 920)
        .commands { BridgeCommands(model: delegate.model); PaneCommands(model: delegate.model); ConsoleCommands(model: delegate.model) }

        MenuBarExtra(isInserted: .constant(MenuGlyph.shown)) {
            MenuBarPanel().environment(delegate.model)
        } label: {
            Image(nsImage: delegate.model.needsCount > 0 ? MenuGlyph.badged : MenuGlyph.plain)
        }
        .menuBarExtraStyle(.window)
    }
}

let navOrder: [(label: String, icon: String, route: Route)] = [
    ("Home", "house", .home),
    ("Inbox", "tray", .inbox),
    ("Sessions", "rectangle.stack", .sessions),
    ("Slack", "number", .slack),
    ("GitHub", "arrow.triangle.pull", .pulls),
    ("Linear", "circle.lefthalf.filled", .linear),
    ("Vercel", "triangle", .vercel),
    ("Incidents", "flame", .incidents),
    ("Granola", "note.text", .granola),
    ("Datadog", "waveform.path.ecg", .datadog),
    ("Models", "cpu", .models),
    ("Memory", "book.closed", .memory),
    ("Usage", "gauge.with.dots.needle.50percent", .usage),
]

struct BridgeCommands: Commands {
    let model: AppModel

    @MainActor func addSelection() {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = pb.string(forType: .string)
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        if pb.changeCount != before, let picked = pb.string(forType: .string), !picked.isEmpty {
            model.quoteIntoComposer(picked)
            if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
        } else {
            model.focusComposer += 1
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button { model.navigate(.settings) } label: { Label("Settings…", systemImage: "gearshape") }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button { model.compose(in: model.projectFilter) } label: { Label("New Task…", systemImage: "square.and.pencil") }.keyboardShortcut("n")
            Button {
                if case .session(let id) = model.route { model.openBrowser(id, url: "") }
            } label: { Label("New Browser Tab", systemImage: "globe") }
            .keyboardShortcut("t")
            Button { model.openImport() } label: { Label("Import Chat…", systemImage: "square.and.arrow.down.on.square") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button { addSelection() } label: { Label("Add Selection to Chat", systemImage: "text.quote") }.keyboardShortcut("l")
        }
        CommandGroup(before: .sidebar) {
            Button { model.toggleSidebar() } label: { Label("Toggle Sidebar", systemImage: "sidebar.left") }.keyboardShortcut("b")
            Button { model.toggleDetails() } label: { Label("Toggle Details", systemImage: "sidebar.right") }.keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Go") {
            Button { model.paletteOpen = true } label: { Label("Command Menu…", systemImage: "command") }.keyboardShortcut("k")
            Button { model.paletteOpen = true } label: { Label("Quick Open…", systemImage: "magnifyingglass") }.keyboardShortcut("p")
            Divider()
            // ⌘1…⌘9 for the first nine; the rest are in the menu and ⌘K.
            ForEach(Array(navOrder.prefix(9).enumerated()), id: \.offset) { i, item in
                Button { model.navigate(item.route) } label: { Label(item.label, systemImage: item.icon) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            ForEach(Array(navOrder.dropFirst(9).enumerated()), id: \.offset) { _, item in
                Button { model.navigate(item.route) } label: { Label(item.label, systemImage: item.icon) }
            }
            Divider()
            Button { model.back() } label: { Label("Back", systemImage: "chevron.left") }.keyboardShortcut("[")
            Button { model.forward() } label: { Label("Forward", systemImage: "chevron.right") }.keyboardShortcut("]")
            Button { model.stepChat(-1) } label: { Label("Previous Chat", systemImage: "chevron.up") }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button { model.stepChat(1) } label: { Label("Next Chat", systemImage: "chevron.down") }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button { model.openOrchestrator(model.projectFilter) } label: { Label("Orchestrator", systemImage: "sparkles") }.keyboardShortcut("o")
            Button { model.addProject() } label: { Label("Add Project…", systemImage: "folder.badge.plus") }
            Button { Task { await model.loadSources(refresh: true); await model.loadAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.keyboardShortcut("r")
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(AppModel.self) var model
    @Namespace private var nav

    var body: some View {
        HStack(spacing: 0) {
            if !model.sidebarHidden {
                Sidebar()
                    .frame(width: T.sidebarWidth)
                    .environment(\.navNS, nav)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Workbench {
                ZStack {
                    T.panel
                    detail
                        .id(model.pageId)
                        .transition(.page)
                }
                .animation(M.page, value: model.pageId)
            }
            .background(T.panel)
            // A page's own minimum width must never grow the window.
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.line.opacity(0.9), lineWidth: 1))
            .shadow(color: T.shade.opacity(0.25), radius: 6, y: 1)
            .padding(.vertical, T.panelInset)
            .padding(.trailing, T.panelInset)
            .padding(.leading, model.sidebarHidden ? T.panelInset : 0)
        }
        .onAppear { Keys.install(model) }
        .background(VisualEffect(material: .sidebar))
        .background(T.bg.opacity(0.55))
        .background(WindowChrome(center: Chrome.center(sidebarHidden: model.sidebarHidden)))
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 2).onEnded { if $0.location.y <= T.headerHeight + T.panelInset { titleBarDoubleClick() } })
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            HStack(spacing: 2) {
                IconButton(icon: "sidebar.left", help: model.sidebarHidden ? "Show sidebar (⌘B)" : "Hide sidebar (⌘B)") { model.toggleSidebar() }
                IconButton(icon: "chevron.left", help: "Back (⌘[)") { model.back() }
                    .disabled(model.backStack.isEmpty).opacity(model.backStack.isEmpty ? 0.35 : 1)
                IconButton(icon: "chevron.right", help: "Forward (⌘])") { model.forward() }
                    .disabled(model.forwardStack.isEmpty).opacity(model.forwardStack.isEmpty ? 0.35 : 1)
            }
            .frame(height: 28)
            .padding(.leading, Chrome.buttonsLeft).padding(.top, Chrome.center(sidebarHidden: model.sidebarHidden) - 14)
            .ignoresSafeArea()
        }
        .overlay {
            if model.paletteOpen || model.importOpen || model.mcpSheet != nil || model.archiveAsk != nil {
                T.shade.opacity(0.32).ignoresSafeArea()
                    .onTapGesture { model.paletteOpen = false; model.importOpen = false; model.mcpSheet = nil; model.archiveAsk = nil }
                    .transition(.opacity)
            }
        }
        .overlay { if model.paletteOpen { CommandPalette().transition(.panel) } }
        .overlay { if model.importOpen { ImportSheet().transition(.panel) } }
        .overlay { if let s = model.mcpSheet { MCPSheetHost(sheet: s).transition(.panel) } }
        .overlay { if let a = model.archiveAsk { ArchiveSheet(ask: a).padding(.top, 120).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).transition(.panel) } }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if !model.connected && !model.everConnected { ConnectingView().transition(.opacity) } }
        .animation(M.pop, value: model.paletteOpen)
        .animation(M.pop, value: model.importOpen)
        .animation(M.pop, value: model.mcpSheet)
        .animation(M.pop, value: model.archiveAsk?.id)
        .animation(M.page, value: model.everConnected)
    }

    @ViewBuilder var detail: some View {
        switch model.route {
        case .home: HomeView()
        case .inbox: InboxView()
        case .slack: SlackView()
        case .usage: UsageView()
        case .board: BoardView()
        case .sessions: SessionsView()
        case .pulls: PullsView()
        case .linear: LinearView()
        case .vercel: VercelView()
        case .incidents: IncidentsView()
        case .granola: GranolaView()
        case .datadog: DatadogView()
        case .models: ModelsView()
        case .memory: MemoryView()
        case .settings: SettingsView()
        case .compose: ComposeSheet()
        case .session(let id): DockedChat(id: id)
        }
    }
}

/// The hidden title bar leaves the header bars covering where AppKit would
/// catch a title-bar double-click, so honor the system setting ourselves.
@MainActor func titleBarDoubleClick() {
    guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "None": break
    case "Minimize": window.miniaturize(nil)
    default: window.zoom(nil)
    }
}

private struct NavNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var navNS: Namespace.ID? {
        get { self[NavNamespaceKey.self] }
        set { self[NavNamespaceKey.self] = newValue }
    }
}

struct NavHighlight: View {
    @Environment(\.navNS) private var ns
    let on: Bool
    let hover: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && !on ? T.sideHover : .clear)
            if on {
                if let ns {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.sideSelected).matchedGeometryEffect(id: "nav-selection", in: ns)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.sideSelected)
                }
            }
        }
    }
}

struct ConnectingView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        ZStack {
            T.bg
            VStack(spacing: 14) {
                Logo(size: 56).modifier(Breathe()).padding(.bottom, 4)
                Text("Starting Bridge…").font(T.ui(13, .medium)).foregroundStyle(T.text2)
                ProgressView().controlSize(.small)
                if !model.serverError.isEmpty {
                    Text(model.serverError).font(T.ui(12)).foregroundStyle(T.orange).multilineTextAlignment(.center).frame(maxWidth: 420).textSelection(.enabled)
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct Breathe: ViewModifier {
    @StateObject private var on = Box(false)
    func body(content: Content) -> some View {
        content
            .scaleEffect(on.v ? 1.03 : 0.97)
            .shadow(color: T.accent.opacity(on.v ? 0.5 : 0.18), radius: on.v ? 20 : 8, y: 4)
            .onAppear { if !on.v { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { on.v = true } } }
    }
}

/// The app icon's squircle and bridge mark (scripts/icon.swift draws the
/// same geometry into icon.png).
struct Logo: View {
    var size: CGFloat = 20
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        // Heavier strokes and no hangers at sidebar sizes, as the icon does at 16/32px.
        let small = size < 24
        ZStack {
            shape.fill(LinearGradient(colors: [.white, Color(red: 0.94, green: 0.94, blue: 0.97)],
                                      startPoint: UnitPoint(x: 0.15, y: 0), endPoint: UnitPoint(x: 0.85, y: 1)))
            BridgeMark(weight: small ? 1.35 : 1, hangers: !small)
                .scale(small ? 1.15 : 1, anchor: UnitPoint(x: 0.5, y: 0.55))
                .fill(LinearGradient(colors: [Color(red: 0.48, green: 0.51, blue: 0.94), T.accent, Color(red: 0.23, green: 0.17, blue: 0.61)], startPoint: .top, endPoint: .bottom))
        }
        .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: max(0.5, size * 0.012)))
        .frame(width: size, height: size)
    }
}

/// Arch, deck, piers and hangers in unit space across the icon body.
struct BridgeMark: Shape {
    var weight: CGFloat = 1
    var hangers = true
    func path(in r: CGRect) -> Path {
        let w = r.width
        func U(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * r.height) }
        let deckY: CGFloat = 0.615, archR: CGFloat = 0.255, stroke = 0.068 * weight * w
        var out = Path()
        func add(_ width: CGFloat, _ build: (inout Path) -> Void) {
            var p = Path(); build(&p)
            out.addPath(p.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)))
        }
        add(stroke) { $0.addArc(center: U(0.5, deckY), radius: archR * w, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false) }
        add(stroke) { $0.move(to: U(0.17, deckY)); $0.addLine(to: U(0.83, deckY)) }
        for x in [0.5 - archR, 0.5 + archR] { add(stroke) { $0.move(to: U(x, deckY)); $0.addLine(to: U(x, 0.76)) } }
        if hangers {
            for dx: CGFloat in [-0.125, 0, 0.125] {
                let top = deckY - (archR * archR - dx * dx).squareRoot()
                add(0.03 * weight * w) { $0.move(to: U(0.5 + dx, top)); $0.addLine(to: U(0.5 + dx, deckY)) }
            }
        }
        return out
    }
}

// MARK: - Sidebar

struct SideLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(T.ui(11.5, .semibold)).foregroundStyle(T.text3)
            .padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 6)
    }
}

struct NavItem: View {
    @Environment(AppModel.self) var model
    let icon: String
    let label: String
    let route: Route
    var also: [Route] = []
    var badge: Int = 0
    var count: Int = 0
    var hot = false
    @StateObject private var hover = Box(false)

    var body: some View {
        let on = model.route == route || also.contains(model.route)
        Button { model.route = route } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13.5, weight: .medium)).frame(width: 18)
                    .foregroundStyle(on ? T.accent : T.text2)
                    .symbolEffect(.bounce, value: on)
                Text(label).font(T.ui(13.5, on ? .medium : .regular)).foregroundStyle(on ? T.text : T.text2)
                Spacer()
                if badge > 0 {
                    Text(verbatim: "\(badge)").font(T.ui(10.5, .semibold)).foregroundStyle(.white).monospacedDigit()
                        .contentTransition(.numericText())
                        .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 16)
                        .background(Capsule().fill(hot ? T.orange : T.text3))
                        .transition(.scale.combined(with: .opacity))
                } else if count > 0 {
                    HStack(spacing: 4) {
                        if hot { Circle().fill(T.red).frame(width: 5, height: 5).transition(.scale) }
                        Text(verbatim: "\(count)").font(T.ui(11.5)).foregroundStyle(T.text3).monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
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

struct SessionNavItem: View {
    @Environment(AppModel.self) var model
    let session: Session
    @StateObject private var hover = Box(false)
    @StateObject private var card = HoverIntent(delay: 0.6)

    var body: some View {
        let on = model.route == .session(session.id)
        let pr = model.pr(for: session.prUrl)
        let twoLine = subtitle != nil || pr != nil || !session.prUrl.isEmpty
        HStack(alignment: twoLine ? .top : .center, spacing: 10) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isOrchestrator ? "Orchestrator" : session.title).font(T.ui(13, on ? .medium : .regular)).foregroundStyle(on ? T.text : T.text2).lineLimit(1)
                metaLine(pr)
            }
            Spacer(minLength: 4)
            marker(twoLine)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, twoLine ? 6 : 0)
        .frame(minHeight: 30)
        .background(NavHighlight(on: on, hover: hover.v))
        .contentShape(Rectangle())
        // A tap, not a Button: a Button tracks the mouse itself and a drag
        // never starts. ⌥-click opens the chat beside the focused pane.
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) { model.openToSide(session.id) } else { model.open(session.id) }
        }
        .hoverBox(hover)
        // A pointer that rests on a chat loads it, so the click opens it drawn.
        // The short wait skips rows the pointer only passes over.
        .task(id: hover.v) {
            guard hover.v else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            if !Task.isCancelled { model.prefetch(session.id) }
        }
        .onHover { inside in if pr != nil { card.hover(inside) } }
        .popover(isPresented: Binding(get: { card.open && pr != nil }, set: { if !$0 { card.hover(false) } }), arrowEdge: .trailing) {
            if let pr { SessionHoverCard(session: session, pr: pr) }
        }
        .onDrag { NSItemProvider(object: session.id as NSString) }
        .help("⌥-click or drag onto the chat to open side by side")
        .contextMenu { SessionMenu(session: session) }
    }

    @ViewBuilder var icon: some View {
        if session.isOrchestrator {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .medium)).foregroundStyle(T.purple)
        } else {
            SessionIcon(session: session)
        }
    }

    @ViewBuilder func marker(_ twoLine: Bool) -> some View {
        if model.isAwaiting(session) { PulseDot(color: T.orange).padding(.top, twoLine ? 6 : 0).transition(.scale.combined(with: .opacity)) }
        else if session.unread && model.route != .session(session.id) { Circle().fill(T.accent).frame(width: 6, height: 6).padding(.top, twoLine ? 6 : 0).transition(.scale.combined(with: .opacity)) }
    }

    /// Under the title: what the session wants or is doing, else its PR
    /// (state, number, CI) the way GitHub shows it.
    @ViewBuilder func metaLine(_ pr: PullRequest?) -> some View {
        if let meta = subtitle {
            Text(meta.0).font(T.ui(11.5)).foregroundStyle(meta.1).lineLimit(1).transition(.opacity)
        } else if let pr {
            PRMetaLine(pr: pr, run: session.id).transition(.opacity)
        } else if !session.prUrl.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 10, weight: .semibold))
                Text(verbatim: session.prNumber).font(T.ui(11.5)).monospacedDigit()
            }
            .foregroundStyle(T.text3)
        }
    }

    var subtitle: (String, Color)? {
        if model.isAwaiting(session) { return (session.askedFor.isEmpty ? "Waiting on you" : session.askedFor, T.orange) }
        if model.isLive(session) { return (session.statusLine.isEmpty ? "Working…" : session.statusLine, T.yellow.opacity(0.85)) }
        return nil
    }
}

/// "⇄ 12 Merged · ✓ passed" under a sidebar session, with the diff size
/// while the PR is open.
struct PRMetaLine: View {
    let pr: PullRequest
    var run: String? = nil
    var body: some View {
        // The diff size goes first when the row is tight: a row wider than
        // the sidebar would push the whole sidebar sideways.
        ViewThatFits(in: .horizontal) {
            line(diff: true)
            line(diff: false)
        }
    }

    func line(diff: Bool) -> some View {
        HStack(spacing: 5) {
            PRBadge(pr: pr)
            if ChecksBadge(pr: pr).look != nil {
                Text("·").font(T.ui(11.5)).foregroundStyle(T.text3)
                ChecksBadge(pr: pr)
            }
            if pr.open && pr.review == "APPROVED" {
                Text("·").font(T.ui(11.5)).foregroundStyle(T.text3)
                Text("approved").font(T.ui(11.5)).foregroundStyle(T.green)
            }
            if pr.open, let p = pr.preview {
                Text("·").font(T.ui(11.5)).foregroundStyle(T.text3)
                PreviewChip(preview: p, run: run, compact: true)
            }
            Spacer(minLength: 4)
            if diff && pr.open && pr.additions + pr.deletions > 0 {
                HStack(spacing: 4) {
                    Text(verbatim: "+\(pr.additions)").foregroundStyle(T.green)
                    Text(verbatim: "−\(pr.deletions)").foregroundStyle(T.red)
                }
                .font(T.ui(11)).monospacedDigit().fixedSize()
            }
        }
        .lineLimit(1)
    }
}

/// A session's status in Linear's vocabulary; live ones spin.
struct SessionIcon: View {
    @Environment(AppModel.self) var model
    let session: Session
    var size: CGFloat = 14

    var body: some View {
        let col = model.column(of: session)
        if model.isLive(session) && !model.isAwaiting(session) {
            LiveIcon(size: size)
        } else {
            StatusIcon(kind: col.status, size: size)
        }
    }
}

struct LiveIcon: View {
    var size: CGFloat = 14
    @StateObject private var spin = Box(false)
    var body: some View {
        ZStack {
            Circle().stroke(T.yellow.opacity(0.3), lineWidth: 1.5)
            Circle().trim(from: 0, to: 0.3).stroke(T.yellow, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(spin.v ? 360 : 0))
            Circle().fill(T.yellow).padding(size * 0.32)
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin.v = true } }
    }
}

struct PulseDot: View {
    let color: Color
    var size: CGFloat = 6
    @StateObject private var on = Box(false)
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(
                Circle().stroke(color, lineWidth: 1.5)
                    .scaleEffect(on.v ? 2.4 : 1)
                    .opacity(on.v ? 0 : 0.8)
            )
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on.v = true } }
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        Group {
            if let t = model.toast {
                HStack(spacing: 8) {
                    Image(systemName: model.toastBad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.toastBad ? T.red : T.green)
                    Text(t).font(T.ui(12.5)).foregroundStyle(T.text).lineLimit(2)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(T.line, lineWidth: 1))
                .shadow(color: T.shade.opacity(0.35), radius: 18, y: 6)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(M.pop, value: model.toast)
    }
}

// MARK: - Menu bar

struct MenuBarPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Logo(size: 16)
                Text("Bridge").font(T.ui(13, .semibold))
                Spacer()
                Text(verbatim: "\(model.liveCount) running").font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            .padding(12)
            Hairline()
            let needs = model.boardSessions.filter { model.column(of: $0) == .needs }
            let live = model.boardSessions.filter { model.isLive($0) }
            if needs.isEmpty && live.isEmpty {
                Text("Nothing running, nothing waiting.").font(T.ui(12)).foregroundStyle(T.text3).padding(12)
            }
            ForEach(needs + live.filter { s in !needs.contains(where: { $0.id == s.id }) }) { s in
                Button { show(s.id) } label: {
                    HStack(spacing: 8) {
                        SessionIcon(session: s)
                        Text(s.title).font(T.ui(12.5)).lineLimit(1)
                        Spacer()
                        Text(Fmt.ago(s.updatedAt)).font(T.ui(11)).foregroundStyle(T.text3)
                    }
                    .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Hairline()
            Button { show(nil) } label: {
                HStack { Text("Open Bridge").font(T.ui(12.5)); Spacer() }
                    .padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 320)
        .background(T.panel)
    }

    func show(_ id: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") ?? false }) { w.makeKeyAndOrderFront(nil) }
        else { openWindow(id: "main") }
        if let id { model.open(id) }
    }
}
