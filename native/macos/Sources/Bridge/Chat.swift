import AppKit
import SwiftUI

// MARK: - Chat

struct ChatView: View {
    @Environment(AppModel.self) var model
    let id: String

    var session: Session? { model.sessions.first { $0.id == id } }
    var run: JSON { model.openRun }

    /// The details panel is for the chat and its changes; a browser or
    /// terminal wants the width.
    var showsInspector: Bool { model.showsDetails }

    var body: some View {
        VStack(spacing: 0) {
            // Side by side, each pane carries its own header and tabs; the
            // page keeps the layout controls.
            if model.isSplit {
                splitHeader.transition(.opacity)
            } else {
                header.transition(.opacity)
                SessionTabs(runId: id, session: session)
            }
            HStack(spacing: 0) {
                PaneArea()
                    .frame(maxWidth: .infinity)
                // One pane: a trailing column. Side by side, each pane has
                // its own (PaneView).
                if showsInspector && !model.isSplit {
                    HStack(spacing: 0) {
                        Rectangle().fill(T.line).frame(width: 1)
                        PropertiesPanel(id: id).frame(width: 312)
                    }
                    // A drag let go over the details still means "beside it".
                    .overlay { if model.paneDragActive { inspectorCatcher } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .clipped()
        }
        .animation(M.snappy, value: showsInspector)
        .animation(M.snappy, value: model.isSplit)
        .task(id: id) {
            let tab = model.chatTab
            let known = tab == "chat" || tab == "changes" || (tab == "term" && model.terminalTabs.contains(id))
                || (model.browserTabs[id] ?? []).contains(where: { "web-\($0.id)" == tab })
            if !known { model.chatTab = "chat" }
            await model.loadCommands(for: id)
        }
    }

    var inspectorCatcher: some View {
        let target = model.panes.indices.contains(model.focusedPane) ? model.panes[model.focusedPane].id : ""
        return DropCatcher(split: false, fixed: .trailing,
                           update: { edge in model.hintDrop(target, edge) },
                           perform: { raw, _ in model.landDrop(raw, at: target, edge: .trailing) })
    }

    /// Panes side by side: every pane has its own header, so the page only
    /// arranges the panes. (Chats step with ⌥⌘↑ / ⌥⌘↓; messages with the
    /// transcript's own stepper.)
    var splitHeader: some View {
        let n = model.panes.count
        let even = Set(model.panes.filter { !$0.collapsed }.map(\.weight)).count <= 1
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: n >= 3 ? "rectangle.split.3x1" : "rectangle.split.2x1").font(.system(size: 12, weight: .medium))
                Text(verbatim: "\(n) panes").font(T.ui(13, .medium)).contentTransition(.numericText())
            }
            .foregroundStyle(T.text2)
            Text("Drag a session or tab onto a pane's edge to add one").font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1)
            Spacer(minLength: 12)
            if !even {
                Button { model.evenOutPanes() } label: { Label("Even Out", systemImage: "equal") }
                    .buttonStyle(LButton())
                    .transition(.scale.combined(with: .opacity))
            }
            if n < AppModel.maxPanes {
                IconButton(icon: "rectangle.split.2x1", help: "Split right (⌘\\)") { model.splitRight() }
            }
            IconButton(icon: "rectangle", help: "Close other panes: back to one chat") { model.closeOtherPanes() }
        }
        .padding(.horizontal, 20)
        .padding(.leading, model.sidebarHidden ? T.lightsInset : 0)
        .frame(height: T.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
        .animation(M.snappy, value: even)
        .animation(M.snappy, value: n)
    }

    var header: some View {
        HStack(spacing: 10) {
            if let s = session, !s.isOrchestrator, let p = model.project(s.project), model.projects.count > 1 {
                Button { model.projectFilter = p.id; model.navigate(.sessions) } label: { Text(p.name).font(T.ui(13.5)).foregroundStyle(T.text2) }.buttonStyle(.plain)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.text3)
            }
            if let s = session {
                if s.isOrchestrator { Image(systemName: "sparkles").foregroundStyle(T.purple) } else { SessionIcon(session: s, size: 14) }
                if !s.issueKey.isEmpty && !s.title.hasPrefix(s.issueKey) { Text(s.issueKey).font(T.mono(12.5)).foregroundStyle(T.text3) }
                Text(s.isOrchestrator ? "Orchestrator" : s.title).font(T.ui(14, .semibold)).foregroundStyle(T.text).lineLimit(1)
                if model.isLive(s) && !model.isAwaiting(s) { LiveBadge().transition(.scale.combined(with: .opacity)) }
            } else {
                Text(run["who"].nonEmpty ?? id).font(T.ui(14, .semibold))
            }
            Spacer(minLength: 12)
            if let s = session {
                if model.isLive(s) {
                    Button { Task { await model.stop(id) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(LButton(danger: true))
                        .transition(.scale.combined(with: .opacity))
                }
                IconButton(icon: s.pinned ? "star.fill" : "star", help: s.pinned ? "Unpin" : "Pin to the sidebar") { Task { await model.setPinned(s.id, !s.pinned) } }
                Menu {
                    Button("Split Right") { model.splitRight() }.keyboardShortcut("\\")
                    Divider()
                    if !s.permalink.isEmpty { Button("Read the Slack Thread") { model.openThread(s.permalink) } }
                    SessionMenu(session: s, inChat: true)
                } label: { Image(systemName: "ellipsis").font(.system(size: 13.5)).foregroundStyle(T.text2).frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32)
            }
            IconButton(icon: "sidebar.right", help: model.inspectorShown ? "Hide details (⌥⌘I)" : "Show details (⌥⌘I)") {
                model.toggleDetails()
            }
        }
        .padding(.horizontal, 20)
        .padding(.leading, model.sidebarHidden ? T.lightsInset : 0)
        .frame(height: T.headerHeight)
        .animation(M.snappy, value: session.map(model.isLive) ?? false)
    }

    func title(of id: String) -> String {
        guard let s = model.sessions.first(where: { $0.id == id }) else { return id }
        return s.isOrchestrator ? "Orchestrator" : s.title
    }
}

struct StepButton: View {
    let icon: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? (hover.v ? T.text : T.text2) : T.text3.opacity(0.5))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover.v && enabled ? T.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.88))
        .disabled(!enabled)
        .help(help)
        .hoverBox(hover)
    }
}

struct SessionTabs: View {
    @Environment(AppModel.self) var model
    let runId: String
    let session: Session?
    /// A split pane's own strip: its tab, not the page's, and compact.
    var pane: Pane? = nil
    /// Too narrow for labels: tabs other than the current one are icons.
    var narrow = false
    @Namespace private var ns

    var current: String { pane?.tab ?? model.chatTab }

    var body: some View {
        let webTabs = model.browserTabs[runId] ?? []
        HStack(spacing: pane == nil ? 4 : 2) {
            tab("chat", icon: "bubble.left", label: "Chat")
            tab("changes", icon: "plusminus", label: "Changes")
            if model.terminalTabs.contains(runId) {
                tab("term", icon: "terminal", label: "Terminal", close: { model.closeTerminalTab(runId) })
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
            ForEach(webTabs) { t in
                WebSessionTab(page: model.web.page(for: t), on: current == "web-\(t.id)", ns: ns,
                              elsewhere: elsewhere("web-\(t.id)"), compact: pane != nil, iconOnly: narrow && current != "web-\(t.id)",
                              close: { model.closeBrowser(runId, t.id) },
                              action: { withAnimation(M.snappy) { model.showTab("web-\(t.id)", of: runId, in: pane?.id) } })
                    .onDrag { NSItemProvider(object: PanePayload.tab(runId, "web-\(t.id)") as NSString) }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
            newTabMenu
            Spacer()
        }
        .padding(.horizontal, pane == nil ? 16 : 8)
        .padding(.leading, pane == nil && model.sidebarHidden ? T.lightsInset : 0)
        .frame(height: pane == nil ? 42 : 34)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
        .animation(M.snappy, value: webTabs.map(\.id))
        .animation(M.snappy, value: model.terminalTabs.contains(runId))
    }

    /// Shown in another pane: the tab says so with a dot, and clicking it
    /// focuses that pane.
    func elsewhere(_ key: String) -> Bool {
        model.isSplit && current != key && model.panes.contains { $0.run == runId && $0.tab == key && $0.id != pane?.id }
    }

    func tab(_ key: String, icon: String, label: String, close: (() -> Void)? = nil) -> some View {
        let on = current == key
        return SessionTab(icon: icon, label: label, on: on, ns: ns, elsewhere: elsewhere(key), compact: pane != nil, iconOnly: narrow && !on, close: close) {
            withAnimation(M.snappy) { model.showTab(key, of: runId, in: pane?.id) }
        }
        .onDrag { NSItemProvider(object: PanePayload.tab(runId, key) as NSString) }
        .help("Drag to the edge of the chat to open it side by side")
    }

    var newTabMenu: some View {
        let s = session
        let ports = s.map { model.servers(for: $0) } ?? []
        return Menu {
            Section("Browser") {
                ForEach(ports) { sv in
                    ForEach(sv.ports, id: \.self) { p in
                        Button { model.openBrowser(runId, url: "http://localhost:\(p)") } label: { Label("localhost:\(p)  ·  \(sv.command)", systemImage: "play.circle") }
                    }
                }
                if let s, !s.prUrl.isEmpty { Button { model.openBrowser(runId, url: s.prUrl) } label: { Label("Pull request #\(s.prNumber)", systemImage: "arrow.triangle.pull") } }
                if let s, !s.linearUrl.isEmpty { Button { model.openBrowser(runId, url: s.linearUrl) } label: { Label("Linear issue", systemImage: "circle.lefthalf.filled") } }
                Button { model.openBrowser(runId, url: "") } label: { Label("New Browser Tab", systemImage: "globe") }
            }
            Section {
                Button { model.openTerminalTab(runId) } label: { Label("Terminal", systemImage: "terminal") }
                Button { model.splitRight() } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: pane == nil ? 11.5 : 10.5, weight: .semibold)).foregroundStyle(T.text2)
                .frame(width: pane == nil ? 28 : 24, height: pane == nil ? 28 : 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: pane == nil ? 32 : 28)
        .help("Open a tab: a browser on this session's dev server, its PR or any page")
    }
}

struct WebSessionTab: View {
    @ObservedObject var page: WebPage
    let on: Bool
    let ns: Namespace.ID
    var elsewhere = false
    var compact = false
    var iconOnly = false
    let close: () -> Void
    let action: () -> Void
    var body: some View {
        SessionTab(icon: page.loading ? "arrow.triangle.2.circlepath" : "globe", label: page.label, on: on, ns: ns, elsewhere: elsewhere, compact: compact, iconOnly: iconOnly, close: close, action: action)
    }
}

struct SessionTab: View {
    let icon: String
    let label: String
    let on: Bool
    let ns: Namespace.ID
    var elsewhere = false
    /// A split pane's strip: shorter tabs and labels.
    var compact = false
    var iconOnly = false
    var close: (() -> Void)? = nil
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let limit = compact ? 18 : 26
        HStack(spacing: compact ? 6 : 7) {
            Image(systemName: icon).font(.system(size: compact ? 10.5 : 11, weight: .medium))
                .overlay(alignment: .topTrailing) {
                    if elsewhere { Circle().fill(T.accent).frame(width: 5, height: 5).offset(x: 3, y: -2).transition(.scale) }
                }
            if !iconOnly {
                Text(label.count > limit ? label.prefix(limit - 1) + "…" : label).font(T.ui(compact ? 12 : 12.5, on ? .medium : .regular)).lineLimit(1).fixedSize()
                    .transition(.opacity)
            }
            if let close, !iconOnly {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text2)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(hover.v ? T.hover : .clear))
                }
                .buttonStyle(Pressable(scale: 0.85))
                .opacity(on || hover.v ? 1 : 0)
                .help("Close tab")
            }
        }
        .foregroundStyle(on ? T.text : T.text2)
        .padding(.leading, compact ? (iconOnly ? 9 : 10) : 12).padding(.trailing, close == nil || iconOnly ? (compact ? (iconOnly ? 9 : 10) : 12) : (compact ? 5 : 7))
        .frame(height: compact ? 26 : 30)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.selected)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.line, lineWidth: 1))
                    .matchedGeometryEffect(id: "session-tab", in: ns)
            } else if hover.v {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.hover.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .hoverBox(hover)
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            LiveIcon(size: 10)
            Text("Running").font(T.ui(11, .medium)).foregroundStyle(T.yellow).shimmer()
        }
        .padding(.horizontal, 7).frame(height: 20)
        .background(Capsule().fill(T.yellow.opacity(0.1)))
        .overlay(Capsule().stroke(T.yellow.opacity(0.25), lineWidth: 1))
    }
}

struct Transcript: View {
    @Environment(AppModel.self) var model
    let run: JSON
    let runId: String
    @StateObject private var holder = NavHolder()

    var body: some View {
        let messages = run["messages"].array
        let nav = holder.nav
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if run.isNull {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
                    } else if messages.isEmpty {
                        EmptyState(icon: "bubble.left", title: "Nothing here yet", detail: "Send a message below to start the session.")
                    }
                    ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                        MessageView(m: m, run: run, runId: runId)
                            .background(FlashMark(flash: nav.flash, index: i))
                            .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                    Color.clear.frame(height: 8).id("end")
                }
                .scrollTargetLayout()
                .animation(M.snappy, value: messages.count)
                .padding(.horizontal, 40).padding(.vertical, 28)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .scrollPosition(id: Binding(get: { nav.top }, set: { v in if nav.top != v { nav.top = v } }), anchor: .top)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24
            } action: { _, bottom in
                if nav.atBottom != bottom { nav.atBottom = bottom }
            }
            .onScrollPhaseChange { _, phase in if phase == .interacting { nav.scrolledByHand() } }
            .overlay(alignment: .topTrailing) {
                MessageStepper(nav: nav, list: nav.list, messages: messages)
                    .padding(.top, 14).padding(.trailing, 10)
            }
            .onAppear {
                nav.proxy = proxy
                model.messageNavs[runId] = nav
            }
            .onDisappear { if model.messageNavs[runId] === nav { model.messageNavs[runId] = nil } }
            .onChange(of: messages.count, initial: true) { nav.update(messages) }
        }
    }
}

struct MessageView: View {
    let m: JSON
    let run: JSON
    let runId: String

    var body: some View {
        switch m["role"].string {
        case "assistant": AssistantMessage(m: m, runId: runId)
        case "event", "outcome": EventLine(m: m)
        case "relay", "harness": HarnessMessage(m: m)
        default: UserMessage(m: m, run: run)
        }
    }
}

struct MessageHead: View {
    let name: String
    var detail: String = ""
    let ts: Double
    var body: some View {
        HStack(spacing: 7) {
            Text(name).font(T.ui(13, .semibold)).foregroundStyle(T.text)
            if !detail.isEmpty { Text(detail).font(T.ui(11.5)).foregroundStyle(T.text3) }
            Text(Fmt.clock(ts)).font(T.ui(11.5)).foregroundStyle(T.text3)
        }
    }
}

struct UserMessage: View {
    let m: JSON
    let run: JSON
    var body: some View {
        let role = m["role"].string
        let fromSlack = role == "slack" || role == "thread"
        let name = fromSlack ? (m["who"].nonEmpty ?? run["who"].nonEmpty ?? "Slack") : "You"
        HStack(alignment: .top, spacing: 14) {
            Avatar(name: name, size: 28)
            VStack(alignment: .leading, spacing: 6) {
                MessageHead(name: name, detail: fromSlack ? (run["channel"].nonEmpty.map { "in \($0)" } ?? "Slack") : "", ts: m["ts"].double)
                MarkdownText(text: fromSlack ? Session.plain(m["text"].string) : m["text"].string)
                if m["queued"].bool { Chip(text: "Queued", icon: "clock") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .messageActions(fromSlack ? Session.plain(m["text"].string) : m["text"].string)
    }
}

struct MessageActions: ViewModifier {
    @Environment(AppModel.self) var model
    let text: String
    @StateObject private var hover = Box(false)
    @StateObject private var copied = Box(false)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if hover.v && !text.isEmpty {
                    HStack(spacing: 2) {
                        IconButton(icon: copied.v ? "checkmark" : "doc.on.doc", help: "Copy") {
                            copyToPasteboard(text)
                            withAnimation(M.pop) { copied.v = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(M.hover) { copied.v = false } }
                        }
                        IconButton(icon: "text.quote", help: "Quote in your reply (select text and press ⌘L to quote just that)") { model.quoteIntoComposer(text) }
                    }
                    .padding(2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.line, lineWidth: 1))
                    .offset(y: -6)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                }
            }
            .hoverBox(hover)
    }
}

extension View {
    func messageActions(_ text: String) -> some View { modifier(MessageActions(text: text)) }
}

struct ClaudeMark: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.85, green: 0.47, blue: 0.34))
            .overlay(Image(systemName: "asterisk").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

struct AssistantMessage: View {
    let m: JSON
    let runId: String

    var body: some View {
        let state = m["state"].string
        let agent = AgentKind.of(m["agent"].string)
        HStack(alignment: .top, spacing: 14) {
            AgentMark(agent: agent)
            VStack(alignment: .leading, spacing: 10) {
                MessageHead(name: agent.label, detail: [m["label"].string, m["model"].string].filter { !$0.isEmpty }.joined(separator: " · "), ts: m["ts"].double)
                let steps = m["steps"].array
                if steps.isEmpty && !m["text"].string.isEmpty { MarkdownText(text: m["text"].string) }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in StepView(step: s, runId: runId) }
                footer(state)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .messageActions(replyText)
    }

    var replyText: String {
        let steps = m["steps"].array.filter { $0["kind"].string == "text" }.map { $0["text"].string }.filter { !$0.isEmpty }
        return steps.isEmpty ? m["text"].string : steps.joined(separator: "\n\n")
    }

    @ViewBuilder func footer(_ state: String) -> some View {
        if state == "running" {
            HStack(spacing: 7) { LiveIcon(size: 11); Text("Working…").font(T.ui(12)).foregroundStyle(T.text3).shimmer() }
        } else if state == "error" || state == "failed" {
            Label(m["error"].nonEmpty ?? "The session ended with an error", systemImage: "exclamationmark.triangle.fill")
                .font(T.ui(12)).foregroundStyle(T.red)
        } else if m["durationMs"].double > 0 || m["turns"].int > 0 {
            HStack(spacing: 10) {
                if m["durationMs"].double > 0 { Text(duration(m["durationMs"].double)) }
                if m["usage"]["output"].int > 0 { Text(verbatim: "\(Fmt.tokens(m["usage"]["output"].int)) out") }
                if m["turns"].int > 0 { Text(verbatim: "\(m["turns"].int) turns") }
                if m["acu"].double > 0 { Text(String(format: "%.2f ACUs", m["acu"].double)) }
                if state == "stopped" { Text("stopped").foregroundStyle(T.orange) }
            }
            .font(T.ui(11.5)).foregroundStyle(T.text3).monospacedDigit()
        }
    }

    func duration(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

struct StepView: View {
    let step: JSON
    let runId: String

    var body: some View {
        switch step["kind"].string {
        case "text":
            if !step["text"].string.isEmpty { MarkdownText(text: step["text"].string) }
        case "thinking":
            ThinkingView(step: step)
        case "tool":
            VStack(alignment: .leading, spacing: 8) {
                ToolView(step: step)
                if !step["ask"].isNull { AskCard(ask: step["ask"], runId: runId) }
            }
        default:
            EmptyView()
        }
    }
}

struct ThinkingView: View {
    let step: JSON
    @StateObject private var open = Box(false)
    var body: some View {
        let text = step["text"].string
        if step["streaming"].bool && text.isEmpty {
            HStack(spacing: 6) { Image(systemName: "brain").font(.system(size: 11)).symbolEffect(.pulse); Text("Thinking…").font(T.ui(12)).shimmer() }.foregroundStyle(T.text3)
        } else if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(M.snappy) { open.v.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain").font(.system(size: 11))
                        Text("Thought").font(T.ui(12))
                        if step["tokens"].int > 0 { Text(verbatim: "· \(Fmt.tokens(step["tokens"].int)) tokens").font(T.ui(12)) }
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open.v ? 90 : 0))
                    }
                    .foregroundStyle(T.text3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open.v {
                    Text(text).font(T.ui(12.5)).foregroundStyle(T.text2).textSelection(.enabled)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 2) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

struct ToolView: View {
    let step: JSON
    @StateObject private var open = Box(false)
    @StateObject private var hover = Box(false)

    var body: some View {
        let name = step["name"].string
        let result = step["result"].string
        let failed = step["ok"] == .bool(false)
        let raw = (try? JSONDecoder().decode(JSON.self, from: Data(step["raw"].string.utf8))) ?? .null
        if name == "TodoWrite" || name == "update_plan", !raw.isNull {
            TodoList(raw: raw)
        } else {
        VStack(alignment: .leading, spacing: 0) {
            Button { if !result.isEmpty { withAnimation(M.snappy) { open.v.toggle() } } } label: {
                HStack(spacing: 8) {
                    Image(systemName: ToolView.icon(name)).font(.system(size: 11)).foregroundStyle(T.text3).frame(width: 14)
                    Text(ToolView.display(name)).font(T.ui(12, .medium)).foregroundStyle(T.text2)
                    Text(step["detail"].string).font(T.mono(11.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if step["ok"].isNull && result.isEmpty && step["ask"].isNull {
                        EmptyView()
                    } else if failed {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(T.red)
                    } else if !result.isEmpty {
                        if step["resultLines"].int > 0 { Text(verbatim: "\(step["resultLines"].int) lines").font(T.ui(11)).foregroundStyle(T.text3) }
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
                            .rotationEffect(.degrees(open.v ? 90 : 0))
                    }
                }
                .padding(.horizontal, 10).frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if ["Edit", "MultiEdit", "Write"].contains(name), !raw.isNull {
                EditPreview(raw: raw).padding(.horizontal, 8).padding(.bottom, 8)
            }
            if open.v {
                Hairline()
                ScrollView {
                    Text(result).font(T.mono(11)).foregroundStyle(failed ? T.red : T.text2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 260)
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .background(RoundedRectangle(cornerRadius: 7).fill(hover.v ? T.hover.opacity(0.5) : T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.lineSoft, lineWidth: 1))
        .hoverBox(hover)
        }
    }

    static func display(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            return parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
        }
        return name
    }

    static func icon(_ name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "Task", "Agent": return "person.2"
        case "WebFetch", "WebSearch": return "globe"
        case "TodoWrite": return "checklist"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode": return "list.bullet.clipboard"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

struct EventLine: View {
    let m: JSON
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(T.lineSoft).frame(height: 1).frame(maxWidth: 40)
            Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(T.text3)
            Text(inline(m["text"].string)).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(3)
            Text(Fmt.clock(m["ts"].double)).font(T.ui(11)).foregroundStyle(T.text3.opacity(0.7))
            Rectangle().fill(T.lineSoft).frame(height: 1)
        }
        .padding(.leading, 38)
    }

    var icon: String {
        switch m["phase"].string {
        case "outcome": return "flag"
        case "spawned": return "arrow.triangle.branch"
        case "waiting": return "hourglass"
        default: return "circle.fill"
        }
    }
}

struct HarnessMessage: View {
    let m: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond").font(.system(size: 10.5))
                Text(m["role"].string == "relay" ? "Harness → orchestrator" : "Harness → worker").font(T.ui(11.5, .medium))
                if !m["label"].string.isEmpty { Text(verbatim: "· \(m["label"].string)").font(T.ui(11.5)) }
                Spacer()
                Text(Fmt.clock(m["ts"].double)).font(T.ui(11))
            }
            .foregroundStyle(T.text3)
            MarkdownText(text: m["text"].string.replacingOccurrences(of: #"^\[harness\]\s*"#, with: "", options: .regularExpression), size: 12.5, color: T.text2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(T.raised.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(.leading, 38)
    }
}

// MARK: - Asks

struct AskCard: View {
    @Environment(AppModel.self) var model
    let ask: JSON
    let runId: String
    @StateObject private var note = Box("")
    @StateObject private var picked = Box([String: Set<String>]())
    @StateObject private var busy = Box(false)

    var body: some View {
        let pending = ask["state"].string == "pending"
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: pending ? "hand.raised.fill" : ask["state"].string == "allowed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(pending ? T.orange : ask["state"].string == "allowed" ? T.green : T.red)
                Text(title).font(T.ui(13, .semibold)).foregroundStyle(T.text)
                Spacer()
            }
            if !pending {
                Text(ask["state"].string == "allowed" ? "Allowed\(answerSuffix)" : "Denied\(answerSuffix)").font(T.ui(12.5)).foregroundStyle(T.text2)
            } else if ask["tool"].string == "AskUserQuestion" {
                questions
            } else if ask["tool"].string == "ExitPlanMode" {
                ScrollView { MarkdownText(text: ask["plan"].string).padding(12) }
                    .frame(maxHeight: 360)
                    .background(RoundedRectangle(cornerRadius: 7).fill(T.panel))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.line, lineWidth: 1))
                decision(yes: "Approve and build", no: "Send back", why: "What to change about the plan (optional)")
            } else {
                if !ask["detail"].string.isEmpty {
                    Text(ask["detail"].string).font(T.mono(11.5)).foregroundStyle(T.text).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(T.panel))
                }
                if let why = ask["reason"].nonEmpty ?? ask["blockedPath"].nonEmpty.map({ "Outside the working directory: \($0)" }) {
                    Text(why).font(T.ui(12)).foregroundStyle(T.text2)
                }
                decision(yes: "Allow", no: "Deny", why: "What to do instead (optional)")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(pending ? T.orange.opacity(0.06) : T.raised.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pending ? T.orange.opacity(0.4) : T.line, lineWidth: 1))
        .disabled(busy.v)
    }

    var answerSuffix: String { ask["answer"].nonEmpty.map { ": \($0)" } ?? "" }

    var title: String {
        switch ask["tool"].string {
        case "AskUserQuestion": return "Claude has a question"
        case "ExitPlanMode": return "Plan ready for review"
        default: return "Allow \(ask["display"].nonEmpty ?? ask["tool"].string)?"
        }
    }

    func decision(yes: String, no: String, why: String) -> some View {
        HStack(spacing: 8) {
            LField(placeholder: why, text: $note.v)
            Button(no) { reply("deny") }.buttonStyle(LButton(danger: true))
            Button(yes) { reply("allow") }.buttonStyle(LButton(primary: true)).keyboardShortcut(.return, modifiers: [.command, .shift])
        }
    }

    var questions: some View {
        let qs = ask["questions"].array
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                let question = q["question"].string
                let multi = q["multiSelect"].bool
                // With several questions, every pick is held until Send, so one
                // click can't submit half the answers.
                let hold = multi || qs.count > 1
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if !q["header"].string.isEmpty { Chip(text: q["header"].string, tint: T.accent) }
                        Text(question).font(T.ui(13, .medium)).foregroundStyle(T.text)
                    }
                    ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, o in
                        let label = o["label"].string
                        let on = picked.v[question]?.contains(label) ?? false
                        Button {
                            if multi {
                                var set = picked.v[question] ?? []
                                if set.contains(label) { set.remove(label) } else { set.insert(label) }
                                picked.v[question] = set
                            } else if hold {
                                picked.v[question] = [label]
                            } else {
                                send([question: label])
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                                    .font(.system(size: 12)).foregroundStyle(on ? T.accent : T.text3).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label).font(T.ui(12.5, .medium)).foregroundStyle(T.text)
                                    if !o["description"].string.isEmpty { Text(o["description"].string).font(T.ui(12)).foregroundStyle(T.text2) }
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? T.accentSoft : T.panel))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? T.accent.opacity(0.5) : T.line, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                LField(placeholder: "Or answer in your own words…", text: $note.v) { sendTyped(qs) }
                Button("Send") { sendTyped(qs) }.buttonStyle(LButton(primary: true))
            }
        }
    }

    func sendTyped(_ qs: [JSON]) {
        if qs.count > 1, let missing = qs.first(where: { (picked.v[$0["question"].string] ?? []).isEmpty }), note.v.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.say("Answer \"\(missing["question"].string.prefix(60))\" too", bad: true)
        }
        var answers: [String: String] = [:]
        for q in qs {
            let question = q["question"].string
            let set = picked.v[question] ?? []
            let value = set.isEmpty ? note.v.trimmingCharacters(in: .whitespaces) : set.sorted().joined(separator: ", ")
            if !value.isEmpty { answers[question] = value }
        }
        guard !answers.isEmpty else { return model.say("Pick an option or type an answer", bad: true) }
        send(answers)
    }

    func send(_ answers: [String: String]) {
        busy.v = true
        Task { await model.answer(run: runId, askId: ask["id"].string, behavior: "allow", answers: answers); busy.v = false }
    }

    func reply(_ behavior: String) {
        busy.v = true
        Task { await model.answer(run: runId, askId: ask["id"].string, behavior: behavior, message: note.v); busy.v = false }
    }
}

// MARK: - Composer

struct JobOption {
    let key: String
    let label: String
    let icon: String
    let choices: [(String, String)]

    static let all: [JobOption] = [
        JobOption(key: "permissionMode", label: "Mode", icon: "lock.shield", choices: [("plan", "Plan mode"), ("manual", "Ask before acting"), ("acceptEdits", "Accept edits"), ("bypassPermissions", "Bypass permissions")]),
        JobOption(key: "model", label: "Model", icon: "cpu", choices: [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("fable", "Fable")]),
        JobOption(key: "effort", label: "Thinking", icon: "brain", choices: [("", "Auto"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "X-High"), ("max", "Max")]),
    ]
}

struct Composer: View {
    @Environment(AppModel.self) var model
    let runId: String
    @StateObject private var text = Box("")
    @StateObject private var sending = Box(false)
    @StateObject private var hasFocus = Box(false)
    @StateObject private var monitor = Box<Any?>(nil)
    @StateObject private var dropping = Box(false)
    @StateObject private var barWidth = Box<CGFloat>(800)
    @FocusState private var focused: Bool

    var items: [Attachment] { model.attachments[runId] ?? [] }

    var live: Bool { model.sessions.first { $0.id == runId }.map(model.isLive) ?? false }
    var trimmedEmpty: Bool { text.v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var draft: String { model.drafts[runId] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            attachmentStrip
            editor
            toolbar
        }
        .animation(M.snappy, value: items.map(\.id))
        .overlay { dropOverlay }
        .animation(M.hover, value: dropping.v)
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls {
                if u.isFileURL { add(.file(u)) } else { text.v += (text.v.isEmpty || text.v.hasSuffix(" ") ? "" : " ") + u.absoluteString }
            }
            return !urls.isEmpty
        } isTargeted: { dropping.v = $0 }
        .modifier(ComposerFrame(focused: focused))
        .onChange(of: focused) { hasFocus.v = focused }
        .onAppear {
            text.v = draft
            installPasteMonitor()
            ComposerSnapshots.run(model: model) { t in text.v = t }
        }
        .onDisappear { if let m = monitor.v { NSEvent.removeMonitor(m); monitor.v = nil } }
        .onChange(of: text.v) { if draft != text.v { model.drafts[runId] = text.v } }
        .onChange(of: draft) { if text.v != draft { text.v = draft } }
        .onChange(of: model.focusComposer, focusIfOpen)
    }

    @ViewBuilder var attachmentStrip: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { a in
                        AttachmentChip(item: a) { remove(a) }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 2)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    var editor: some View {
        PromptEditor(text: $text.v, placeholder: live ? "Queue a follow-up for when this turn ends…" : "Reply, paste an image, @ a file, # a session, / a skill…",
                     source: .run(runId), exclude: runId, focused: $focused) { a in
            if !items.contains(where: { $0.id == a.id }) { add(a) }
        }
        .padding(.horizontal, 12).padding(.top, 12)
    }

    var toolbar: some View {
        let agent = AgentKind.of(value("agent").string)
        return HStack(spacing: 4) {
            // Scrolls rather than overflowing in a narrow split pane.
            ScrollView(.horizontal, showsIndicators: false) { toolbarChips(agent) }
                .scrollBounceBehavior(.basedOnSize)
                // Fades out under the trailing controls instead of a hard cut.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            Spacer(minLength: 0)
            ContextButton(runId: runId, run: model.runData(runId), agent: agent, live: live)
            if live && !trimmedEmpty { stopAndSendButton }
            if barWidth.v > 620 { Text("⌘↩").font(T.ui(11)).foregroundStyle(T.text3).transition(.opacity) }
            sendButton
        }
        .padding(10)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth.v = $0 }
    }

    func toolbarChips(_ agent: AgentKind) -> some View {
        HStack(spacing: 4) {
            Button { pickFiles() } label: { ComposerChip(icon: "paperclip", text: "") }
                .buttonStyle(.plain).help("Attach images or files (or paste / drop them here)")
            AgentModelPicker(agent: agent, modelId: value(agent == .claude ? "model" : "agentModel").string, effort: value("effort").string,
                             pick: { a, m in pickModel(a, m, was: agent) }, setEffort: { e in Task { await model.setOpts(runId, ["effort": e]) } })
            AccessPicker(agent: agent, mode: value("permissionMode").string) { m in Task { await model.setOpts(runId, ["permissionMode": m]) } }
        }
    }

    var stopAndSendButton: some View {
        Button {
            let t = text.v
            sending.v = true
            Task {
                if await model.stopAndSend(t, to: runId), text.v == t { text.v = "" }
                sending.v = false
            }
        } label: { Label("Stop & send", systemImage: "bolt.fill").font(T.ui(11.5, .medium)) }
        .buttonStyle(LButton()).help("Interrupt the running turn and send this now (⌘↩ queues it instead)")
    }

    var sendButton: some View {
        let empty = trimmedEmpty && items.isEmpty
        return Button {
            send()
        } label: {
            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(empty ? T.text3.opacity(0.6) : T.accent))
                .shadow(color: T.accent.opacity(empty ? 0 : 0.5), radius: 6)
                .scaleEffect(empty ? 0.92 : 1)
                .animation(M.pop, value: empty)
        }
        .buttonStyle(Pressable(scale: 0.88))
        .keyboardShortcut(.return, modifiers: .command)
        // Covered by the New Task sheet or ⌘K: ⌘↩ belongs to them.
        // ⌘↩ belongs to the focused pane's composer when chats are side by side.
        .disabled(sending.v || model.composeOpen || model.paletteOpen || runId != model.openId)
    }

    @ViewBuilder var dropOverlay: some View {
        if dropping.v {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.accent.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .overlay(Label("Drop to attach", systemImage: "paperclip").font(T.ui(13, .medium)).foregroundStyle(T.accent))
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// ⌘L and friends focus the open chat's composer, not every pane's.
    func focusIfOpen() { if runId == model.openId { focused = true } }

    func value(_ key: String) -> JSON {
        let own = model.runData(runId)["opts"][key]
        return own.isNull ? model.config["followup"][key] : own
    }

    /// Agent and model change together. Switching agents mid-session hands
    /// the work over: the next agent's first turn opens with a briefing.
    func pickModel(_ a: AgentKind, _ m: String, was: AgentKind) {
        var patch: [String: Any] = ["agent": a.rawValue]
        patch[a == .claude ? "model" : "agentModel"] = m
        Task { await model.setOpts(runId, patch) }
        if a != was && model.runData(runId)["messages"].array.contains(where: { $0["role"].string == "assistant" }) {
            model.say("Next turn goes to \(a.label), with a handoff briefing")
        }
    }

    /// The draft is cleared only once the server has taken it, and only if
    /// you haven't typed something new in the meantime.
    func send() {
        let t = text.v
        let attached = items
        let full = Attachment.compose(t, attached)
        guard !full.isEmpty else { return }
        sending.v = true
        Task {
            if await model.send(full, to: runId) {
                if text.v == t { text.v = "" }
                model.attachments[runId]?.removeAll { a in attached.contains { $0.id == a.id } }
            }
            sending.v = false
        }
    }

    func add(_ a: Attachment?) {
        guard let a else { return }
        model.attachments[runId, default: []].append(a)
    }

    func remove(_ a: Attachment) { model.attachments[runId]?.removeAll { $0.id == a.id } }

    func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = "Attach"
        guard p.runModal() == .OK else { return }
        p.urls.forEach { add(.file($0)) }
    }

    func installPasteMonitor() {
        guard monitor.v == nil else { return }
        monitor.v = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak hasFocus] e in
            guard hasFocus?.v == true, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "v" else { return e }
            return handlePaste() ? nil : e
        }
    }

    func handlePaste() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach { add(.file($0)) }
            return true
        }
        let str = pb.string(forType: .string)
        if str == nil, let img = NSImage(pasteboard: pb) {
            add(.image(img))
            return true
        }
        if let str, Attachment.isLarge(str) {
            add(.pasted(str))
            return true
        }
        return false
    }
}

struct ComposerChip: View {
    let icon: String
    let text: String
    var warn = false
    @StateObject private var hover = Box(false)
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            if !text.isEmpty { Text(text).font(T.ui(12, .medium)) }
        }
        .foregroundStyle(warn ? T.orange : T.text2)
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover.v ? T.hover : .clear))
        .hoverBox(hover)
    }
}

// MARK: - Properties

// MARK: - Markdown

func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// Block-level Markdown the way a transcript needs it: paragraphs, headings,
/// lists, quotes and fenced code. Inline styling comes from AttributedString.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 13
    var color: Color = T.text

    enum Block: Hashable {
        case para(String), heading(Int, String), bullet(String, Int), numbered(String, String), quote(String), code(String, String), rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownText.parse(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
        .tint(T.accent)
    }

    @ViewBuilder func block(_ b: Block) -> some View {
        switch b {
        case .para(let s):
            Text(inline(s)).font(T.ui(size)).foregroundStyle(color).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(inline(s)).font(T.ui(level == 1 ? size + 4 : level == 2 ? size + 2 : size + 0.5, .semibold)).foregroundStyle(T.text).padding(.top, 4)
        case .bullet(let s, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(T.ui(size)).foregroundStyle(T.text3)
                Text(inline(s)).font(T.ui(size)).foregroundStyle(color).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).font(T.ui(size)).foregroundStyle(T.text3).monospacedDigit()
                Text(inline(s)).font(T.ui(size)).foregroundStyle(color).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let s):
            Text(inline(s)).font(T.ui(size)).foregroundStyle(T.text2)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 2) }
        case .code(let lang, let s):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    HStack {
                        Text(lang).font(T.ui(11)).foregroundStyle(T.text3)
                        Spacer()
                        Button { copyToPasteboard(s) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10.5)).foregroundStyle(T.text3) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.top, 7)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(s).font(T.mono(11.5)).foregroundStyle(T.text).padding(10)
                }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(T.bg))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.lineSoft, lineWidth: 1))
        case .rule:
            Hairline()
        }
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        var lang = ""
        func flush() {
            if !para.isEmpty { out.append(.para(para.joined(separator: "\n"))); para = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let t = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if t.hasPrefix("```") { out.append(.code(lang, code!.joined(separator: "\n"))); code = nil } else { code!.append(line) }
                continue
            }
            if t.hasPrefix("```") { flush(); lang = String(t.dropFirst(3)); code = []; continue }
            if t.isEmpty { flush(); continue }
            if t == "---" || t == "***" { flush(); out.append(.rule); continue }
            if let r = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                out.append(.heading(t[r].filter { $0 == "#" }.count, String(t[r.upperBound...])))
                continue
            }
            if let r = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                flush()
                let indent = line.prefix { $0 == " " }.count / 2
                out.append(.bullet(String(line[r.upperBound...]), min(indent, 3)))
                continue
            }
            if let r = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                out.append(.numbered(String(t[r].trimmingCharacters(in: .whitespaces)), String(t[r.upperBound...])))
                continue
            }
            if t.hasPrefix(">") { flush(); out.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            para.append(line)
        }
        if let code { out.append(.code(lang, code.joined(separator: "\n"))) }
        flush()
        return out
    }
}


private struct ComposerFrame: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(focused ? T.accent.opacity(0.6) : T.line, lineWidth: 1))
            .shadow(color: focused ? T.accent.opacity(0.18) : .black.opacity(0.2), radius: focused ? 10 : 6, y: 2)
            .animation(M.hover, value: focused)
            .padding(.horizontal, 32).padding(.bottom, 20).padding(.top, 8)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
    }
}
