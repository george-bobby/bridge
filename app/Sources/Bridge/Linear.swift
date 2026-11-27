import AppKit
import SwiftUI

// The Linear page: my issues as a grouped list or a board, with Linear's
// Display and Filter popovers in the header.

struct IssueGroup: Identifiable {
    let id: String
    let title: String
    let icon: AnyView
    let issues: [Issue]
}

/// Comma-joined set kept in UserDefaults.
func csvSet(_ s: String) -> Set<String> { Set(s.split(separator: ",").map(String.init).filter { !$0.isEmpty }) }
func csvString(_ s: Set<String>) -> String { s.sorted().joined(separator: ",") }

enum LinearProps {
    static let all: [(id: String, label: String)] = [
        ("priority", "Priority"), ("id", "ID"), ("status", "Status"), ("labels", "Labels"), ("project", "Project"),
        ("cycle", "Cycle"), ("prs", "Pull requests"), ("session", "Session"), ("assignee", "Assignee"), ("updated", "Updated"),
    ]
    static let defaults = "assignee,cycle,id,labels,priority,project,prs,session,status,updated"
}

let priorityNames = [1: "Urgent", 2: "High", 3: "Medium", 4: "Low", 0: "No priority"]
let priorityOrder = [1, 2, 3, 4, 0]

struct LinearView: View {
    @Environment(AppModel.self) var model
    @AppStorage("linear.subissues") private var showSubs = true
    @AppStorage("linear.done") private var showDone = false
    @AppStorage("linear.layout") private var layout = "list"
    @AppStorage("linear.group") private var grouping = "status"
    @AppStorage("linear.order") private var ordering = "priority"
    @AppStorage("linear.props") private var propsRaw = LinearProps.defaults
    @AppStorage("linear.f.priority") private var fPriority = ""
    @AppStorage("linear.f.labels") private var fLabels = ""
    @AppStorage("linear.f.projects") private var fProjects = ""
    @StateObject private var collapsed = Box(Set<String>())

    static let order: [StatusKind] = [.progress, .review, .todo, .triage, .backlog, .done, .canceled]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "My issues", subtitle: model.linear["viewer"].nonEmpty ?? "", icon: "circle.lefthalf.filled") {
                filterButton
                displayButton
                IconButton(icon: "arrow.clockwise", help: "Refresh (⌘R)", spinning: model.refreshing.contains("linear")) { Task { await model.load("linear", refresh: true) } }
            }
            if filterCount > 0 { filterBar.transition(.move(edge: .top).combined(with: .opacity)) }
            if let e = model.errors["linear"], !e.isEmpty { ErrorBar(text: e) }
            if model.linear.isNull {
                EmptyState(icon: "circle.lefthalf.filled", title: model.loading.contains("linear") ? "Loading from Linear…" : "Nothing loaded")
            } else if !model.linear["configured"].bool {
                EmptyState(icon: "key", title: "Linear isn't connected", detail: "Add LINEAR_API_KEY to .env and restart the server.")
            } else if layout == "board" {
                LinearBoard(groups: groups(board: true), showSubs: showSubs)
                    .transition(.opacity)
            } else {
                list.transition(.opacity)
            }
        }
        .animation(M.snappy, value: layout)
        .animation(M.snappy, value: filterCount)
    }

    // MARK: list

    var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                let gs = groups(board: false)
                if gs.isEmpty { EmptyState(icon: "line.3.horizontal.decrease.circle", title: "No issues", detail: filterCount > 0 ? "Nothing matches these filters." : "Nothing assigned to you here.") }
                ForEach(gs) { group in
                    Section {
                        if !collapsed.v.contains(group.id) {
                            ForEach(group.issues) { IssueTree(issue: $0, showSubs: showSubs) }
                        }
                    } header: {
                        if grouping != "none" {
                            GroupHeader(title: group.title, count: group.issues.count, icon: group.icon) {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.text3)
                                    .rotationEffect(.degrees(collapsed.v.contains(group.id) ? 0 : 90))
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(M.snappy) {
                                    if collapsed.v.contains(group.id) { collapsed.v.remove(group.id) } else { collapsed.v.insert(group.id) }
                                }
                            }
                        }
                    }
                }
            }
            .animation(M.snappy, value: grouping)
            .animation(M.snappy, value: ordering)
        }
    }

    // MARK: header controls

    var displayButton: some View {
        PopoverButton(icon: "slider.horizontal.3", text: "Display", help: "Layout, grouping, ordering and properties", width: 320) {
            HStack {
                SlidingTabs(tabs: [
                    .init(id: "list", label: "List", icon: "list.bullet"),
                    .init(id: "board", label: "Board", icon: "rectangle.split.3x1"),
                ], selection: $layout)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 6)
            PopRow(icon: "rectangle.3.group", label: "Grouping") {
                ValueMenu(options: [
                    .init(id: "status", label: "Status", icon: "circle.lefthalf.filled"),
                    .init(id: "priority", label: "Priority", icon: "chart.bar"),
                    .init(id: "project", label: "Project", icon: "cube"),
                    .init(id: "none", label: "No grouping", icon: "minus"),
                ], selection: $grouping)
            }
            PopRow(icon: "arrow.up.arrow.down", label: "Ordering") {
                ValueMenu(options: [
                    .init(id: "priority", label: "Priority", icon: "chart.bar"),
                    .init(id: "updated", label: "Last updated", icon: "clock"),
                    .init(id: "id", label: "Issue ID", icon: "number"),
                    .init(id: "title", label: "Title", icon: "textformat"),
                ], selection: $ordering)
            }
            PopDivider()
            PopRow(icon: "list.bullet.indent", label: "Show sub-issues") {
                Toggle("", isOn: Binding(get: { showSubs }, set: { v in withAnimation(M.snappy) { showSubs = v } })).toggleStyle(LSwitch())
            }
            PopRow(icon: "checkmark.circle", label: "Show completed issues") {
                Toggle("", isOn: Binding(get: { showDone }, set: { v in withAnimation(M.snappy) { showDone = v } })).toggleStyle(LSwitch())
            }
            PopDivider()
            PopLabel("Display properties")
            PropChips(options: LinearProps.all, selected: Binding(get: { csvSet(propsRaw) }, set: { propsRaw = csvString($0) }))
            PopDivider()
            HStack {
                Spacer()
                Button("Reset to default") {
                    withAnimation(M.snappy) {
                        layout = "list"; grouping = "status"; ordering = "priority"; showSubs = true; showDone = false; propsRaw = LinearProps.defaults
                    }
                }
                .buttonStyle(.plain).font(T.ui(12)).foregroundStyle(T.text3)
            }
            .padding(.horizontal, 14).padding(.bottom, 2)
        }
    }

    var filterButton: some View {
        let prios = csvSet(fPriority), labels = csvSet(fLabels), projects = csvSet(fProjects)
        return PopoverButton(icon: "line.3.horizontal.decrease", text: "Filter", count: filterCount, active: filterCount > 0, help: "Filter issues", width: 280) {
            PopLabel("Priority")
            ForEach(priorityOrder, id: \.self) { p in
                PopCheckRow(label: priorityNames[p] ?? "", on: prios.contains("\(p)")) { PriorityIcon(priority: p) } action: { fPriority = csvString(toggled(prios, "\(p)")) }
            }
            let allLabels = labelCatalog
            if !allLabels.isEmpty {
                PopDivider()
                PopLabel("Labels")
                ForEach(allLabels, id: \.0) { l in
                    PopCheckRow(label: l.0, on: labels.contains(l.0)) { Circle().fill(hexColor(l.1)).frame(width: 8, height: 8) } action: { fLabels = csvString(toggled(labels, l.0)) }
                }
            }
            let allProjects = Array(Set(model.issues.map(\.project).filter { !$0.isEmpty })).sorted()
            if !allProjects.isEmpty {
                PopDivider()
                PopLabel("Project")
                ForEach(allProjects, id: \.self) { p in
                    PopCheckRow(label: p, on: projects.contains(p)) { Image(systemName: "cube").font(.system(size: 11)).foregroundStyle(T.text2) } action: { fProjects = csvString(toggled(projects, p)) }
                }
            }
            if filterCount > 0 {
                PopDivider()
                PopCheckRow(label: "Clear all filters", on: false) { Image(systemName: "xmark.circle").font(.system(size: 11.5)).foregroundStyle(T.text2) } action: { clearFilters() }
            }
        }
    }

    var filterBar: some View {
        let prios = csvSet(fPriority), labels = csvSet(fLabels), projects = csvSet(fProjects)
        return HStack(spacing: 6) {
            if !prios.isEmpty {
                FilterChip(label: "Priority is", value: priorityOrder.filter { prios.contains("\($0)") }.compactMap { priorityNames[$0] }.joined(separator: ", ")) { fPriority = "" }
            }
            if !labels.isEmpty { FilterChip(label: "Label is", value: labels.sorted().joined(separator: ", ")) { fLabels = "" } }
            if !projects.isEmpty { FilterChip(label: "Project is", value: projects.sorted().joined(separator: ", ")) { fProjects = "" } }
            Button("Clear") { clearFilters() }.buttonStyle(.plain).font(T.ui(11.5, .medium)).foregroundStyle(T.text3).padding(.leading, 4)
            Spacer()
        }
        .padding(.horizontal, 20).frame(height: 38)
        .overlay(alignment: .bottom) { Hairline() }
    }

    func toggled(_ s: Set<String>, _ v: String) -> Set<String> { var s = s; if s.contains(v) { s.remove(v) } else { s.insert(v) }; return s }

    func clearFilters() { withAnimation(M.snappy) { fPriority = ""; fLabels = ""; fProjects = "" } }

    var filterCount: Int { csvSet(fPriority).count + csvSet(fLabels).count + csvSet(fProjects).count }

    var labelCatalog: [(String, String)] {
        var seen: [String: String] = [:]
        for i in model.issues { for l in i.labels where seen[l.0] == nil { seen[l.0] = l.1 } }
        return seen.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { ($0.key, $0.value) }
    }

    // MARK: grouping

    func matches(_ i: Issue) -> Bool {
        let prios = csvSet(fPriority), labels = csvSet(fLabels), projects = csvSet(fProjects)
        if !prios.isEmpty && !prios.contains("\(i.priority)") { return false }
        if !labels.isEmpty && !i.labels.contains(where: { labels.contains($0.0) }) { return false }
        if !projects.isEmpty && !projects.contains(i.project) { return false }
        return true
    }

    func sorted(_ list: [Issue]) -> [Issue] {
        switch ordering {
        case "updated": return list.sorted { $0.updatedAt > $1.updatedAt }
        case "id": return list.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        case "title": return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        default: return list.sorted { ($0.priority == 0 ? 9 : $0.priority, -$0.updatedAt) < ($1.priority == 0 ? 9 : $1.priority, -$1.updatedAt) }
        }
    }

    /// Issues grouped by the Display setting. A sub-issue whose parent is also
    /// shown sits under that parent rather than twice. The board always has
    /// columns, so "No grouping" falls back to status there.
    func groups(board: Bool) -> [IssueGroup] {
        let shownParents = Set(model.issues.filter { showDone || $0.active }.map(\.key))
        let visible = model.issues.filter { (showDone || $0.active) && !(showSubs && shownParents.contains($0.parentKey)) && matches($0) }
        let mode = board && grouping == "none" ? "status" : grouping
        switch mode {
        case "priority":
            return priorityOrder.compactMap { p in
                let list = visible.filter { $0.priority == p }
                return list.isEmpty ? nil : IssueGroup(id: "p\(p)", title: priorityNames[p] ?? "", icon: AnyView(PriorityIcon(priority: p)), issues: sorted(list))
            }
        case "project":
            let names = Array(Set(visible.map(\.project))).sorted { ($0.isEmpty ? 1 : 0, $0) < ($1.isEmpty ? 1 : 0, $1) }
            return names.map { n in
                IssueGroup(id: "proj:\(n)", title: n.isEmpty ? "No project" : n,
                           icon: AnyView(Image(systemName: n.isEmpty ? "cube.transparent" : "cube").font(.system(size: 11)).foregroundStyle(T.text2)),
                           issues: sorted(visible.filter { $0.project == n }))
            }
        case "none":
            return visible.isEmpty ? [] : [IssueGroup(id: "all", title: "All issues", icon: AnyView(EmptyView()), issues: sorted(visible))]
        default:
            var byState: [String: [Issue]] = [:]
            for i in visible { byState[i.state, default: []].append(i) }
            let names = byState.keys.sorted { stateRank(byState[$0] ?? []) < stateRank(byState[$1] ?? []) }
            return names.map { name in stateGroup(name, byState[name] ?? []) }
        }
    }
}

extension LinearView {
    /// Workflow order, then Linear's own position within a type. Split out so CI's
    /// slower type-checker doesn't give up on one long chained expression.
    func stateRank(_ list: [Issue]) -> (Int, Double) {
        let kind: StatusKind = list.first?.status ?? .backlog
        let pos: Double = list.first?.statePos ?? 0
        return (Self.order.firstIndex(of: kind) ?? 9, -pos)
    }

    func stateGroup(_ name: String, _ list: [Issue]) -> IssueGroup {
        let kind: StatusKind = list.first?.status ?? .backlog
        let color: Color = hexColor(list.first?.stateColor ?? "", fallback: kind.color)
        let icon = AnyView(StatusIcon(kind: kind, color: color, size: 13))
        return IssueGroup(id: "s:\(name)", title: name, icon: icon, issues: sorted(list))
    }
}

// MARK: - Board

struct LinearBoard: View {
    let groups: [IssueGroup]
    let showSubs: Bool
    @Namespace private var cards

    var body: some View {
        GeometryReader { g in
            let n = CGFloat(max(groups.count, 1))
            let width = min(360, max(270, (g.size.width - 40 - 12 * (n - 1)) / n))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(groups) { group in
                        LinearColumn(group: group, showSubs: showSubs, ns: cards).frame(width: width)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    if groups.isEmpty {
                        EmptyState(icon: "rectangle.split.3x1", title: "No issues", detail: "Nothing matches this view.").frame(width: g.size.width - 40)
                    }
                }
                .animation(M.snappy, value: groups.map { "\($0.id):\($0.issues.map(\.key))" })
                .padding(20)
                .frame(height: g.size.height, alignment: .top)
            }
            .scrollIndicators(.automatic)
        }
    }
}

struct LinearColumn: View {
    @Environment(AppModel.self) var model
    let group: IssueGroup
    let showSubs: Bool
    let ns: Namespace.ID
    @StateObject private var showAll = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                group.icon
                Text(group.title).font(T.ui(12.5, .medium)).foregroundStyle(T.text).lineLimit(1)
                Text(verbatim: "\(group.issues.count)").font(T.ui(12)).foregroundStyle(T.text3).monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 42)
            ScrollView {
                LazyVStack(spacing: 8) {
                    let shown = showAll.v ? group.issues : Array(group.issues.prefix(40))
                    ForEach(shown) { i in
                        IssueCard(issue: i, showSubs: showSubs)
                            .matchedGeometryEffect(id: i.key, in: ns)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    if shown.count < group.issues.count {
                        Button("Show \(group.issues.count - shown.count) more") { withAnimation(M.snappy) { showAll.v = true } }
                            .buttonStyle(.plain).font(T.ui(12)).foregroundStyle(T.text3).padding(6)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.raised.opacity(0.28)))
    }
}

struct IssueCard: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    let showSubs: Bool
    @AppStorage("linear.props") private var propsRaw = LinearProps.defaults
    @StateObject private var hover = Box(false)
    @StateObject private var subsOpen = Box(false)

    var body: some View {
        let props = csvSet(propsRaw)
        let prs = props.contains("prs") ? Array(model.pulls(forIssue: issue.key).prefix(2)) : []
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if props.contains("id") { Text(issue.key).font(T.mono(11)).foregroundStyle(T.text3).fixedSize() }
                if !issue.parentKey.isEmpty && !model.issues.contains(where: { $0.key == issue.parentKey }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 8.5, weight: .semibold))
                        Text(issue.parentTitle).lineLimit(1)
                    }
                    .font(T.ui(11)).foregroundStyle(T.text3)
                    .help("Sub-issue of \(issue.parentKey) \(issue.parentTitle)")
                }
                Spacer(minLength: 4)
                if props.contains("assignee") {
                    Avatar(name: issue.assignee.isEmpty ? "?" : issue.assignee, url: issue.assigneeAvatar, size: 18)
                        .opacity(issue.assignee.isEmpty ? 0.35 : 1)
                        .help(issue.assignee.isEmpty ? "Unassigned" : issue.assignee)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                if props.contains("status") {
                    StatusIcon(kind: issue.status, color: hexColor(issue.stateColor, fallback: issue.status.color), size: 13).padding(.top, 1.5).help(issue.state)
                }
                Text(issue.title).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(3).multilineTextAlignment(.leading)
            }
            FlowRows(spacing: 5) {
                if props.contains("priority") {
                    PriorityIcon(priority: issue.priority)
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(T.line, lineWidth: 1))
                        .help(issue.priorityLabel.isEmpty ? (priorityNames[issue.priority] ?? "") : issue.priorityLabel)
                }
                if !issue.children.isEmpty {
                    Button { withAnimation(M.snappy) { subsOpen.v.toggle() } } label: {
                        HStack(spacing: 4) {
                            Ring(done: issue.childrenDone, total: issue.children.count, size: 11)
                            Text(verbatim: "\(issue.childrenDone)/\(issue.children.count)").font(T.ui(11, .medium)).foregroundStyle(T.text2).monospacedDigit()
                        }
                        .padding(.horizontal, 6).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(subsOpen.v ? T.selected : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(T.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(issue.childrenDone) of \(issue.children.count) sub-issues done")
                }
                if props.contains("labels") { ForEach(issue.labels.prefix(3), id: \.0) { l in Chip(text: l.0, dot: hexColor(l.1)) } }
                if props.contains("project") && !issue.project.isEmpty { Chip(text: issue.project, icon: "cube") }
                if props.contains("cycle"), let c = issue.cycle { Chip(text: "Cycle \(c)", icon: "arrow.triangle.2.circlepath") }
                ForEach(prs) { pr in
                    Button { openURL(pr.url) } label: {
                        Chip(text: "#\(pr.number)", icon: pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull", tint: pr.state == "MERGED" ? T.purple : nil, mono: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            if subsOpen.v && !issue.children.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(issue.children) { c in
                        HStack(spacing: 7) {
                            StatusIcon(kind: c.status, color: hexColor(c.stateColor, fallback: c.status.color), size: 11)
                            Text(c.key).font(T.mono(10.5)).foregroundStyle(T.text3)
                            Text(c.title).font(T.ui(11.5)).foregroundStyle(c.status == .done || c.status == .canceled ? T.text3 : T.text2).lineLimit(1)
                                .strikethrough(c.status == .canceled, color: T.text3)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { openURL(c.url) }
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if props.contains("session") || props.contains("updated") {
                HStack(spacing: 6) {
                    if props.contains("session") { IssueSessionButton(issue: issue) }
                    Spacer(minLength: 0)
                    if props.contains("updated") { Text(Fmt.ago(issue.updatedAt)).font(T.ui(11)).foregroundStyle(T.text3).fixedSize() }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover.v ? T.hover : T.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(hover.v ? T.text3.opacity(0.5) : T.line, lineWidth: 1))
        .shadow(color: T.shade.opacity(hover.v ? 0.35 : 0.18), radius: hover.v ? 10 : 2, y: hover.v ? 4 : 1)
        .offset(y: hover.v ? -1 : 0)
        .contentShape(Rectangle())
        .hoverBox(hover)
        .onTapGesture(count: 2) { openURL(issue.url) }
        .onTapGesture { if let s = model.session(forIssue: issue.key) { model.open(s.id) } }
        .contextMenu { IssueMenu(issue: issue) }
    }
}
