import SwiftUI

/// How a message goes out while a turn runs (server jobs.steer / queue / interrupt):
/// ↩ steers it into the running turn, ⌘↩ queues it for after, ⌥↩ stops the
/// turn and sends it now. With nothing running, all three just send.
enum SendMode: String {
    case steer, queue, interrupt
}

extension AppModel {
    /// Only Claude reads a message mid-turn; the other agents' turns are one
    /// closed-off process, so a steer to them waits in the queue.
    func canSteer(_ runId: String) -> Bool {
        let run = runData(runId)
        let turn = run["messages"].array.last { $0["role"].string == "assistant" && $0["state"].string == "running" }
        let agent = turn?["agent"].nonEmpty ?? run["opts"]["agent"].nonEmpty ?? config["followup"]["agent"].nonEmpty ?? "claude"
        return agent == "claude"
    }

    func editQueued(_ runId: String, _ id: String, text: String) async {
        await act { try await API.post("/api/runs/\(API.q(runId))/queue/\(API.q(id))", ["text": text]) }
    }

    func removeQueued(_ runId: String, _ id: String) async {
        await act { try await API.delete("/api/runs/\(API.q(runId))/queue/\(API.q(id))") }
    }

    /// Cursor's "send now": stop the running turn and send this one next.
    func sendQueuedNow(_ runId: String, _ id: String) async {
        await act { try await API.post("/api/runs/\(API.q(runId))/queue/\(API.q(id))/send") }
    }
}

/// What the send button's tooltip says: the keys, for this chat as it is now.
enum SendKeys {
    static func help(live: Bool, steers: Bool) -> String {
        guard live else { return "↩  Send\n⇧↩  New line\n⌘↩ or ⌥↩  Send too" }
        return [
            steers ? "↩  Steer: add to the running turn" : "↩  Queue (this agent can't take a message mid-turn)",
            "⇧↩  New line",
            "⌘↩  Queue: run after this turn",
            "⌥↩  Stop the turn and send now",
        ].joined(separator: "\n")
    }
}

/// Messages queued behind the running turn, over the composer: each runs as a
/// turn of its own once this one ends. Edit in place, remove, or send now.
struct QueueStrip: View {
    @Environment(AppModel.self) var model
    let runId: String

    var body: some View {
        let items = model.queues[runId] ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 10.5, weight: .medium))
                    Text(verbatim: items.count == 1 ? "1 queued" : "\(items.count) queued").font(T.ui(11.5, .medium))
                    Text("· each runs after the current turn").font(T.ui(11.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(T.text3)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                ForEach(Array(items.enumerated()), id: \.element["id"].string) { i, q in
                    if i > 0 { Rectangle().fill(T.line).frame(height: 1).padding(.leading, 12) }
                    QueueRow(runId: runId, item: q)
                }
            }
            .padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(T.raised.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.line, lineWidth: 1))
            .padding(.horizontal, 44)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

struct QueueRow: View {
    @Environment(AppModel.self) var model
    let runId: String
    let item: JSON
    @StateObject private var hover = Box(false)
    @StateObject private var editing = Box<String?>(nil)
    @FocusState private var focused: Bool

    var id: String { item["id"].string }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 10.5)).foregroundStyle(T.text3).padding(.top, 3)
            if let draft = editing.v {
                TextField("", text: Binding(get: { draft }, set: { editing.v = $0 }), axis: .vertical)
                    .textFieldStyle(.plain).font(T.ui(12.5)).lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand { editing.v = nil }
                    .onAppear { focused = true }
                Button("Save", action: save).buttonStyle(LButton(primary: true, small: true))
                IconButton(icon: "xmark", help: "Cancel (esc)", size: B.small) { editing.v = nil }
            } else {
                Text(item["text"].string).font(T.ui(12.5)).foregroundStyle(T.text).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing.v = item["text"].string }
                HStack(spacing: 2) {
                    IconButton(icon: "pencil", help: "Edit", size: B.small) { editing.v = item["text"].string }
                    IconButton(icon: "trash", help: "Remove from the queue", size: B.small) { Task { await model.removeQueued(runId, id) } }
                    IconButton(icon: "arrow.up", help: "Send now: stop the running turn and send this (⌥↩)", size: B.small) { Task { await model.sendQueuedNow(runId, id) } }
                }
                .opacity(hover.v ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .hoverBox(hover)
    }

    func save() {
        guard let t = editing.v?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        editing.v = nil
        Task { if t.isEmpty { await model.removeQueued(runId, id) } else { await model.editQueued(runId, id, text: t) } }
    }
}

/// A message steered into a running turn, where it was sent: waiting for the
/// session's next step, read, or never read because the turn ended first.
struct SteerStep: View {
    let step: JSON

    var body: some View {
        let state = step["state"].string
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .medium)).foregroundStyle(T.accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("You, mid-turn").font(T.ui(11.5, .medium)).foregroundStyle(T.text2)
                    switch state {
                    case "sent": Text("waiting for its next step").font(T.ui(11.5)).foregroundStyle(T.text3).shimmer()
                    case "unread": Text("not read: the turn ended first").font(T.ui(11.5)).foregroundStyle(T.orange)
                    default: EmptyView()
                    }
                }
                MarkdownText(text: step["text"].string, size: 12.5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.raised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.line, lineWidth: 1))
    }
}
