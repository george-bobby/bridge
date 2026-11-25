import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundlePath.hasSuffix(".app") { UNUserNotificationCenter.current().delegate = self }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.boot()
        if let dir = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_DIR"] { snapshots(to: dir) }
    }

    /// Dev aid: render every page of the window to PNGs, for checking the UI
    /// without screen-recording permission. `BRIDGE_SNAPSHOT_DIR=/tmp/x Bridge`.
    private func snapshots(to dir: String) {
        let routes: [(String, Route)] = [("home", .home), ("board", .board), ("sessions", .sessions), ("pulls", .pulls), ("linear", .linear), ("inbox", .inbox), ("memory", .memory), ("slack", .slack), ("usage", .usage)]
        let browser = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_URL"]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            var pages = routes
            let chat = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_CHAT"]
            if let s = model.sessions.first(where: { $0.id == chat }) ?? model.boardSessions.first(where: { $0.worked }) ?? model.orchestrator { pages.append(("chat", .session(s.id))) }
            pages.append(("palette", .board))
            if let last = pages.first(where: { $0.0 == "chat" }) {
                pages.append(("collapsed", last.1))
                if browser != nil { pages.append(("browser", last.1)) }
            }
            let hidden = model.sidebarHidden
            if let only = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_PAGES"]?.split(separator: ",").map(String.init) {
                pages = pages.filter { only.contains($0.0) }
            }
            for (name, route) in pages {
                model.paletteOpen = name == "palette"
                model.sidebarHidden = name == "collapsed"
                if name == "browser", case .session(let id) = route, let browser { model.open(id); model.openBrowser(id, url: browser) }
                if case .session(let id) = route { model.open(id) } else { model.route = route }
                if name == "slack", let m = model.mentions.first { model.openThread(m.permalink) }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 800 })?.contentView,
                      let view = content.superview ?? Optional(content),
                      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
            model.sidebarHidden = hidden
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["runId"] as? String ?? ""
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if !id.isEmpty { self.model.open(id) }
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
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1480, height: 920)
        .commands { BridgeCommands(model: delegate.model) }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra {
            MenuBarPanel().environment(delegate.model).preferredColorScheme(.dark)
        } label: {
            Image(systemName: delegate.model.needsCount > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid")
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
        CommandGroup(replacing: .newItem) {
            Button("New Task…") { model.compose(in: model.projectFilter) }.keyboardShortcut("n")
            Button("New Browser Tab") {
                if case .session(let id) = model.route { model.openBrowser(id, url: "") }
            }
            .keyboardShortcut("t")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Add Selection to Chat") { addSelection() }.keyboardShortcut("l")
        }
        CommandGroup(before: .sidebar) {
            Button("Toggle Sidebar") { model.toggleSidebar() }.keyboardShortcut("s", modifiers: [.command, .control])
            Button("Toggle Details") { withAnimation(M.snappy) { model.inspectorShown.toggle() } }.keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Go") {
            Button("Command Menu…") { model.paletteOpen = true }.keyboardShortcut("k")
            Divider()
            ForEach(Array(navOrder.enumerated()), id: \.offset) { i, item in
                Button(item.label) { model.navigate(item.route) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
            Button("Back") { model.back() }.keyboardShortcut("[")
            Button("Forward") { model.forward() }.keyboardShortcut("]")
            Button("Previous Chat") { model.stepChat(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Chat") { model.stepChat(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Orchestrator") { model.openOrchestrator(model.projectFilter) }.keyboardShortcut("o")
            Button("Add Project…") { model.addProject() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Refresh") { Task { await model.loadSources(refresh: true); await model.loadAll() } }.keyboardShortcut("r")
            Divider()
            Button("Open Legacy Web UI") { openURL(API.base.absoluteString) }
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
            ZStack {
                T.panel
                detail
                    .id(model.route)
                    .transition(.page)
            }
            .animation(M.page, value: model.route)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.line.opacity(0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
            .padding(.vertical, T.panelInset)
            .padding(.trailing, T.panelInset)
            .padding(.leading, model.sidebarHidden ? T.panelInset : 0)
        }
        .background(VisualEffect(material: .sidebar))
        .background(T.bg.opacity(0.55))
        .background(WindowChrome())
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 2).onEnded { if $0.location.y <= T.headerHeight + T.panelInset { titleBarDoubleClick() } })
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            HStack(spacing: 2) {
                IconButton(icon: "sidebar.left", help: model.sidebarHidden ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)") { model.toggleSidebar() }
                IconButton(icon: "chevron.left", help: "Back (⌘[)") { model.back() }
                    .disabled(model.backStack.isEmpty).opacity(model.backStack.isEmpty ? 0.35 : 1)
                IconButton(icon: "chevron.right", help: "Forward (⌘])") { model.forward() }
                    .disabled(model.forwardStack.isEmpty).opacity(model.forwardStack.isEmpty ? 0.35 : 1)
            }
            .frame(height: 28)
            .padding(.leading, Chrome.buttonsLeft).padding(.top, Chrome.center - 14)
            .ignoresSafeArea()
        }
        .overlay {
            if model.paletteOpen || model.composeOpen {
                Color.black.opacity(0.32).ignoresSafeArea()
                    .onTapGesture { model.paletteOpen = false; model.composeOpen = false }
                    .transition(.opacity)
            }
        }
        .overlay { if model.paletteOpen { CommandPalette().transition(.panel) } }
        .overlay { if model.composeOpen { ComposeSheet().transition(.panel) } }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if !model.connected && !model.everConnected { ConnectingView().transition(.opacity) } }
        .animation(M.pop, value: model.paletteOpen)
        .animation(M.pop, value: model.composeOpen)
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
        case .memory: MemoryView()
        case .session(let id): ChatView(id: id)
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
                Logo(size: 40).modifier(Breathe())
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
            .scaleEffect(on.v ? 1.06 : 0.96)
            .shadow(color: T.accent.opacity(on.v ? 0.55 : 0.15), radius: on.v ? 18 : 6)
            .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on.v = true } }
    }
}

struct Logo: View {
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(LinearGradient(colors: [T.accent, T.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Path { p in
                    p.move(to: CGPoint(x: size * 0.22, y: size * 0.66))
                    p.addLine(to: CGPoint(x: size * 0.40, y: size * 0.36))
                    p.addLine(to: CGPoint(x: size * 0.54, y: size * 0.56))
                    p.addLine(to: CGPoint(x: size * 0.64, y: size * 0.44))
                    p.addLine(to: CGPoint(x: size * 0.80, y: size * 0.64))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round))
            )
            .frame(width: size, height: size)
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

    var body: some View {
        let on = model.route == .session(session.id)
        let meta = subtitle
        Button { model.open(session.id) } label: {
            HStack(alignment: meta == nil ? .center : .top, spacing: 10) {
                Group {
                    if session.isOrchestrator {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .medium)).foregroundStyle(T.purple)
                    } else {
                        SessionIcon(session: session)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.isOrchestrator ? "Orchestrator" : session.title).font(T.ui(13, on ? .medium : .regular)).foregroundStyle(on ? T.text : T.text2).lineLimit(1)
                    if let meta {
                        Text(meta.0).font(T.ui(11.5)).foregroundStyle(meta.1).lineLimit(1)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 4)
                if model.isAwaiting(session) { PulseDot(color: T.orange).padding(.top, meta == nil ? 0 : 6).transition(.scale.combined(with: .opacity)) }
                else if session.unread && !on { Circle().fill(T.accent).frame(width: 6, height: 6).padding(.top, meta == nil ? 0 : 6).transition(.scale.combined(with: .opacity)) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, meta == nil ? 0 : 6)
            .frame(minHeight: 30)
            .background(NavHighlight(on: on, hover: hover.v))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
        .hoverBox(hover)
        .contextMenu { SessionMenu(session: session) }
    }

    var subtitle: (String, Color)? {
        if model.isAwaiting(session) { return (session.askedFor.isEmpty ? "Waiting on you" : session.askedFor, T.orange) }
        if model.isLive(session) { return (session.statusLine.isEmpty ? "Working…" : session.statusLine, T.yellow.opacity(0.85)) }
        if let pr = model.pr(for: session.prUrl) {
            let checks = pr.failing ? "checks failing" : pr.checks == "SUCCESS" ? "checks pass" : pr.checks == "PENDING" ? "checks running" : ""
            return (["#\(pr.number)", pr.state == "MERGED" ? "merged" : pr.review == "APPROVED" ? "approved" : "", checks].filter { !$0.isEmpty }.joined(separator: " · "), pr.failing ? T.red.opacity(0.9) : T.text3)
        }
        if !session.prUrl.isEmpty { return ("#\(session.prNumber)", T.text3) }
        return nil
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
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
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
                HStack { Text("Open Bridge").font(T.ui(12.5)); Spacer(); Kbd(keys: "⌘O") }
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
