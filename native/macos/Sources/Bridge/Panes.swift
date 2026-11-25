import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Split panes
//
// The chat page is a row of panes. Each pane shows one tab of one session
// (its chat, Changes, Terminal or a browser tab); one pane is today's single
// chat. The focused pane is the route's session and `model.chatTab`, so the
// header, the tab strip and the details panel all follow focus. No two panes
// show the same (session, tab): a web view or a terminal can only live in one
// place, and two composers on one chat would only confuse.

struct Pane: Identifiable, Hashable {
    let id = UUID().uuidString
    var run: String
    var tab = "chat"
    var weight: CGFloat = 1
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
        if focusedPane != j { withAnimation(M.hover) { focusedPane = j } }
        let run = panes[j].run
        if !run.isEmpty, route != .session(run) || openId != run { open(run) }
    }

    func stepPane(_ delta: Int) {
        guard isSplit else { return }
        focusPane((focusedPane + delta + panes.count) % panes.count)
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
    }

    private func mouseDown(_ e: NSEvent) {
        guard let model, let view = e.window?.contentView else { return }
        dragCount = NSPasteboard(name: .drag).changeCount
        watchDrag()
        guard case .session = model.route, model.isSplit, !model.paletteOpen, !model.composeOpen else { return }
        let p = CGPoint(x: e.locationInWindow.x, y: view.bounds.height - e.locationInWindow.y)
        if let hit = frames.first(where: { $0.value.contains(p) })?.key, let j = model.pane(hit), j != model.focusedPane {
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

    var body: some View {
        GeometryReader { g in
            let panes = model.panes
            let total = max(panes.reduce(0) { $0 + $1.weight }, 0.001)
            let gaps = CGFloat(max(panes.count - 1, 0))
            let usable = max(g.size.width - gaps, 1)
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { i, p in
                    if i > 0 {
                        PaneDivider(left: panes[i - 1].id, right: p.id, usable: usable, total: total)
                    }
                    PaneView(pane: p, index: i)
                        .frame(width: usable * p.weight / total)
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
    @StateObject private var hover = Box(false)
    @StateObject private var start = Box<(CGFloat, CGFloat)?>(nil)

    var body: some View {
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

    var focused: Bool { model.focusedPane == index }

    var body: some View {
        VStack(spacing: 0) {
            if model.isSplit { PaneHeader(pane: pane, focused: focused).transition(.opacity) }
            ZStack { PaneContent(run: pane.run, tab: pane.tab).id(pane.run + "|" + pane.tab).transition(.opacity) }
                .animation(M.page, value: pane.run + "|" + pane.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isSplit && focused && model.showsDetails && !pane.run.isEmpty {
                DetailsDrawer(id: pane.run)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(M.snappy, value: model.isSplit && focused && model.showsDetails)
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
}

struct PaneHeader: View {
    @Environment(AppModel.self) var model
    let pane: Pane
    let focused: Bool
    @StateObject private var hover = Box(false)

    var body: some View {
        let t = model.tabLabel(pane.tab, of: pane.run)
        let s = model.sessions.first { $0.id == pane.run }
        HStack(spacing: 7) {
            if let s { if s.isOrchestrator { Image(systemName: "sparkles").font(.system(size: 10.5)).foregroundStyle(T.purple) } else { SessionIcon(session: s, size: 11) } }
            Text(model.sessionTitle(pane.run)).font(T.ui(12, focused ? .medium : .regular)).foregroundStyle(focused ? T.text : T.text2).lineLimit(1)
            if let s, model.isLive(s) { LiveIcon(size: 9) }
            Image(systemName: t.icon).font(.system(size: 9.5, weight: .medium)).foregroundStyle(T.text3)
            Text(t.label).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
            Spacer(minLength: 4)
            Button { model.closePane(pane.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text2)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(hover.v ? T.hover : .clear))
            }
            .buttonStyle(Pressable(scale: 0.85))
            .opacity(focused || hover.v ? 1 : 0.5)
            .help("Close pane (⌘⇧W)")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(focused ? T.raised.opacity(0.55) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
        .overlay(alignment: .top) { Rectangle().fill(T.accent).frame(height: 2).opacity(focused ? 1 : 0) }
        .contentShape(Rectangle())
        .onTapGesture { if let j = model.pane(pane.id) { model.focusPane(j) } }
        .onDrag { NSItemProvider(object: PanePayload.tab(pane.run, pane.tab) as NSString) }
        .hoverBox(hover)
        .animation(M.hover, value: focused)
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
        } else {
            // Pinned to the pane's width: a composer or card that can't
            // shrink further must not widen (and off-center) the transcript.
            GeometryReader { g in
                VStack(spacing: 0) {
                    Transcript(run: model.runData(run), runId: run).frame(width: g.size.width)
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
            Button("Split Right") { model.splitRight() }
                .keyboardShortcut("\\")
                .disabled(!model.isChatRoute)
            Button("Close Pane") { model.closeFocusedPane() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!model.isSplit || !model.isChatRoute)
            Divider()
            Button("Focus Previous Pane") { model.stepPane(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!model.isSplit || !model.isChatRoute)
            Button("Focus Next Pane") { model.stepPane(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.isSplit || !model.isChatRoute)
            Divider()
            Button("Terminal") { if case .session(let id) = model.route { model.openTerminalTab(id) } }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(!model.isChatRoute)
            Button("Changes") { if case .session(let id) = model.route { withAnimation(M.snappy) { model.showTab("changes", of: id) } } }
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

    /// The details are for the chat and its changes; a browser or terminal
    /// wants the room.
    var showsDetails: Bool { inspectorShown && (chatTab == "chat" || chatTab == "changes") }
    var isChatRoute: Bool { if case .session = route { return true }; return false }
}
