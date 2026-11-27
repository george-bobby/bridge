import AppKit
import SwiftTerm
import SwiftUI

// MARK: - Terminal tab
//
// The session, continued inside the app: SwiftTerm's LocalProcessTerminalView
// runs the server's resume command (GET /api/runs/:id/terminal) in the
// user's login shell, in the session's folder. One terminal per session, kept alive in
// `TermStore` while its tab is open, so switching tabs or panes never kills it.

@MainActor
final class TermSession: ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let runId: String
    let view: BridgeTerminalView
    @Published var state: State = .loading
    @Published var title = ""
    @Published var command = ""
    @Published var workdir = ""

    enum State: Equatable { case loading, busy, running, exited(Int32?), failed(String) }

    init(runId: String) {
        self.runId = runId
        view = BridgeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.processDelegate = self
    }

    /// Ask the server for the command, then run it. A headless job holding
    /// the session means waiting: two processes resuming one session id
    /// corrupt it.
    func start() async {
        state = .loading
        do {
            let info = try await API.get("/api/runs/\(API.q(runId))/terminal")
            command = info["command"].string
            workdir = info["workdir"].string
            if info["running"].bool { state = .busy; return }
            launch(path: info["path"].string)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func launch(path: String) {
        let shell = Self.shell
        // Run the session, then stay in a shell in its folder once it exits.
        let line = command.isEmpty ? "exec \(shell) -l" : "\(command); exec \(shell) -l"
        let dir = FileManager.default.fileExists(atPath: workdir) ? workdir : NSHomeDirectory()
        view.startProcess(executable: shell, args: ["-l", "-i", "-c", line], environment: Self.environment(path: path),
                          execName: "-" + URL(fileURLWithPath: shell).lastPathComponent, currentDirectory: dir)
        state = .running
        DispatchQueue.main.async { self.view.window?.makeFirstResponder(self.view) }
    }

    nonisolated static var shell: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// The app's environment minus its secrets and snapshot knobs, dressed
    /// for a 256-colour terminal; `path` goes in front of PATH.
    nonisolated static func environment(path: String = "") -> [String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["ACP_BACKEND", "LINEAR_API_KEY", "SLACK_USER_TOKEN", "VERCEL_TOKEN", "INCIDENT_API_KEY", "GRANOLA_API_KEY", "DD_API_KEY", "DD_APP_KEY", "BRIDGE_APPEARANCE"] { env[k] = nil }
        for k in env.keys where k.hasPrefix("BRIDGE_SNAPSHOT") { env[k] = nil }
        if !path.isEmpty { env["PATH"] = path + ":" + (env["PATH"] ?? "/usr/bin:/bin") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Bridge"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// A restart's own kill must not mark the new process exited.
    private var ignoreExits = 0

    func restart() {
        if state == .running { ignoreExits += 1; view.terminate() }
        view.getTerminal().resetToInitialState()
        Task { await start() }
    }

    func stop() { if state == .running { view.terminate() } }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { self.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            if self.ignoreExits > 0 { self.ignoreExits -= 1; return }
            self.state = .exited(exitCode)
        }
    }
}

@MainActor
final class TermStore {
    private var sessions: [String: TermSession] = [:]

    func session(for runId: String) -> TermSession {
        if let s = sessions[runId] { return s }
        let s = TermSession(runId: runId)
        sessions[runId] = s
        return s
    }

    func drop(_ runId: String) {
        sessions[runId]?.stop()
        sessions[runId] = nil
    }
}

/// The terminal, dressed in the app's palette and monospaced font, and
/// re-dressed when the appearance flips.
final class BridgeTerminalView: LocalProcessTerminalView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        optionAsMetaKey = true
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        func ns(_ c: SwiftUI.Color) -> NSColor {
            var out = NSColor(c)
            effectiveAppearance.performAsCurrentDrawingAppearance { out = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c) }
            return out
        }
        font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        nativeBackgroundColor = ns(T.panel)
        nativeForegroundColor = ns(T.text)
        caretColor = ns(T.accent)
        selectedTextBackgroundColor = ns(T.accent).withAlphaComponent(0.35)
        layer?.backgroundColor = nativeBackgroundColor.cgColor
        // ANSI 16, tuned to the palette: T's accents for the bright half.
        let hex: [UInt32] = dark
            ? [0x18181B, 0xEB5757, 0x4CB878, 0xF2C94C, 0x5E6AD2, 0x8C6BF2, 0x4EA7C8, 0x9A9AA3,
               0x5F5F68, 0xF07A7A, 0x6FD196, 0xF5D77A, 0x8B94E6, 0xAC93F5, 0x7CC4DD, 0xEDEDEF]
            : [0x1B1B1F, 0xC9373A, 0x2E8A55, 0xA87A12, 0x4A55C0, 0x7550D8, 0x2C7E9C, 0x5C5C66,
               0x9A9AA3, 0xE04B4F, 0x3BA168, 0xC59420, 0x5E6AD2, 0x8C6BF2, 0x3B97B8, 0xF4F4F6]
        installColors(hex.map { v in
            SwiftTerm.Color(red: UInt16((v >> 16) & 0xFF) * 257, green: UInt16((v >> 8) & 0xFF) * 257, blue: UInt16(v & 0xFF) * 257)
        })
    }
}

struct TerminalHost: NSViewRepresentable {
    let view: BridgeTerminalView
    func makeNSView(context: Context) -> NSView {
        // A plain container, so the terminal can move between panes (SwiftUI
        // drops the old host before making the new one).
        let box = NSView()
        box.wantsLayer = true
        attach(view, to: box)
        return box
    }
    func updateNSView(_ box: NSView, context: Context) {
        if view.superview !== box { attach(view, to: box) }
    }
    private func attach(_ v: NSView, to box: NSView) {
        v.removeFromSuperview()
        v.frame = box.bounds
        v.autoresizingMask = [.width, .height]
        box.addSubview(v)
    }
}

struct TerminalTab: View {
    @Environment(AppModel.self) var model
    let runId: String

    var body: some View {
        TerminalPane(session: model.terms.session(for: runId), runId: runId)
    }
}

struct TerminalPane: View {
    @Environment(AppModel.self) var model
    @ObservedObject var session: TermSession
    let runId: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(T.text3)
                Text(session.workdir.isEmpty ? "Terminal" : (session.workdir as NSString).abbreviatingWithTildeInPath)
                    .font(T.mono(11.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.head)
                if !session.title.isEmpty {
                    Text(session.title).font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
                }
                Spacer()
                IconButton(icon: "doc.on.doc", help: "Copy the resume command") {
                    copyToPasteboard(session.command); model.say("Command copied")
                }
                IconButton(icon: "arrow.clockwise", help: "Restart the session here") { session.restart() }
            }
            .padding(.horizontal, 14).frame(height: 40)
            Hairline()
            ZStack {
                T.panel
                TerminalHost(view: session.view)
                    .padding(.leading, 12).padding(.top, 8).padding(.bottom, 4)
                    .opacity(session.state == .running || isExited ? 1 : 0)
                overlay.transition(.opacity)
            }
            .animation(M.page, value: session.state)
        }
        .task {
            if session.state == .loading { await session.start() }
        }
        .onChange(of: model.running.contains(runId)) {
            if !model.running.contains(runId), session.state == .busy { Task { await session.start() } }
        }
    }

    var isExited: Bool { if case .exited = session.state { return true }; return false }

    @ViewBuilder var overlay: some View {
        switch session.state {
        case .loading:
            ProgressView().controlSize(.small)
        case .busy:
            notice(icon: "hourglass", title: "A job is running in this chat",
                   detail: "Two processes on one session corrupt it. Stop the job to continue here; the terminal starts when it ends.") {
                Button { Task { await model.stop(runId) } } label: { Label("Stop the job", systemImage: "stop.fill") }.buttonStyle(LButton(danger: true))
            }
        case .failed(let why):
            notice(icon: "exclamationmark.triangle", title: "Couldn't start the terminal", detail: why) {
                Button { session.restart() } label: { Label("Try again", systemImage: "arrow.clockwise") }.buttonStyle(LButton())
            }
        case .exited(let code):
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Text(code.map { "Exited with code \($0)" } ?? "Exited").font(T.ui(12)).foregroundStyle(T.text2)
                    Button { session.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }.buttonStyle(LButton(primary: true))
                    Button("Close Tab") { model.closeTerminalTab(runId) }.buttonStyle(LButton())
                }
                .padding(.horizontal, 14).frame(height: 44)
                .floatingPanel()
                .padding(16)
            }
        case .running:
            EmptyView()
        }
    }

    func notice<A: View>(icon: String, title: String, detail: String, @ViewBuilder action: () -> A) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 24, weight: .light)).foregroundStyle(T.text3)
                .frame(width: 56, height: 56).background(Circle().fill(T.raised.opacity(0.6)))
            Text(title).font(T.ui(14, .medium)).foregroundStyle(T.text)
            Text(detail).font(T.ui(12.5)).foregroundStyle(T.text2).multilineTextAlignment(.center).frame(maxWidth: 380)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
