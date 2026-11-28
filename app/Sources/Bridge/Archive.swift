import SwiftUI

// The archive dialog: every "Archive" (session menus, the chat's ⋯, the
// palette) asks here first. "Delete the worktree" is on by default when Bridge
// made the worktree and deleting it loses nothing; with uncommitted or unpushed
// work it starts off and says what would go, so ticking it is the confirmation.
// A checkout Bridge didn't make (main checkout, adopted, imported) has no box.

/// The chat being archived and what the server said about its worktree.
struct ArchiveAsk: Equatable {
    let id: String
    let title: String
    var loaded = false
    var owned = false
    var path = ""
    var branch = ""
    var reason = ""
    var dirtyFiles = 0
    var unpushed = 0

    var risky: Bool { dirtyFiles > 0 || unpushed > 0 }
    /// "3 uncommitted changes and 2 unpushed commits".
    var loss: String {
        [dirtyFiles > 0 ? "\(dirtyFiles) uncommitted change\(dirtyFiles == 1 ? "" : "s")" : "",
         unpushed > 0 ? "\(unpushed) unpushed commit\(unpushed == 1 ? "" : "s")" : ""]
            .filter { !$0.isEmpty }.joined(separator: " and ")
    }

    mutating func fill(_ w: JSON) {
        loaded = true
        owned = w["owned"].bool
        path = w["path"].string
        branch = w["branch"].string
        reason = w["reason"].string
        dirtyFiles = w["dirty"].bool ? max(1, Int(w["dirtyFiles"].double)) : 0
        unpushed = Int(w["unpushed"].double)
    }
}

struct ArchiveSheet: View {
    @Environment(AppModel.self) var model
    let ask: ArchiveAsk
    @StateObject private var delete = Box(true)
    @StateObject private var busy = Box(false)

    var deleting: Bool { ask.owned && delete.v }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 13, weight: .medium)).foregroundStyle(T.text2)
                    Text(verbatim: "Archive \u{201C}\(ask.title.count > 48 ? String(ask.title.prefix(47)) + "…" : ask.title)\u{201D}?")
                        .font(T.ui(14, .semibold)).foregroundStyle(T.text).lineLimit(1)
                }
                Text("Its open questions and to-dos are dismissed. The chat is kept under Sessions › Archived.")
                    .font(T.ui(12.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
            worktree
            Hairline()
            buttons
        }
        .frame(width: 440)
        .floatingPanel()
        .onChange(of: ask.loaded, initial: true) { _, _ in delete.v = ask.owned && !ask.risky }
        .onKeyPress(.escape) { model.archiveAsk = nil; return .handled }
    }

    @ViewBuilder var worktree: some View {
        if !ask.loaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the worktree…").font(T.ui(12)).foregroundStyle(T.text3)
            }
            .padding(.horizontal, 18).padding(.bottom, 14)
        } else if ask.owned {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $delete.v) { Text("Delete the worktree").font(T.ui(13, .medium)).foregroundStyle(T.text) }
                    .toggleStyle(.checkbox)
                Text(verbatim: ask.path).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 22)
                if ask.risky {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(T.orange).padding(.top, 1)
                        Text(verbatim: "It has \(ask.loss).\(ask.dirtyFiles > 0 ? " Deleting the worktree loses the uncommitted changes." : "")\(ask.unpushed > 0 ? " The branch keeps its commits, but they aren't on the remote." : "")")
                            .font(T.ui(12)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.orange.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.orange.opacity(0.3), lineWidth: 1))
                } else {
                    Text(verbatim: "The branch\(ask.branch.isEmpty ? "" : " \(ask.branch)") stays.").font(T.ui(12)).foregroundStyle(T.text3).padding(.leading, 22)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 14)
        } else if !ask.path.isEmpty {
            Label(ask.reason.isEmpty ? "Its folder stays on disk" : "Its folder stays: \(ask.reason)", systemImage: "folder")
                .font(T.ui(12)).foregroundStyle(T.text3).lineLimit(2)
                .padding(.horizontal, 18).padding(.bottom, 14)
        }
    }

    var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { model.archiveAsk = nil }.buttonStyle(LButton())
            Button(deleting ? "Archive and Delete" : "Archive") {
                busy.v = true
                Task {
                    await model.setArchived(ask.id, true, deleteWorktree: deleting, force: deleting && ask.risky)
                    busy.v = false
                    model.archiveAsk = nil
                }
            }
            .buttonStyle(LButton(kind: deleting && ask.risky ? .danger : .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(!ask.loaded || busy.v)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
