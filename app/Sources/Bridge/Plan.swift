import SwiftUI

// MARK: - The agent's task list
//
// What the agent said it would do and how far it got: the latest to-do list
// it wrote (Claude's TodoWrite, Devin's todo_write, Cursor's todo tool, Codex's
// update_plan), replayed in order so Cursor's merges land. Ticks itself as the
// agent marks items done. Shown as a pill over the composer and as a section
// in the details panel.

struct PlanItem: Identifiable, Hashable {
    let id: String
    let text: String
    let status: String
    var done: Bool { status == "completed" || status == "done" }
    var active: Bool { status == "in_progress" || status == "in-progress" || status == "active" }
    var cancelled: Bool { status == "cancelled" || status == "canceled" }
}

struct Plan: Equatable {
    var items: [PlanItem] = []
    var done: Int { items.filter { $0.done || $0.cancelled }.count }
    var total: Int { items.count }
    var active: PlanItem? { items.first(where: \.active) }
    var finished: Bool { total > 0 && done == total }
    var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    static let tools: Set<String> = ["TodoWrite", "todo_write", "update_plan"]

    /// The plan as of the last to-do call in the transcript.
    static func of(_ run: JSON) -> Plan {
        var items: [PlanItem] = []
        for m in run["messages"].array where m["role"].string == "assistant" {
            for s in m["steps"].array where s["kind"].string == "tool" && tools.contains(s["name"].string) {
                guard let raw = try? JSONDecoder().decode(JSON.self, from: Data(s["raw"].string.utf8)) else { continue }
                let list = raw["todos"].array.isEmpty ? raw["plan"].array : raw["todos"].array
                let next = list.enumerated().compactMap { i, t -> PlanItem? in
                    let text = (t["content"].nonEmpty ?? t["step"].nonEmpty ?? t["title"].nonEmpty ?? t["activeForm"].string).trimmingCharacters(in: .whitespacesAndNewlines)
                    let id = t["id"].nonEmpty ?? text
                    if text.isEmpty && t["id"].nonEmpty == nil { return nil }
                    return PlanItem(id: id, text: text, status: (t["status"].nonEmpty ?? "pending").lowercased())
                }
                if raw["merge"].bool {
                    // Cursor updates items by id and appends new ones.
                    for n in next {
                        if let i = items.firstIndex(where: { $0.id == n.id }) {
                            items[i] = PlanItem(id: n.id, text: n.text.isEmpty ? items[i].text : n.text, status: n.status)
                        } else { items.append(n) }
                    }
                } else if !next.isEmpty || raw["todos"].isNull == false {
                    items = next
                }
            }
        }
        return Plan(items: items)
    }
}

extension AppModel {
    /// A list kept with `bridge plan` wins; else the agent's own to-do tool's.
    func plan(_ runId: String) -> Plan {
        let kept = sessions.first { $0.id == runId }?.task["plan"].array ?? []
        if !kept.isEmpty {
            return Plan(items: kept.enumerated().map { i, t in PlanItem(id: "\(i)", text: t["text"].string, status: t["status"].nonEmpty ?? "pending") })
        }
        return Plan.of(runData(runId))
    }
}

/// A small progress ring: an arc filling as items are ticked.
struct PlanRing: View {
    let progress: Double
    var size: CGFloat = 14
    var body: some View {
        ZStack {
            Circle().stroke(T.line, lineWidth: 2)
            Circle().trim(from: 0, to: progress).stroke(progress >= 1 ? T.green : T.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress >= 1 { Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(T.green) }
        }
        .frame(width: size, height: size)
        .animation(M.snappy, value: progress)
    }
}

struct PlanRow: View {
    let item: PlanItem
    var compact = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                if item.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(T.green) }
                else if item.cancelled { Image(systemName: "xmark.circle").foregroundStyle(T.text3) }
                else if item.active { Image(systemName: "circle.dotted.circle").foregroundStyle(T.accent).symbolEffect(.pulse) }
                else { Image(systemName: "circle").foregroundStyle(T.text3) }
            }
            .font(.system(size: compact ? 11.5 : 12.5))
            .contentTransition(.symbolEffect(.replace))
            Text(item.text)
                .font(T.ui(compact ? 12 : 12.5, item.active ? .medium : .regular))
                .foregroundStyle(item.done || item.cancelled ? T.text3 : T.text)
                .strikethrough(item.done || item.cancelled, color: T.text3)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(compact ? 2 : nil)
            Spacer(minLength: 0)
        }
        .animation(M.snappy, value: item.status)
    }
}

/// "3/10 tasks" over the composer; click for the whole list.
struct PlanPill: View {
    @Environment(AppModel.self) var model
    let runId: String
    @StateObject private var open = Box(false)
    @StateObject private var hover = Box(false)

    var body: some View {
        let plan = model.plan(runId)
        if plan.total > 0 {
            HStack {
                Button { open.v.toggle() } label: {
                    HStack(spacing: 8) {
                        PlanRing(progress: plan.progress)
                        Text(verbatim: "\(plan.done)/\(plan.total) tasks").font(T.ui(12, .semibold)).foregroundStyle(T.text).monospacedDigit()
                            .contentTransition(.numericText())
                        if let a = plan.active, !plan.finished {
                            Text(a.text).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        }
                        Image(systemName: "chevron.up").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.text3)
                            .rotationEffect(.degrees(open.v ? 180 : 0))
                    }
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(Capsule().fill(hover.v ? T.hover : T.raised))
                    .overlay(Capsule().stroke(T.line, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.97))
                .hoverBox(hover)
                .help("The agent's task list: ticks itself as it works")
                .popover(isPresented: $open.v, arrowEdge: .top) { PlanPanel(plan: plan).frame(width: 440) }
                Spacer()
            }
            .padding(.horizontal, 44).padding(.top, 4)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .animation(M.snappy, value: plan)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

struct PlanPanel: View {
    let plan: Plan
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PlanRing(progress: plan.progress, size: 16)
                Text("Tasks").font(T.ui(13, .semibold))
                Text(verbatim: "\(plan.done) of \(plan.total) done").font(T.ui(12)).foregroundStyle(T.text3).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(plan.items) { PlanRow(item: $0) }
                }
                .padding(14)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The details panel's section: a bar and the list.
struct PlanSection: View {
    @Environment(AppModel.self) var model
    let runId: String
    @StateObject private var all = Box(false)

    var body: some View {
        let plan = model.plan(runId)
        if plan.total > 0 {
            PropSection(title: "Tasks") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(T.line)
                                Capsule().fill(plan.finished ? T.green : T.accent).frame(width: max(4, g.size.width * plan.progress))
                            }
                        }
                        .frame(height: 5)
                        Text(verbatim: "\(plan.done)/\(plan.total)").font(T.ui(11.5, .medium)).foregroundStyle(T.text2).monospacedDigit()
                    }
                    .animation(M.snappy, value: plan.progress)
                    let shown = all.v || plan.total <= 8 ? plan.items : Array(plan.items.prefix(8))
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(shown) { PlanRow(item: $0, compact: true) }
                    }
                    if plan.total > 8 {
                        Button(all.v ? "Show less" : "Show all \(plan.total)") { withAnimation(M.snappy) { all.v.toggle() } }
                            .buttonStyle(.plain).font(T.ui(11.5, .medium)).foregroundStyle(T.accent)
                    }
                }
            }
        }
    }
}
