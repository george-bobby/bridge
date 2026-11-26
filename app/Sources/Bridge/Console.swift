import AppKit
import SwiftTerm
import SwiftUI

// MARK: - Terminal panel
//
// VS Code's integrated terminal: a panel along the bottom of the window with
// any number of plain login shells, toggled with ⌃` (⌘J hides or shows the
// panel, ⌃⇧` adds a shell). A new shell starts in the folder of what's on
// screen: the open session's worktree, else the filtered project, else the
// default workdir. Unlike a chat's Terminal tab it never resumes an agent.

@MainActor
final class Shell: ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID().uuidString
    let view = BridgeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 260))
    @Published var title = ""
    @Published var dir: String
    weak var store: ConsoleStore?

    init(dir: String, store: ConsoleStore) {
        self.dir = dir
        self.store = store
        view.processDelegate = self
        let shell = TermSession.shell
        view.startProcess(executable: shell, args: ["-l", "-i"], environment: TermSession.environment(),
                          execName: "-" + URL(fileURLWithPath: shell).lastPathComponent, currentDirectory: dir)
    }

    var label: String {
        if !title.isEmpty { return title }
        let name = URL(fileURLWithPath: TermSession.shell).lastPathComponent
        return dir == NSHomeDirectory() ? name : "\(name) · \(URL(fileURLWithPath: dir).lastPathComponent)"
    }

    func kill() { view.terminate() }

    /// VS Code's Clear: wipe the buffer and scrollback, and let the shell redraw its prompt.
    func clear() {
        view.getTerminal().resetToInitialState()
        view.send(txt: "\u{0C}")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { self.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let d = directory, !d.isEmpty else { return }
        dir = d.hasPrefix("file://") ? (URL(string: d)?.path ?? d) : d
    }
    /// A shell that exits closes its tab, as in VS Code.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.store?.remove(self.id) }
    }
}

@MainActor
final class ConsoleStore: ObservableObject {
    static let shared = ConsoleStore()

    @Published var open = false
    @Published var maximized = false
    @Published var shells: [Shell] = []
    @Published var current: String? = nil
    @Published var height: CGFloat = {
        let h = UserDefaults.standard.double(forKey: "console.height")
        return h > 0 ? h : 280
    }() {
        didSet { UserDefaults.standard.set(Double(height), forKey: "console.height") }
    }

    var active: Shell? { shells.first { $0.id == current } ?? shells.last }

    /// The panel's terminal holds the keyboard.
    var focused: Bool {
        guard open, let r = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        return shells.contains { r === $0.view || r.isDescendant(of: $0.view) }
    }

    /// ⌃`: open the panel and focus its terminal; from inside the terminal, hide it.
    func toggle(_ model: AppModel) {
        if focused { return hide(model) }
        if shells.isEmpty { return add(model.contextFolder) }
        show()
    }

    /// ⌘J: the panel itself, focus aside.
    func togglePanel(_ model: AppModel) {
        if open { hide(model) } else if shells.isEmpty { add(model.contextFolder) } else { show() }
    }

    func show() {
        withAnimation(M.snappy) { open = true }
        focus()
    }

    func hide(_ model: AppModel) {
        let had = focused
        withAnimation(M.snappy) { open = false; maximized = false }
        if had {
            NSApp.keyWindow?.makeFirstResponder(nil)
            if model.isChatRoute { model.focusComposer += 1 }
        }
    }

    /// A new shell in `dir`, shown and focused.
    func add(_ dir: String) {
        let path = FileManager.default.fileExists(atPath: dir) ? dir : NSHomeDirectory()
        let s = Shell(dir: path, store: self)
        withAnimation(M.snappy) {
            shells.append(s)
            current = s.id
        }
        show()
    }

    func select(_ id: String) {
        current = id
        focus()
    }

    func kill(_ id: String? = nil) {
        guard let s = id.flatMap({ i in shells.first { $0.id == i } }) ?? active else { return }
        s.store = nil
        s.kill()
        remove(s.id)
    }

    func remove(_ id: String) {
        guard let i = shells.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(M.snappy) {
            shells.remove(at: i)
            if current == id { current = shells.indices.contains(i) ? shells[i].id : shells.last?.id }
            if shells.isEmpty { open = false; maximized = false }
        }
        if open { focus() }
    }

    func step(_ d: Int) {
        guard let s = active, let i = shells.firstIndex(where: { $0.id == s.id }), shells.count > 1 else { return }
        select(shells[(i + d + shells.count) % shells.count].id)
    }

    func toggleMaximized() { withAnimation(M.snappy) { maximized.toggle() } }

    /// The view lands in the window a beat after the panel appears.
    func focus(_ tries: Int = 6) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.open, let s = self.active else { return }
            if let w = s.view.window { w.makeFirstResponder(s.view) } else if tries > 0 { self.focus(tries - 1) }
        }
    }
}

extension AppModel {
    /// Where a new shell starts: the open session's folder, else the
    /// filtered project's, else the default workdir, else home.
    var contextFolder: String {
        let fm = FileManager.default
        if case .session(let id) = route, let s = sessions.first(where: { $0.id == id }) {
            let dir = s.isOrchestrator || s.worktree.isEmpty ? (project(s.project)?.path ?? "") : s.worktree
            if !dir.isEmpty, fm.fileExists(atPath: dir) { return dir }
        }
        if let p = projectFilter.flatMap(project), fm.fileExists(atPath: p.path) { return p.path }
        if !defaultWorkdir.isEmpty, fm.fileExists(atPath: defaultWorkdir) { return defaultWorkdir }
        return NSHomeDirectory()
    }
}

// MARK: - Layout

/// The page with the terminal panel under it.
struct Workbench<Content: View>: View {
    @ObservedObject var console = ConsoleStore.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let room = max(0, geo.size.height - 140)
            VStack(spacing: 0) {
                content()
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .opacity(console.open && console.maximized ? 0 : 1)
                if console.open {
                    ConsolePanel(console: console, room: room)
                        .frame(height: console.maximized ? geo.size.height : min(max(console.height, 120), room))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(M.snappy, value: console.open)
        .animation(M.snappy, value: console.maximized)
    }
}

struct ConsolePanel: View {
    @ObservedObject var console: ConsoleStore
    let room: CGFloat
    @Environment(AppModel.self) var model
    @StateObject private var dragStart = Box<CGFloat?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ZStack {
                T.panel
                if let s = console.active {
                    TerminalHost(view: s.view)
                        .padding(.leading, 12).padding(.top, 6).padding(.bottom, 4)
                }
            }
        }
        .background(T.panel)
        .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
        .overlay(alignment: .top) { grip }
    }

    /// The top edge: drag to resize, double-click to maximize.
    var grip: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if dragStart.v == nil { dragStart.v = console.maximized ? room : min(console.height, room) }
                        if console.maximized { console.maximized = false }
                        console.height = min(max((dragStart.v ?? 0) - g.translation.height, 120), room)
                    }
                    .onEnded { _ in dragStart.v = nil }
            )
            .onTapGesture(count: 2) { console.toggleMaximized() }
    }

    var header: some View {
        HStack(spacing: 6) {
            Text("TERMINAL").font(T.ui(10.5, .semibold)).tracking(0.6).foregroundStyle(T.text2)
                .padding(.trailing, 6)
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(console.shells) { s in
                        ConsoleTab(shell: s, on: s.id == console.active?.id,
                                   select: { console.select(s.id) }, close: { console.kill(s.id) })
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 8)
            IconButton(icon: "plus", help: "New Terminal (⌃⇧`)", size: 24) { console.add(model.contextFolder) }
            IconButton(icon: "trash", help: "Kill Terminal", size: 24) { console.kill() }
            IconButton(icon: console.maximized ? "chevron.down" : "chevron.up", help: console.maximized ? "Restore Panel Size" : "Maximize Panel Size", size: 24) {
                console.toggleMaximized()
            }
            IconButton(icon: "xmark", help: "Hide Panel (⌘J)", size: 24) { console.hide(model) }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 34)
    }
}

struct ConsoleTab: View {
    @ObservedObject var shell: Shell
    let on: Bool
    let select: () -> Void
    let close: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 10.5, weight: .medium)).foregroundStyle(on ? T.text : T.text3)
            Text(shell.label).font(T.ui(11.5, on ? .medium : .regular)).foregroundStyle(on ? T.text : T.text2).lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover.v || on ? 1 : 0)
            .help("Kill Terminal")
        }
        .padding(.leading, 9).padding(.trailing, 5)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? T.selected : hover.v ? T.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .hoverBox(hover)
        .help(shell.dir)
    }
}
