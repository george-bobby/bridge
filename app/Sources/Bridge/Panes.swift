import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Split panes
//
// The chat page is a row of panes. Each pane shows one tab of one session
// (its chat, Changes, Terminal or a browser tab); one pane is today's single
// chat, with the page header, tab strip and details column. Side by side,
// every pane is self-contained: its own header (title, tabs, details, menu,
// minimize, close) and its own details (a column when it's wide, a drawer
// otherwise). The focused pane is the route's session and `model.chatTab`,
// so shortcuts act on it. No two panes show the same (session, tab): a web
// view or a terminal can only live in one place, and two composers on one
// chat would only confuse.

struct Pane: Identifiable, Hashable {
    let id = UUID().uuidString
    var run: String
    var tab = "chat"
    var weight: CGFloat = 1
    /// Side by side: this pane's details are open (one pane uses
    /// `inspectorShown`), and whether its drawer is folded to the strip.
    var details = false
    var drawerFolded = false
    /// Minimized to a narrow strip with its icon and title.
    var collapsed = false
}

enum PaneEdge { case leading, trailing, center }

struct DropZone: Equatable { let pane: String; let edge: PaneEdge }

/// What a drag carries: a sidebar session is its bare id (`.draggable(s.id)`),
/// a tab or pane header is `bridge-tab:<run>\t<tab>`.
enum PanePayload {
    static let prefix = "bridge-tab:"
    static func tab(_ run: String, _ tab: String) -> String { prefix + run + "\t" + tab }

    @MainActor static func parse(_ raw: String, in model: AppModel) -> (run: String, tab: String)? {
        if raw.hasPrefix(prefix) {
            let parts = raw.dropFirst(prefix.count).split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.sessions.contains(where: { $0.id == id }) ? (id, "chat") : nil
    }
}

extension AppModel {
    static let maxPanes = 4

    /// What the page container keys its transition on: every session shares
    /// one page, so moving focus between panes never rebuilds them.
    var pageId: String {
        if case .session = route { return "session" }
        return "\(route)"
    }

    var isSplit: Bool { panes.count > 1 }
    /// Sessions shown in a pane other than the focused one.
    var paneRuns: Set<String> { Set(panes.map(\.run).filter { !$0.isEmpty && $0 != openId }) }

    func pane(_ id: String) -> Int? { panes.firstIndex { $0.id == id } }

    /// open(id) lands here first: a session already on screen gets focus,
    /// anything else replaces the focused pane's content.
    func placeInPanes(_ id: String) {
        guard panes.indices.contains(focusedPane) else { panes = [Pane(run: id)]; focusedPane = 0; return }
        if panes[focusedPane].run == id { return }
        if let j = panes.firstIndex(where: { $0.run == id }) { focusedPane = j; return }
        panes[focusedPane].run = id
        if panes[focusedPane].tab != "changes" { panes[focusedPane].tab = "chat" }
    }

    func focusPane(_ j: Int) {
        guard panes.indices.contains(j) else { return }
        if panes[j].collapsed { withAnimation(M.snappy) { panes[j].collapsed = false } }
        if focusedPane != j { withAnimation(M.hover) { focusedPane = j } }
        let run = panes[j].run
        if !run.isEmpty, route != .session(run) || openId != run { open(run) }
    }

    func stepPane(_ delta: Int) {
        guard isSplit else { return }
        var j = focusedPane
        for _ in panes.indices {
            j = (j + delta + panes.count) % panes.count
            if !panes[j].collapsed { return focusPane(j) }
        }
    }

    /// A tab clicked in a pane's own strip: shown in that pane, unless
    /// another pane already shows it (then that pane takes focus).
    func showTab(_ key: String, of run: String, in paneId: String?) {
        guard let paneId, let j = pane(paneId) else { return showTab(key, of: run) }
        if panes[j].tab == key { return focusPane(j) }
        if let k = panes.firstIndex(where: { $0.run == run && $0.tab == key }) { return focusPane(k) }
        panes[j].tab = key
        focusPane(j)
    }

    /// The details are for the chat and its changes; a browser or terminal
    /// wants the room. One pane follows ⌥⌘I; side by side, each pane its own.
    func paneShowsDetails(_ p: Pane) -> Bool {
        !p.run.isEmpty && (isSplit ? p.details : inspectorShown) && (p.tab == "chat" || p.tab == "changes")
    }

    func toggleDetails(_ paneId: String? = nil) {
        withAnimation(M.snappy) {
            guard isSplit, let j = paneId.flatMap(pane) ?? (panes.indices.contains(focusedPane) ? focusedPane : nil) else {
                return inspectorShown.toggle()
            }
            panes[j].details.toggle()
            if panes[j].details { panes[j].drawerFolded = false }
        }
        if let j = paneId.flatMap(pane) ?? (panes.indices.contains(focusedPane) ? focusedPane : nil), panes[j].details {
            let run = panes[j].run
            Task { await loadTask(run) }
        }
    }

    func toggleDrawer(_ paneId: String) {
        guard let j = pane(paneId) else { return }
        withAnimation(M.snappy) { panes[j].drawerFolded.toggle() }
    }

    /// Minimize a pane to a strip; the last expanded pane stays put.
    func collapsePane(_ id: String) {
        guard isSplit, let j = pane(id), panes.filter({ !$0.collapsed }).count > 1 else { return }
        withAnimation(M.snappy) { panes[j].collapsed = true }
        if j == focusedPane {
            let order = Array(panes.indices[j...]) + panes.indices[..<j].reversed()
            if let k = order.first(where: { !panes[$0].collapsed }) { focusPane(k) }
        }
    }

    func evenOutPanes() {
        withAnimation(M.snappy) { for i in panes.indices { panes[i].weight = 1 } }
    }

    /// Back to one chat: the focused pane stays.
    func closeOtherPanes() {
        guard isSplit, panes.indices.contains(focusedPane) else { return }
        withAnimation(M.snappy) {
            var keep = panes[focusedPane]
            keep.weight = 1
            keep.collapsed = false
            panes = [keep]
            focusedPane = 0
        }
    }

    func loadTask(_ run: String) async {
        guard !run.isEmpty, run != openId else { return }
        let kind = runData(run)["kind"].string
        guard kind == "task" || kind == "slack" || kind.isEmpty else { return }
        if let t = try? await API.get("/api/tasks/\(API.q(run))") { taskCache[run] = t }
    }

    /// Switch to a tab of a session: focus the pane already showing it,
    /// otherwise show it in that session's pane.
    func showTab(_ key: String, of run: String) {
        if let j = panes.firstIndex(where: { $0.run == run && $0.tab == key }) { return focusPane(j) }
        if panes.indices.contains(focusedPane), panes[focusedPane].run == run { chatTab = key; return }
        if let j = panes.firstIndex(where: { $0.run == run }) { panes[j].tab = key; return focusPane(j) }
        chatTab = key
    }

    /// A tab went away (closed browser or terminal): panes on it close when
    /// that session's chat is already on screen, else fall back to the chat.
    func vacate(_ run: String, _ tab: String) {
        for p in panes where p.run == run && p.tab == tab {
            if isSplit && panes.contains(where: { $0.run == run && $0.tab == "chat" }) { closePane(p.id) }
            else if let j = pane(p.id) { panes[j].tab = "chat" }
        }
    }

    func forgetPanes(of run: String) {
        for p in panes where p.run == run && isSplit { closePane(p.id) }
    }

    func closePane(_ id: String) {
        guard isSplit, let j = pane(id) else { return }
        let wasFocused = j == focusedPane
        withAnimation(M.snappy) {
            let w = panes[j].weight
            panes.remove(at: j)
            panes[max(0, j - 1)].weight += w
            if focusedPane > j || focusedPane >= panes.count { focusedPane = max(0, focusedPane - 1) }
            // Never leave only strips behind.
            if panes.count == 1 || !panes.contains(where: { !$0.collapsed }) { panes[focusedPane].collapsed = false }
        }
        if wasFocused { focusPane(min(max(0, j - 1), panes.count - 1)) }
    }

    func closeFocusedPane() {
        if panes.indices.contains(focusedPane) { closePane(panes[focusedPane].id) }
    }

    /// Put (run, tab) beside `target` or into it. Content already on screen
    /// moves rather than duplicates; dragging a pane's own tab to its edge
    /// leaves that pane on the session's chat (or Changes, for the chat).
    func dropInPane(run: String, tab: String, at target: String, edge: PaneEdge) {
        guard var t = pane(target) else { return }
        if tab.hasPrefix("web-") && !(browserTabs[run] ?? []).contains(where: { "web-\($0.id)" == tab }) { return }
        if tab.hasPrefix("task-") && !(taskTabs[run] ?? []).contains(String(tab.dropFirst(5))) { taskTabs[run, default: []].append(String(tab.dropFirst(5))) }
        if tab == "term" { terminalTabs.insert(run) }
        withAnimation(M.snappy) {
            let existing = panes.firstIndex { $0.run == run && $0.tab == tab }
            if edge == .center {
                if let e = existing, e != t {
                    panes[t].weight += panes[e].weight
                    panes.remove(at: e)
                    if e < t { t -= 1 }
                }
                panes[t].run = run
                panes[t].tab = tab
                panes[t].collapsed = false
                focusedPane = t
                return
            }
            if let e = existing {
                if e == t {
                    let other = tab == "chat" ? "changes" : "chat"
                    if panes.contains(where: { $0.run == run && $0.tab == other }) {
                        if !isSplit { return }
                        // Both of this session's views are up: just move the pane.
                        let moved = panes.remove(at: e)
                        let at = min(edge == .leading ? 0 : panes.count, panes.count)
                        panes.insert(moved, at: at)
                        focusedPane = at
                        return
                    }
                    panes[t].tab = other
                } else {
                    panes[t].weight += panes[e].weight
                    panes.remove(at: e)
                    if e < t { t -= 1 }
                }
            }
            guard panes.count < Self.maxPanes else {
                say("Up to \(Self.maxPanes) panes side by side", bad: true)
                return
            }
            // A new split evens the row out; the divider tunes it from there.
            let at = edge == .leading ? t : t + 1
            panes.insert(Pane(run: run, tab: tab), at: at)
            for i in panes.indices { panes[i].weight = 1 }
            focusedPane = at
        }
        focusPane(focusedPane)
    }

    /// "Open to the Side" / ⌥-click: the session's chat beside the focused
    /// pane (or focus it, when it's already on screen). Off the chat page,
    /// this is just open.
    func openToSide(_ run: String) {
        guard isChatRoute, panes.indices.contains(focusedPane), !panes[focusedPane].run.isEmpty else { return open(run) }
        if let j = panes.firstIndex(where: { $0.run == run && $0.tab == "chat" }) { return focusPane(j) }
        if panes.count >= Self.maxPanes, let last = panes.last {
            return dropInPane(run: run, tab: "chat", at: last.id, edge: .center)
        }
        dropInPane(run: run, tab: "chat", at: panes[focusedPane].id, edge: .trailing)
    }

    /// ⌘\: open something useful beside the focused pane: this session's
    /// Changes (from its chat) or chat (from anything else), else the next
    /// chat in sidebar order that isn't on screen yet.
    func splitRight() {
        guard panes.indices.contains(focusedPane) else { return }
        let cur = panes[focusedPane]
        guard !cur.run.isEmpty else { return }
        let want = cur.tab == "chat" ? "changes" : "chat"
        if !panes.contains(where: { $0.run == cur.run && $0.tab == want }) {
            return dropInPane(run: cur.run, tab: want, at: cur.id, edge: .trailing)
        }
        let shown = Set(panes.filter { $0.tab == "chat" }.map(\.run))
        let order = chatOrder
        let start = order.firstIndex(of: cur.run) ?? -1
        let next = (order[(start + 1)...] + order[..<max(0, start)]).first { !shown.contains($0) }
        if let next { dropInPane(run: next, tab: "chat", at: cur.id, edge: .trailing) }
    }

    func refreshPanes() async {
        for run in paneRuns {
            if let r = try? await API.get("/api/runs/\(API.q(run))") { runs[run] = r["run"] }
        }
        for p in panes where p.details && isSplit && paneRuns.contains(p.run) { await loadTask(p.run) }
    }

    // MARK: terminal tabs

    func openTerminalTab(_ run: String) {
        withAnimation(M.snappy) {
            terminalTabs.insert(run)
            showTab("term", of: run)
        }
    }

    func closeTerminalTab(_ run: String) {
        withAnimation(M.snappy) {
            terminalTabs.remove(run)
            vacate(run, "term")
        }
        terms.drop(run)
    }

    func tabLabel(_ tab: String, of run: String) -> (icon: String, label: String) {
        switch tab {
        case "chat": return ("bubble.left", "Chat")
        case "changes": return ("plusminus", "Changes")
        case "term": return ("terminal", "Terminal")
        case _ where tab.hasPrefix("task-"):
            let t = agentTask(run, String(tab.dropFirst(5)))
            return (t?.icon ?? "square.stack.3d.down.right", t?.title ?? "Task")
        default:
            let id = String(tab.dropFirst(4))
            let page = web.existing(id)
            return ("globe", page?.label ?? "Browser")
        }
    }

    func sessionTitle(_ run: String) -> String {
        guard let s = sessions.first(where: { $0.id == run }) else { return runData(run)["who"].nonEmpty ?? run }
        return s.isOrchestrator ? "Orchestrator" : s.title
    }
}

// MARK: - Layout

/// Pane frames in window coordinates, for click-to-focus.
@MainActor final class PaneFrames {
    static let shared = PaneFrames()
    var frames: [String: CGRect] = [:]
    private var monitor: Any?
    private var keys: Any?
    private var dragTimer: Timer?
    private var dragCount = 0
    weak var model: AppModel?

    /// Two event hooks, installed once. A click inside a pane focuses it
    /// (whatever view takes the click: text views, the terminal and web views
    /// never let a SwiftUI gesture see it). And a drag of a session or tab
    /// arms the drop zones: the drag pasteboard is polled while the button is
    /// down, since a drag session runs its own event loop.
    func install(_ model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseDown(e) }
            return e
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            MainActor.assumeIsolated { model.messageKey(e) } ? nil : e
        }
    }

    private func mouseDown(_ e: NSEvent) {
        guard let model, let view = e.window?.contentView else { return }
        dragCount = NSPasteboard(name: .drag).changeCount
        watchDrag()
        guard case .session = model.route, model.isSplit, !model.paletteOpen, !model.composeOpen else { return }
        let p = CGPoint(x: e.locationInWindow.x, y: view.bounds.height - e.locationInWindow.y)
        // A minimized strip expands from its own controls, not any click.
        if let hit = frames.first(where: { $0.value.contains(p) })?.key, let j = model.pane(hit), j != model.focusedPane, !model.panes[j].collapsed {
            model.focusPane(j)
        }
    }

    private func watchDrag() {
        dragTimer?.invalidate()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let model = self.model else { return timer.invalidate() }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    timer.invalidate()
                    // Let a drop land before the catchers go away.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if model.paneDragActive { withAnimation(M.hover) { model.paneDragActive = false; model.dropZone = nil } } }
                    return
                }
                let pb = NSPasteboard(name: .drag)
                guard !model.paneDragActive, pb.changeCount != self.dragCount else { return }
                self.dragCount = pb.changeCount
                if case .session = model.route, let raw = pb.string(forType: .string), PanePayload.parse(raw, in: model) != nil {
                    withAnimation(M.hover) { model.paneDragActive = true }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dragTimer = t
    }
}

struct PaneArea: View {
    @Environment(AppModel.self) var model

    static let stripWidth: CGFloat = 40

    var body: some View {
        GeometryReader { g in
            let panes = model.panes
            let open = panes.filter { !$0.collapsed }
            let total = max(open.reduce(0) { $0 + $1.weight }, 0.001)
            let gaps = CGFloat(max(panes.count - 1, 0))
            let strips = CGFloat(panes.count - open.count) * Self.stripWidth
            let usable = max(g.size.width - gaps - strips, 1)
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { i, p in
                    if i > 0 {
                        PaneDivider(left: panes[i - 1].id, right: p.id, usable: usable, total: total,
                                    fixed: p.collapsed || panes[i - 1].collapsed)
                    }
                    let w = p.collapsed ? Self.stripWidth : usable * p.weight / total
                    PaneView(pane: p, index: i, width: w)
                        .frame(width: w)
                        .clipped()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .onAppear { PaneFrames.shared.install(model) }
    }
}

struct PaneDivider: View {
    @Environment(AppModel.self) var model
    let left: String
    let right: String
    let usable: CGFloat
    let total: CGFloat
    /// Next to a minimized strip: a plain hairline, nothing to resize.
    var fixed = false
    @StateObject private var hover = Box(false)
    @StateObject private var start = Box<(CGFloat, CGFloat)?>(nil)

    var body: some View {
        if fixed {
            Rectangle().fill(T.line).frame(width: 1)
        } else {
            handle
        }
    }

    var handle: some View {
        Rectangle().fill(hover.v || start.v != nil ? T.accent.opacity(0.7) : T.line)
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(M.hover) { hover.v = inside }
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            guard let l = model.pane(left), let r = model.pane(right) else { return }
                            if start.v == nil { start.v = (model.panes[l].weight, model.panes[r].weight) }
                            guard let (wl, wr) = start.v else { return }
                            let pair = wl + wr
                            let minW = 300 * total / usable
                            let delta = v.translation.width * total / usable
                            let nl = min(max(wl + delta, minW), pair - minW)
                            guard pair > 2 * minW else { return }
                            model.panes[l].weight = nl
                            model.panes[r].weight = pair - nl
                        }
                        .onEnded { _ in start.v = nil })
                    .onTapGesture(count: 2) {
                        guard let l = model.pane(left), let r = model.pane(right) else { return }
                        let pair = model.panes[l].weight + model.panes[r].weight
                        withAnimation(M.snappy) { model.panes[l].weight = pair / 2; model.panes[r].weight = pair / 2 }
                    }
            }
            .help("Drag to resize; double-click to even out")
            .zIndex(1)
    }
}

struct PaneView: View {
    @Environment(AppModel.self) var model
    let pane: Pane
    let index: Int
    let width: CGFloat

    /// Wide enough to keep the details beside the content; narrower panes
    /// dock them underneath.
    static let columnMin: CGFloat = 800

    var focused: Bool { model.focusedPane == index }
    var details: Bool { model.isSplit && model.paneShowsDetails(pane) }
    var column: Bool { width >= Self.columnMin }

    var body: some View {
        ZStack {
            if pane.collapsed {
                CollapsedPane(pane: pane, focused: focused)
                    .transition(.opacity)
            } else {
                full.transition(.opacity)
            }
        }
        .animation(M.snappy, value: pane.collapsed)
        .background(T.panel)
        .clipped()
        .contentShape(Rectangle())
        .overlay { if model.paneDragActive { DropZones(zone: model.dropZone?.pane == pane.id ? model.dropZone?.edge : nil).allowsHitTesting(false) } }
        .overlay {
            if model.paneDragActive {
                DropCatcher(
                    split: model.isSplit,
                    update: { edge in model.hintDrop(pane.id, edge) },
                    perform: { raw, edge in
                        model.landDrop(raw, at: pane.id, edge: edge)
                    })
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PaneFrames.shared.frames[pane.id] = $0 }
        .onDisappear { PaneFrames.shared.frames[pane.id] = nil }
    }

    var full: some View {
        VStack(spacing: 0) {
            if model.isSplit { PaneHeader(pane: pane, focused: focused, width: width).transition(.opacity) }
            HStack(spacing: 0) {
                ZStack { PaneContent(run: pane.run, tab: pane.tab).id(pane.run + "|" + pane.tab).transition(.opacity) }
                    .animation(M.page, value: pane.run + "|" + pane.tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if details && column {
                    HStack(spacing: 0) {
                        Rectangle().fill(T.line).frame(width: 1)
                        PropertiesPanel(id: pane.run).frame(width: 288)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .clipped()
            if details && !column {
                DetailsDrawer(id: pane.run, open: !pane.drawerFolded) { model.toggleDrawer(pane.id) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(M.snappy, value: details)
        .animation(M.snappy, value: column)
        .task(id: details ? pane.run : "") { if details { await model.loadTask(pane.run) } }
    }
}

/// A split pane's own header: what it shows, its tabs and its controls, so
/// each pane reads (and works) as a chat of its own.
struct PaneHeader: View {
    @Environment(AppModel.self) var model
    let pane: Pane
    let focused: Bool
    let width: CGFloat

    var narrow: Bool { width < 430 }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            SessionTabs(runId: pane.run, session: model.sessions.first { $0.id == pane.run }, pane: pane, narrow: narrow)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(T.accent).frame(height: 2).opacity(focused ? 1 : 0)
        }
        .animation(M.hover, value: focused)
    }

    var titleRow: some View {
        let s = model.sessions.first { $0.id == pane.run }
        let live = s.map { model.isLive($0) && !model.isAwaiting($0) } ?? false
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let s {
                    if s.isOrchestrator { Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(T.purple) } else { SessionIcon(session: s, size: 13) }
                    if !narrow && !s.issueKey.isEmpty && !s.title.hasPrefix(s.issueKey) {
                        Text(s.issueKey).font(T.mono(11.5)).foregroundStyle(T.text3).fixedSize()
                    }
                }
                Text(model.sessionTitle(pane.run))
                    .font(T.ui(13, .semibold)).foregroundStyle(focused ? T.text : T.text2)
                    .lineLimit(1).truncationMode(.tail)
                if live {
                    Group { if narrow { LiveIcon(size: 10) } else { LiveBadge() } }
                        .fixedSize()
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer(minLength: 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if let j = model.pane(pane.id) { model.focusPane(j) } }
            .onDrag { NSItemProvider(object: PanePayload.tab(pane.run, pane.tab) as NSString) }
            .help("Drag onto another pane's edge to move it")
            controls(s, live: live)
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 40)
        .animation(M.snappy, value: live)
    }

    @ViewBuilder func controls(_ s: Session?, live: Bool) -> some View {
        HStack(spacing: 1) {
            if let s, model.isLive(s) {
                IconButton(icon: "stop.fill", help: "Stop the running turn", size: 24, tint: T.red) { Task { await model.stop(s.id) } }
                    .transition(.scale.combined(with: .opacity))
            }
            if pane.tab == "chat" || pane.tab == "changes" {
                IconButton(icon: "sidebar.right", help: pane.details ? "Hide details (⌥⌘I)" : "Show details (⌥⌘I)", size: 24, on: pane.details) {
                    model.toggleDetails(pane.id)
                }
            }
            Menu {
                if let s {
                    Button { Task { await model.setPinned(s.id, !s.pinned) } } label: { Label(s.pinned ? "Unpin" : "Pin to the Sidebar", systemImage: s.pinned ? "star.slash" : "star") }
                }
                Button { model.splitRight() } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
                Button { model.collapsePane(pane.id) } label: { Label("Minimize Pane", systemImage: "arrow.right.and.line.vertical.and.arrow.left") }
                    .disabled(model.panes.filter { !$0.collapsed }.count < 2)
                Button { model.closeOtherPanes() } label: { Label("Close Other Panes", systemImage: "rectangle") }
                if let s {
                    Divider()
                    if !s.permalink.isEmpty { Button { model.openThread(s.permalink) } label: { Label("Read the Slack Thread", systemImage: "number") } }
                    SessionMenu(session: s, inChat: true)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(T.text2).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
            .help("More")
            if !narrow {
                IconButton(icon: "minus", help: "Minimize pane", size: 24) { model.collapsePane(pane.id) }
                    .disabled(model.panes.filter { !$0.collapsed }.count < 2)
            }
            IconButton(icon: "xmark", help: "Close pane (⌘⇧W): the session stays in the sidebar", size: 24) { model.closePane(pane.id) }
        }
    }
}

/// A minimized pane: a narrow strip with the session's icon and title.
/// Clicking it (or its expand button) brings the pane back.
struct CollapsedPane: View {
    @Environment(AppModel.self) var model
    let pane: Pane
    let focused: Bool
    @StateObject private var hover = Box(false)

    var body: some View {
        let s = model.sessions.first { $0.id == pane.run }
        let t = model.tabLabel(pane.tab, of: pane.run)
        VStack(spacing: 10) {
            IconButton(icon: "arrow.left.and.right", help: "Expand pane", size: 24) { expand() }
                .padding(.top, 8)
            if let s {
                if s.isOrchestrator { Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(T.purple) } else { SessionIcon(session: s, size: 13) }
                if model.isLive(s) && !model.isAwaiting(s) { LiveIcon(size: 10) }
            }
            Image(systemName: t.icon).font(.system(size: 10.5, weight: .medium)).foregroundStyle(T.text3)
            GeometryReader { g in
                Text(model.sessionTitle(pane.run))
                    .font(T.ui(12.5, .medium)).foregroundStyle(hover.v ? T.text : T.text2)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: g.size.height, height: 20, alignment: .leading)
                    .rotationEffect(.degrees(90))
                    .frame(width: g.size.width, height: g.size.height)
            }
            IconButton(icon: "xmark", help: "Close pane", size: 24) { model.closePane(pane.id) }
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hover.v ? T.hover.opacity(0.5) : T.bg.opacity(0.35))
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        .onDrag { NSItemProvider(object: PanePayload.tab(pane.run, pane.tab) as NSString) }
        .hoverBox(hover)
        .help("Expand \(model.sessionTitle(pane.run))")
    }

    func expand() {
        if let j = model.pane(pane.id) { model.focusPane(j) }
    }
}


/// One pane's content: the same views the single chat always showed.
struct PaneContent: View {
    @Environment(AppModel.self) var model
    let run: String
    let tab: String

    var body: some View {
        if run.isEmpty {
            Color.clear
        } else if tab == "changes" {
            ChangesView(runId: run)
        } else if tab == "term" {
            TerminalTab(runId: run)
        } else if tab.hasPrefix("web-"), let t = model.browserTabs[run]?.first(where: { "web-\($0.id)" == tab }) {
            BrowserView(page: model.web.page(for: t))
        } else if tab.hasPrefix("task-") {
            TaskView(runId: run, taskId: String(tab.dropFirst(5)))
        } else {
            // Pinned to the pane's width: a composer or card that can't
            // shrink further must not widen (and off-center) the transcript.
            GeometryReader { g in
                VStack(spacing: 0) {
                    Transcript(run: model.runData(run), runId: run).frame(width: g.size.width)
                    PlanPill(runId: run).frame(width: g.size.width)
                    TaskStrip(runId: run).frame(width: g.size.width)
                    Composer(runId: run).frame(width: g.size.width)
                }
            }
            .task(id: run) { if run != model.openId && model.runs[run] == nil { await model.refreshPanes() } }
        }
    }
}

struct DropZones: View {
    let zone: PaneEdge?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: zone == .trailing ? .trailing : .leading) {
                Color.clear
                if let zone {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(T.accent.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.accent.opacity(0.7), lineWidth: 1.5))
                        .overlay {
                            Label(zone == .center ? "Open here" : zone == .leading ? "Split left" : "Split right", systemImage: zone == .center ? "rectangle" : "rectangle.split.2x1")
                                .font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(T.raised))
                                .overlay(Capsule().stroke(T.line, lineWidth: 1))
                        }
                        .frame(width: zone == .center ? w - 16 : w / 2 - 12)
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .animation(M.snappy, value: zone)
        }
    }
}

/// The drop target, as a plain NSView laid over the pane while a drag is on:
/// web views, text views and the terminal all register for text drops
/// themselves, and an AppKit view above them is the one sure way to win.
struct DropCatcher: NSViewRepresentable {
    let split: Bool
    /// Every point is this edge (the details column: "beside the chat").
    var fixed: PaneEdge? = nil
    let update: (PaneEdge?) -> Void
    let perform: (String, PaneEdge) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.registerForDraggedTypes([.string])
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.update = update
        v.perform = perform
        v.split = split
        v.fixed = fixed
    }

    final class CatcherView: NSView {
        var update: (PaneEdge?) -> Void = { _ in }
        var perform: (String, PaneEdge) -> Bool = { _, _ in false }
        var split = false
        var fixed: PaneEdge?
        private var edge: PaneEdge = .center

        /// One pane: either half splits. Split: the outer bands split, the
        /// middle replaces that pane.
        func zone(_ info: NSDraggingInfo) -> PaneEdge {
            if let fixed { return fixed }
            let x = convert(info.draggingLocation, from: nil).x
            if !split { return x < bounds.width / 2 ? .leading : .trailing }
            let band = min(bounds.width * 0.3, 220)
            return x < band ? .leading : x > bounds.width - band ? .trailing : .center
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            edge = zone(sender)
            update(edge)
            return .move
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { update(nil) }
        override func draggingEnded(_ sender: NSDraggingInfo) { update(nil) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let raw = sender.draggingPasteboard.string(forType: .string) else { return false }
            return perform(raw, zone(sender))
        }
    }
}

// MARK: - Menu

struct PaneCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Pane") {
            Button { model.splitRight() } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
                .keyboardShortcut("\\")
                .disabled(!model.isChatRoute)
            Button { model.closeFocusedPane() } label: { Label("Close Pane", systemImage: "xmark.rectangle") }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!model.isSplit || !model.isChatRoute)
            Divider()
            Button { model.stepPane(-1) } label: { Label("Focus Previous Pane", systemImage: "arrow.left.to.line") }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!model.isSplit || !model.isChatRoute)
            Button { model.stepPane(1) } label: { Label("Focus Next Pane", systemImage: "arrow.right.to.line") }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.isSplit || !model.isChatRoute)
            Divider()
            Button { if case .session(let id) = model.route { model.openTerminalTab(id) } } label: { Label("Terminal", systemImage: "terminal") }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(!model.isChatRoute)
            Button { if case .session(let id) = model.route { withAnimation(M.snappy) { model.showTab("changes", of: id) } } } label: { Label("Changes", systemImage: "plusminus") }
                .disabled(!model.isChatRoute)
        }
    }
}

extension AppModel {
    func hintDrop(_ pane: String, _ edge: PaneEdge?) {
        guard let edge else {
            if dropZone?.pane == pane { withAnimation(M.hover) { dropZone = nil } }
            return
        }
        let z = DropZone(pane: pane, edge: edge)
        if dropZone != z { withAnimation(M.hover) { dropZone = z } }
    }

    @discardableResult func landDrop(_ raw: String, at pane: String, edge: PaneEdge) -> Bool {
        dropZone = nil
        guard let (run, tab) = PanePayload.parse(raw, in: self) else { return false }
        dropInPane(run: run, tab: tab, at: pane, edge: edge)
        withAnimation(M.hover) { paneDragActive = false }
        return true
    }

    var showsDetails: Bool { panes.indices.contains(focusedPane) ? paneShowsDetails(panes[focusedPane]) : false }
    var isChatRoute: Bool { if case .session = route { return true }; return false }
}
