import AppKit
import SwiftUI

// MARK: - Open in…
//
// The chat header's split button: the icon opens the session in your last
// pick, the chevron lists every place it can go. VS Code and Finder open the
// session's folder (there's no Cursor target, by choice); GitHub its PR (else its branch); Linear its issue; Slack
// its thread, or the thread its Linear issue links.

enum OpenTarget: String, CaseIterable, Identifiable {
    case vscode, finder, github, linear, slack
    var id: String { rawValue }

    var label: String {
        switch self {
        case .vscode: return "VS Code"
        case .finder: return "Finder"
        case .github: return "GitHub"
        case .linear: return "Linear"
        case .slack: return "Slack"
        }
    }

    /// The app a target opens in, when it's an app (editors, Finder) or has one (Linear, Slack).
    var bundleIds: [String] {
        switch self {
        case .vscode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]
        case .finder: return ["com.apple.finder"]
        case .github: return ["com.github.GitHubClient"]
        case .linear: return ["com.linear"]
        case .slack: return ["com.tinyspeck.slackmacgap"]
        }
    }

    var symbol: String {
        switch self {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .finder: return "folder"
        case .github: return "arrow.triangle.pull"
        case .linear: return "circle.lefthalf.filled"
        case .slack: return "number"
        }
    }

    var appURL: URL? {
        for b in bundleIds { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return u } }
        return nil
    }

    /// The real app icon when it's installed (what Paseo and Xcode show), else a symbol.
    var icon: NSImage {
        if let u = appURL {
            let i = NSWorkspace.shared.icon(forFile: u.path)
            i.size = NSSize(width: 16, height: 16)
            return i
        }
        let i = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        i.isTemplate = true
        return i
    }

    var isEditor: Bool { self == .vscode }
}

/// Where one session can be opened, and the URLs/folders behind each target.
struct OpenPlaces {
    let folder: String
    let github: String
    let linear: String
    let slack: String

    @MainActor init(session s: Session, model: AppModel) {
        let issue = model.linkedIssue(s)
        let dir = s.isOrchestrator ? (model.project(s.project)?.path ?? "") : s.worktree.isEmpty ? (model.project(s.project)?.path ?? "") : s.worktree
        folder = FileManager.default.fileExists(atPath: dir) ? dir : ""
        github = !s.prUrl.isEmpty ? s.prUrl : OpenPlaces.branchURL(folder: folder, branch: s.branch)
        linear = s.linearUrl.isEmpty ? (issue?.url ?? "") : s.linearUrl
        slack = s.permalink.isEmpty ? (issue?.slackUrl ?? "") : s.permalink
    }

    func available(_ t: OpenTarget) -> Bool {
        switch t {
        case .vscode: return !folder.isEmpty && t.appURL != nil
        case .finder: return !folder.isEmpty
        case .github: return !github.isEmpty
        case .linear: return !linear.isEmpty
        case .slack: return !slack.isEmpty
        }
    }

    var targets: [OpenTarget] { OpenTarget.allCases.filter(available) }

    @MainActor func open(_ t: OpenTarget, model: AppModel) {
        switch t {
        case .vscode:
            guard let app = t.appURL else { return }
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
        case .github:
            openURL(github)
        case .linear:
            // The Linear app takes its own links; the browser is the fallback.
            if let app = t.appURL, let u = URL(string: linear) {
                NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else { openURL(linear) }
        case .slack:
            // A Slack permalink hands itself to the desktop app when it's installed.
            openURL(slack)
        }
        UserDefaults.standard.set(t.rawValue, forKey: "openInTarget")
        model.say("Opened in \(t.label)")
    }

    /// The branch on the remote's web page, from the folder's `origin`.
    static var remotes: [String: String] = [:]
    static func branchURL(folder: String, branch: String) -> String {
        guard !folder.isEmpty else { return "" }
        let base: String
        if let cached = remotes[folder] { base = cached } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", folder, "remote", "get-url", "origin"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            base = webURL(remote: raw)
            remotes[folder] = base
        }
        guard !base.isEmpty else { return "" }
        return branch.isEmpty ? base : "\(base)/tree/\(branch)"
    }

    static func webURL(remote: String) -> String {
        var r = remote
        if r.hasPrefix("git@") { r = "https://" + r.dropFirst(4).replacingOccurrences(of: ":", with: "/") }
        if r.hasPrefix("ssh://git@") { r = "https://" + r.dropFirst(10) }
        if let at = r.range(of: #"https://[^@/]+@"#, options: .regularExpression) { r.replaceSubrange(at, with: "https://") }
        if r.hasSuffix(".git") { r = String(r.dropLast(4)) }
        return r.hasPrefix("https://") ? r : ""
    }
}

struct OpenInButton: View {
    @Environment(AppModel.self) var model
    let session: Session
    @StateObject private var hover = Box(false)

    var body: some View {
        let places = OpenPlaces(session: session, model: model)
        let targets = places.targets
        if !targets.isEmpty {
            let saved = OpenTarget(rawValue: UserDefaults.standard.string(forKey: "openInTarget") ?? "")
            let main = saved.flatMap { targets.contains($0) ? $0 : nil } ?? targets.first(where: \.isEditor) ?? targets[0]
            HStack(spacing: 0) {
                Button { places.open(main, model: model) } label: {
                    Image(nsImage: main.icon).resizable().interpolation(.high)
                        .renderingMode(main.appURL == nil ? .template : .original)
                        .foregroundStyle(T.text2)
                        .frame(width: 16, height: 16)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Pressable(scale: 0.9))
                .help("Open in \(main.label)")
                Rectangle().fill(T.line).frame(width: 1, height: 16)
                Menu {
                    Section("Open in") {
                        ForEach(OpenTarget.allCases) { t in
                            Button { places.open(t, model: model) } label: {
                                Label { Text(t.label) } icon: { Image(nsImage: t.icon) }
                            }
                            .disabled(!places.available(t))
                        }
                    }
                    if !places.folder.isEmpty {
                        Section {
                            Button { ConsoleStore.shared.add(places.folder) } label: { Label("Open in Integrated Terminal", systemImage: "terminal") }
                            Button { copyToPasteboard(places.folder); model.say("Copied the path") } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(T.text3)
                        .frame(width: 22, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .help("Open in…")
            }
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.v ? T.hover : T.raised.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.line, lineWidth: 1))
            .hoverBox(hover)
            .fixedSize()
        }
    }
}

/// The same places as a submenu, for right-click and a pane's ⋯ menu.
struct OpenInMenu: View {
    @Environment(AppModel.self) var model
    let session: Session

    var body: some View {
        let places = OpenPlaces(session: session, model: model)
        if !places.targets.isEmpty {
            Menu {
                ForEach(OpenTarget.allCases) { t in
                    Button { places.open(t, model: model) } label: { Label { Text(t.label) } icon: { Image(nsImage: t.icon) } }
                        .disabled(!places.available(t))
                }
                if !places.folder.isEmpty {
                    Divider()
                    Button { ConsoleStore.shared.add(places.folder) } label: { Label("Integrated Terminal", systemImage: "terminal") }
                }
            } label: { Label("Open In", systemImage: "arrow.up.forward.app") }
        }
    }
}
