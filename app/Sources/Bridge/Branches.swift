import AppKit
import SwiftUI

// Where a new worker runs, picked in the New task sheet: a fresh worktree
// branched from any branch (the default), the main checkout, or an existing
// worktree. Data from GET /api/git (server/tasks.js `branches`).

struct GitBranch: Identifiable, Hashable {
    let j: JSON
    var id: String { name }
    var name: String { j["name"].string }
    var remote: Bool { j["remote"].bool }
    var isDefault: Bool { j["default"].bool }
    var subject: String { j["subject"].string }
    var date: Double { j["date"].double }
    var worktree: String { j["worktree"].string }
}

struct GitWorktree: Identifiable, Hashable {
    let j: JSON
    var id: String { path }
    var path: String { j["path"].string }
    var branch: String { j["branch"].nonEmpty ?? j["head"].string }
    var main: Bool { j["main"].bool }
    var name: String { j["name"].string }
}

/// The two chips under the sheet's header: workspace, then base branch.
struct WorkspaceBar: View {
    let git: JSON
    @Binding var workspace: String
    @Binding var base: String
    @Binding var branchName: String
    @StateObject private var wsOpen = Box(false)
    @StateObject private var baseOpen = Box(false)
    @ObservedObject private var data = ComposerData.shared

    var worktrees: [GitWorktree] { git["worktrees"].array.map(GitWorktree.init) }
    var defaultBranch: String { git["default"].nonEmpty ?? "main" }
    var picked: GitWorktree? {
        workspace == "local" ? worktrees.first(where: \.main) : worktrees.first { $0.path == workspace }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { wsOpen.v.toggle() } label: {
                PickerChip(text: wsLabel, open: wsOpen.v) {
                    Image(systemName: workspace == "worktree" ? "arrow.triangle.branch" : workspace == "local" ? "laptopcomputer" : "folder").font(.system(size: 11)).foregroundStyle(workspace == "local" ? T.orange : T.text2)
                }
            }
            .buttonStyle(Pressable(scale: 0.97))
            .popover(isPresented: $wsOpen.v, arrowEdge: .bottom) {
                WorkspacePanel(git: git, current: workspace, branchName: $branchName) { workspace = $0; wsOpen.v = false }
            }
            if workspace == "worktree" {
                Button { baseOpen.v.toggle() } label: {
                    PickerChip(text: "from \(base.isEmpty ? defaultBranch : base)", open: baseOpen.v) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 10.5)).foregroundStyle(T.text3)
                    }
                }
                .buttonStyle(Pressable(scale: 0.97))
                .popover(isPresented: $baseOpen.v, arrowEdge: .bottom) {
                    BranchPanel(git: git, current: base.isEmpty ? defaultBranch : base) { b in base = b == defaultBranch ? "" : b; baseOpen.v = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            } else if let w = picked {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                    Text("on \(w.branch)").font(T.ui(12)).lineLimit(1)
                }
                .foregroundStyle(T.text3).padding(.horizontal, 8)
                .transition(.opacity)
            }
            if workspace == "local" {
                Label("Edits your main checkout", systemImage: "exclamationmark.triangle.fill").font(T.ui(11.5)).foregroundStyle(T.orange)
                    .padding(.leading, 4).transition(.opacity)
            }
        }
        .animation(M.snappy, value: workspace)
        .onChange(of: data.snapshotOpen) {
            wsOpen.v = data.snapshotOpen == "compose-workspace"
            baseOpen.v = data.snapshotOpen == "compose-base"
        }
    }

    var wsLabel: String {
        if workspace == "worktree" { return branchName.isEmpty ? "New worktree" : "New worktree · \(branchName)" }
        if workspace == "local" { return "Local checkout" }
        return picked?.name ?? "Worktree"
    }
}

struct WorkspacePanel: View {
    let git: JSON
    let current: String
    @Binding var branchName: String
    let pick: (String) -> Void

    var body: some View {
        let wts = git["worktrees"].array.map(GitWorktree.init)
        let main = wts.first(where: \.main)
        let others = wts.filter { !$0.main }
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                Button { pick("worktree") } label: {
                    PickRow(title: "New worktree", subtitle: "A fresh branch in its own folder", checked: current == "worktree", height: 46) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 12)).foregroundStyle(T.accent)
                    } trail: { EmptyView() }
                }
                .buttonStyle(HoverPick())
                if current == "worktree" {
                    HStack(spacing: 8) {
                        Text("Branch").font(T.ui(11.5, .medium)).foregroundStyle(T.text3).frame(width: 48, alignment: .leading)
                        SInput(placeholder: "Named from the brief", text: $branchName, width: .infinity, mono: true)
                    }
                    .padding(.leading, 40).padding(.trailing, 10).padding(.bottom, 8)
                }
                if let m = main {
                    Button { pick("local") } label: {
                        PickRow(title: "Local checkout", subtitle: "\(tilde(m.path)) · on \(m.branch)", checked: current == "local", height: 46) {
                            Image(systemName: "laptopcomputer").font(.system(size: 12)).foregroundStyle(T.orange)
                        } trail: { EmptyView() }
                    }
                    .buttonStyle(HoverPick())
                }
            }
            .padding(5)
            if !others.isEmpty {
                Hairline()
                SectionLabel(text: "Existing worktrees", count: others.count)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(others) { w in
                            Button { pick(w.path) } label: {
                                PickRow(title: w.name, subtitle: w.branch, mono: true, checked: current == w.path) {
                                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(T.text3)
                                } trail: { EmptyView() }
                            }
                            .buttonStyle(HoverPick())
                            .help(w.path)
                        }
                    }
                    .padding(.horizontal, 5).padding(.bottom, 5)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 380)
        .background(T.raised)
    }

    func tilde(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

struct BranchPanel: View {
    let git: JSON
    let current: String
    let pick: (String) -> Void
    @StateObject private var query = Box("")
    @StateObject private var hi = Box(0)

    var body: some View {
        let all = git["branches"].array.map(GitBranch.init)
        let hits = all.filter { query.v.isEmpty || Fuzzy.score(query.v, $0.name) != nil }
        let local = hits.filter { !$0.remote }, remote = hits.filter(\.remote)
        let flat = local + remote
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(T.text3)
                PickerField(placeholder: "Branch to start from…", text: $query.v,
                            onMove: { d in if !flat.isEmpty { hi.v = (hi.v + d + flat.count) % flat.count } },
                            onSubmit: { if flat.indices.contains(hi.v) { pick(flat[hi.v].name) } })
                    .frame(height: 20)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 1) {
                    if !local.isEmpty { SectionLabel(text: "Local", count: local.count) }
                    ForEach(Array(local.enumerated()), id: \.element.id) { i, b in row(b, i) }
                    if !remote.isEmpty { SectionLabel(text: "Remote", count: remote.count) }
                    ForEach(Array(remote.enumerated()), id: \.element.id) { i, b in row(b, local.count + i) }
                    if flat.isEmpty { Text("No branch matches").font(T.ui(12)).foregroundStyle(T.text3).padding(20) }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .frame(height: min(CGFloat(flat.count) * 41 + 70, 340))
            Hairline()
            Text("Fetched fresh from origin when it has the branch").font(T.ui(11)).foregroundStyle(T.text3)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 400)
        .background(T.raised)
        .onAppear { hi.v = flat.firstIndex { $0.name == current } ?? 0 }
    }

    func row(_ b: GitBranch, _ i: Int) -> some View {
        Button { pick(b.name) } label: {
            PickRow(title: b.name, subtitle: [b.subject, b.date > 0 ? Fmt.ago(b.date) : ""].filter { !$0.isEmpty }.joined(separator: " · "), mono: true, checked: b.name == current, highlighted: hi.v == i) {
                Image(systemName: b.remote ? "cloud" : "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(b.isDefault ? T.accent : T.text3)
            } trail: {
                HStack(spacing: 4) {
                    if b.isDefault { Chip(text: "default", tint: T.accent) }
                    if !b.worktree.isEmpty { Image(systemName: "folder.fill").font(.system(size: 9.5)).foregroundStyle(T.text3).help("Checked out in \(b.worktree)") }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { if $0 { hi.v = i } }
    }
}

/// A picker row that lights while the pointer is on it.
struct HoverPick: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverPickBody(label: configuration.label) }
}

private struct HoverPickBody<Label: View>: View {
    let label: Label
    @StateObject private var hover = Box(false)
    var body: some View {
        label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover.v ? T.selected : .clear))
            .hoverBox(hover)
    }
}
