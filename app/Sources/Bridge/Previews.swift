import SwiftUI

// MARK: - Preview deployments
//
// A PR's Vercel / Netlify preview, from the pulls feed (`previews` on each PR,
// server/previews.js) or the details panel's PR activity. Clicking one opens
// it in a browser tab of the session working on that PR; the context menu has
// the default browser and copy.

struct PreviewDeploy: Identifiable, Hashable {
    let j: JSON
    var id: String { url }
    var url: String { j["url"].string }
    var provider: String { j["provider"].string }
    var state: String { j["state"].string }
    var env: String { j["env"].string }
    var ready: Bool { state == "ready" || state.isEmpty }
    var building: Bool { state == "building" }
    var failed: Bool { state == "failed" }
    var host: String { URL(string: url)?.host ?? url }
    var name: String { provider == "vercel" ? "Vercel" : provider == "netlify" ? "Netlify" : "Preview" }
    var stateLabel: String { building ? "Building" : failed ? "Failed" : "Ready" }
    var stateTint: Color { building ? T.orange : failed ? T.red : T.green }
}

extension PullRequest {
    var previews: [PreviewDeploy] { j["previews"].array.map(PreviewDeploy.init).filter { !$0.url.isEmpty } }
    /// The one to show when there's room for one: a ready preview first.
    var preview: PreviewDeploy? { previews.first { $0.ready } ?? previews.first }
}

extension AppModel {
    /// Previews for a session: the details panel's fresher PR activity, else the pulls feed.
    func previews(for s: Session) -> [PreviewDeploy] {
        guard !s.prUrl.isEmpty else { return [] }
        let live = prActivity[s.prUrl]?["previews"].array.map(PreviewDeploy.init).filter { !$0.url.isEmpty } ?? []
        return live.isEmpty ? pr(for: s.prUrl)?.previews ?? [] : live
    }

    /// Opens a preview in the built-in browser of the session working on it
    /// (reusing a tab already on that URL), or the default browser when no
    /// session has the PR.
    func openPreview(_ url: String, run: String?) {
        guard let run, !run.isEmpty else { return openURL(url) }
        if route != .session(run) { open(run) }
        if let tab = browserTabs[run]?.first(where: { $0.url == url }) { return showTab("web-\(tab.id)", of: run) }
        openBrowser(run, url: url)
    }
}

/// Vercel's triangle, Netlify's diamond, a globe for anything else.
struct PreviewGlyph: View {
    let provider: String
    var size: CGFloat = 10
    var body: some View {
        Image(systemName: provider == "vercel" ? "triangle.fill" : provider == "netlify" ? "diamond.fill" : "globe")
            .font(.system(size: provider == "vercel" ? size * 0.85 : size, weight: .semibold))
    }
}

/// A compact preview link: glyph plus a word ("Preview", "Building"). In the
/// sidebar's PR line, PR rows and board cards.
struct PreviewChip: View {
    @Environment(AppModel.self) var model
    let preview: PreviewDeploy
    var run: String? = nil
    var size: CGFloat = 11.5
    var boxed = false
    /// Glyph only, for the sidebar's tight PR line.
    var compact = false
    @StateObject private var hover = Box(false)

    var body: some View {
        Button { model.openPreview(preview.url, run: run) } label: {
            HStack(spacing: 3) {
                PreviewGlyph(provider: preview.provider, size: size - 2)
                if !compact { Text(preview.building ? "Building" : preview.failed ? "Failed" : "Preview").font(T.ui(size)) }
            }
            .foregroundStyle(preview.ready ? (hover.v ? T.text : T.text2) : preview.stateTint)
            .padding(.horizontal, boxed ? 7 : 0)
            .frame(height: boxed ? 22 : nil)
            .background(RoundedRectangle(cornerRadius: 5).fill(boxed && hover.v ? T.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(boxed ? T.line : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.92))
        .fixedSize()
        .hoverBox(hover)
        .help("\(preview.name) preview · \(preview.stateLabel)\n\(preview.url)\n\(run == nil ? "Click to open" : "Click to open in Bridge's browser")")
        .contextMenu { PreviewMenu(preview: preview, run: run) }
    }
}

struct PreviewMenu: View {
    @Environment(AppModel.self) var model
    let preview: PreviewDeploy
    let run: String?
    var body: some View {
        if run != nil { Button { model.openPreview(preview.url, run: run) } label: { Label("Open in Bridge", systemImage: "macwindow") } }
        Button { openURL(preview.url) } label: { Label("Open in Default Browser", systemImage: "safari") }
        Button { copyToPasteboard(preview.url) } label: { Label("Copy Preview URL", systemImage: "link") }
    }
}

/// Rows in the details panel's links: one per preview, with its state.
struct PreviewRows: View {
    @Environment(AppModel.self) var model
    let session: Session
    var body: some View {
        ForEach(model.previews(for: session)) { p in
            LinkRow(icon: p.provider == "vercel" ? "triangle.fill" : p.provider == "netlify" ? "diamond.fill" : "globe",
                    tint: p.ready ? T.text2 : p.stateTint, title: "\(p.name) preview", detail: p.host, url: p.url,
                    open: { model.openPreview(p.url, run: session.id) }) {
                if !p.ready { Text(p.stateLabel).font(T.ui(11, .medium)).foregroundStyle(p.stateTint) }
            }
            .contextMenu { PreviewMenu(preview: p, run: session.id) }
        }
    }
}
