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
        let routes: [(String, Route)] = [("home", .home), ("board", .board), ("sessions", .sessions), ("pulls", .pulls), ("linear", .linear), ("inbox", .inbox), ("memory", .memory), ("slack", .slack)]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            var pages = routes
            let chat = ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_CHAT"]
            if let s = model.sessions.first(where: { $0.id == chat }) ?? model.boardSessions.first(where: { $0.worked }) ?? model.orchestrator { pages.append(("chat", .session(s.id))) }
            pages.append(("palette", .board))
            for (name, route) in pages {
                model.paletteOpen = name == "palette"
                if case .session(let id) = route { model.open(id) } else { model.route = route }
                if name == "slack", let m = model.mentions.first { model.openThread(m.permalink) }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 800 })?.contentView,
                      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
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

struct BridgeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task…") { model.compose(in: model.projectFilter) }.keyboardShortcut("n")
        }
        CommandMenu("Go") {
            Button("Command Menu…") { model.paletteOpen = true }.keyboardShortcut("k")
            Divider()
            Button("Home") { model.route = .home }.keyboardShortcut("1")
            Button("Inbox") { model.route = .inbox }.keyboardShortcut("2")
            Button("Board") { model.route = .board }.keyboardShortcut("3")
            Button("Sessions") { model.route = .sessions }.keyboardShortcut("4")
            Button("Pull Requests") { model.route = .pulls }.keyboardShortcut("5")
            Button("Linear") { model.route = .linear }.keyboardShortcut("6")
            Button("Memory") { model.route = .memory }.keyboardShortcut("7")
            Button("Slack") { model.route = .slack }.keyboardShortcut("8")
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

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Sidebar().frame(width: 236)
            Rectangle().fill(T.line).frame(width: 1)
            ZStack {
                T.panel
                detail
            }
        }
        .background(T.bg)
        .ignoresSafeArea()
        .overlay { if model.paletteOpen { CommandPalette().transition(.opacity) } }
        .overlay { if model.composeOpen { ComposeSheet().transition(.opacity) } }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if !model.connected && !model.everConnected { ConnectingView() } }
        .animation(.easeOut(duration: 0.12), value: model.paletteOpen)
        .animation(.easeOut(duration: 0.12), value: model.composeOpen)
    }

    @ViewBuilder var detail: some View {
        switch model.route {
        case .home: HomeView()
        case .inbox: InboxView()
        case .slack: SlackView()
        case .board: BoardView()
        case .sessions: SessionsView()
        case .pulls: PullsView()
        case .linear: LinearView()
        case .memory: MemoryView()
        case .session(let id): ChatView(id: id).id(id)
        }
    }
}

struct ConnectingView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        ZStack {
            T.bg
            VStack(spacing: 14) {
                Logo(size: 40)
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
        Text(text).font(T.ui(11.5, .medium)).foregroundStyle(T.text3)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
    }
}

struct NavItem: View {
    @Environment(AppModel.self) var model
    let icon: String
    let label: String
    let route: Route
    var badge: Int = 0
    var count: Int = 0
    var hot = false
    @StateObject private var hover = Box(false)

    var body: some View {
        let on = model.route == route
        Button { model.route = route } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .medium)).frame(width: 16)
                    .foregroundStyle(on ? T.text : T.text2)
                Text(label).font(T.ui(13, on ? .medium : .regular)).foregroundStyle(on ? T.text : T.text2)
                Spacer()
                if badge > 0 {
                    Text(verbatim: "\(badge)").font(T.ui(10.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 16)
                        .background(Capsule().fill(hot ? T.orange : T.text3))
                } else if count > 0 {
                    HStack(spacing: 4) {
                        if hot { Circle().fill(T.red).frame(width: 5, height: 5) }
                        Text(verbatim: "\(count)").font(T.ui(11.5)).foregroundStyle(T.text3)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? T.selected : hover.v ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.v = $0 }
    }
}

struct SessionNavItem: View {
    @Environment(AppModel.self) var model
    let session: Session
    @StateObject private var hover = Box(false)

    var body: some View {
        let on = model.route == .session(session.id)
        Button { model.open(session.id) } label: {
            HStack(spacing: 9) {
                if session.isOrchestrator {
                    Image(systemName: "sparkles").font(.system(size: 11.5, weight: .medium)).foregroundStyle(T.purple).frame(width: 16)
                } else {
                    SessionIcon(session: session).frame(width: 16)
                }
                Text(session.isOrchestrator ? "Orchestrator" : session.title).font(T.ui(12.5)).foregroundStyle(on ? T.text : T.text2).lineLimit(1)
                Spacer(minLength: 4)
                if model.isAwaiting(session) { Circle().fill(T.orange).frame(width: 6, height: 6) }
                else if session.unread && !on { Circle().fill(T.accent).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? T.selected : hover.v ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.v = $0 }
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
                .background(RoundedRectangle(cornerRadius: 9).fill(T.raised))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: model.toast)
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
