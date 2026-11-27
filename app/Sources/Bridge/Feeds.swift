import SwiftUI

// MARK: - More sources: Vercel, incident.io, Granola
//
// Read-only feeds from server/sources.js (`/api/sources/vercel|incidents|granola`),
// each on its own key in .env. Which sources the sidebar shows is a Settings
// choice (`SourceKind`, UserDefaults `sources.hidden`); a source that isn't
// connected yet says which key it needs.

enum SourceKind: String, CaseIterable, Identifiable {
    case slack, github, linear, vercel, incidents, granola
    var id: String { rawValue }
    var label: String {
        switch self {
        case .slack: return "Slack"
        case .github: return "GitHub"
        case .linear: return "Linear"
        case .vercel: return "Vercel"
        case .incidents: return "Incidents"
        case .granola: return "Granola"
        }
    }
    var icon: String {
        switch self {
        case .slack: return "number"
        case .github: return "arrow.triangle.pull"
        case .linear: return "circle.lefthalf.filled"
        case .vercel: return "triangle"
        case .incidents: return "flame"
        case .granola: return "note.text"
        }
    }
    var route: Route {
        switch self {
        case .slack: return .slack
        case .github: return .pulls
        case .linear: return .linear
        case .vercel: return .vercel
        case .incidents: return .incidents
        case .granola: return .granola
        }
    }
    var detail: String {
        switch self {
        case .slack: return "Mentions, watched channels and threads"
        case .github: return "Your pull requests and review requests"
        case .linear: return "Issues assigned to you"
        case .vercel: return "Deployments across your account and teams"
        case .incidents: return "incident.io: live and recent incidents"
        case .granola: return "Granola: your meeting notes"
        }
    }
    /// The .env key that connects it, for the ones that need one.
    var key: String? {
        switch self {
        case .vercel: return "VERCEL_TOKEN"
        case .incidents: return "INCIDENT_API_KEY"
        case .granola: return "GRANOLA_API_KEY"
        default: return nil
        }
    }
}

enum Sources {
    static let key = "sources.hidden"
    static var hidden: Set<String> { Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init)) }
}

extension AppModel {
    func sourceShown(_ s: SourceKind) -> Bool { !hiddenSources.contains(s.rawValue) }
    func setSource(_ s: SourceKind, shown: Bool) {
        var h = hiddenSources
        if shown { h.remove(s.rawValue) } else { h.insert(s.rawValue) }
        withAnimation(M.snappy) { hiddenSources = h }
        UserDefaults.standard.set(h.sorted().joined(separator: ","), forKey: Sources.key)
        if shown { Task { if s == .slack { await loadSlack() } else { await load(s == .github ? "pulls" : s.rawValue) } } }
    }
    var vercelDeployments: [JSON] { vercel["deployments"].array }
    var liveIncidents: [JSON] { incidents["incidents"].array.filter { ["live", "triage"].contains($0["category"].string) } }
}

/// "Connect X": what a source needs, with a way to Settings.
struct SourceSetup: View {
    let kind: SourceKind
    let how: String
    var body: some View {
        VStack(spacing: 12) {
            EmptyState(icon: kind.icon, title: "Connect \(kind.label)", detail: how)
                .frame(maxHeight: 260)
            OpenSettingsButton(pane: "integrations", label: "Add \(kind.key ?? "the key") in Settings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Vercel

struct VercelView: View {
    @Environment(AppModel.self) var model
    @AppStorage("vercel.tab") private var tab = "all"

    var all: [JSON] { model.vercelDeployments }
    var shown: [JSON] {
        switch tab {
        case "production": return all.filter { $0["target"].string == "production" }
        case "preview": return all.filter { $0["target"].string != "production" }
        case "failed": return all.filter { $0["state"].string == "failed" }
        default: return all
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Vercel", subtitle: model.vercel["user"].nonEmpty.map { "@\($0)" + (model.vercel["teams"].array.isEmpty ? "" : " · " + model.vercel["teams"].array.map(\.string).joined(separator: ", ")) } ?? "", icon: "triangle") {
                if model.vercel["configured"].bool {
                    SlidingTabs(tabs: [
                        .init(id: "all", label: "All"),
                        .init(id: "preview", label: "Preview"),
                        .init(id: "production", label: "Production"),
                        .init(id: "failed", label: "Failed", count: all.filter { $0["state"].string == "failed" }.count, hot: true),
                    ], selection: $tab)
                }
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.refreshing.contains("vercel")) { Task { await model.load("vercel", refresh: true) } }
            }
            if let e = model.errors["vercel"], !e.isEmpty { ErrorBar(text: e) }
            if model.vercel.isNull {
                EmptyState(icon: "triangle", title: model.loading.contains("vercel") ? "Loading from Vercel…" : "Nothing loaded")
            } else if !model.vercel["configured"].bool {
                SourceSetup(kind: .vercel, how: "Create a token at vercel.com › Account Settings › Tokens (any Vercel account can), then paste it as VERCEL_TOKEN. Bridge only reads deployments.")
            } else if shown.isEmpty {
                EmptyState(icon: "checkmark.circle", title: "Nothing here", detail: "No deployments in this view.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        let projects = Dictionary(grouping: shown) { $0["project"].string }
                        let order = projects.keys.sorted { (projects[$0]?.first?["createdAt"].double ?? 0) > (projects[$1]?.first?["createdAt"].double ?? 0) }
                        ForEach(order, id: \.self) { name in
                            Section {
                                ForEach(projects[name] ?? [], id: \.self) { DeploymentRow(d: $0) }
                            } header: {
                                GroupHeader(title: name, count: projects[name]?.count, icon: AnyView(Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(T.text2)))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct DeploymentState: View {
    let state: String
    var body: some View {
        let (label, tint): (String, Color) = {
            switch state {
            case "ready": return ("Ready", T.green)
            case "failed": return ("Failed", T.red)
            case "building": return ("Building", T.orange)
            case "canceled": return ("Canceled", T.text3)
            default: return ("Queued", T.text3)
            }
        }()
        HStack(spacing: 5) {
            if state == "building" { PulseDot(color: tint) } else { Circle().fill(tint).frame(width: 7, height: 7) }
            Text(label).font(T.ui(11.5, .medium)).foregroundStyle(tint)
        }
        .frame(width: 78, alignment: .leading)
    }
}

struct DeploymentRow: View {
    @Environment(AppModel.self) var model
    let d: JSON

    var session: Session? {
        let b = d["branch"].string
        guard !b.isEmpty else { return nil }
        return model.boardSessions.first { $0.branch == b }
    }

    var body: some View {
        HoverRow(height: 46) {
            HStack(spacing: 12) {
                DeploymentState(state: d["state"].string)
                if d["target"].string == "production" { Chip(text: "Production", tint: T.accent) } else { Chip(text: "Preview") }
                VStack(alignment: .leading, spacing: 2) {
                    Text(d["message"].nonEmpty ?? d["url"].string).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                    HStack(spacing: 6) {
                        if !d["branch"].string.isEmpty {
                            Label(d["branch"].string, systemImage: "arrow.triangle.branch").font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1)
                        }
                        Text(URL(string: d["url"].string)?.host ?? "").font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let s = session { Chip(text: s.title, icon: "bubble.left").frame(maxWidth: 200).help("The session on this branch") }
                if d["pr"].int > 0 { Chip(text: "#\(d["pr"].int)", icon: "arrow.triangle.pull", mono: true) }
                if !d["creator"].string.isEmpty { Avatar(name: d["creator"].string, size: 18).help(d["creator"].string) }
                Text(Fmt.ago(d["createdAt"].double / 1000)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 34, alignment: .trailing)
            }
        }
        .onTapGesture { open() }
        .contextMenu {
            Button { open() } label: { Label(session == nil ? "Open Deployment" : "Open in Bridge", systemImage: "globe") }
            Button { openURL(d["url"].string) } label: { Label("Open in Default Browser", systemImage: "safari") }
            if !d["inspect"].string.isEmpty { Button { openURL(d["inspect"].string) } label: { Label("Inspect on Vercel", systemImage: "triangle") } }
            Divider()
            Button { copyToPasteboard(d["url"].string) } label: { Label("Copy URL", systemImage: "link") }
        }
    }

    /// Like a PR preview: in the browser tab of the session on its branch, else the default browser.
    func open() { model.openPreview(d["url"].string, run: session?.id) }
}

// MARK: incident.io

struct IncidentsView: View {
    @Environment(AppModel.self) var model

    var all: [JSON] { model.incidents["incidents"].array }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Incidents", subtitle: model.incidents["configured"].bool ? "incident.io" : "", icon: "flame") {
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.refreshing.contains("incidents")) { Task { await model.load("incidents", refresh: true) } }
            }
            if let e = model.errors["incidents"], !e.isEmpty { ErrorBar(text: e) }
            if model.incidents.isNull {
                EmptyState(icon: "flame", title: model.loading.contains("incidents") ? "Loading from incident.io…" : "Nothing loaded")
            } else if !model.incidents["configured"].bool {
                SourceSetup(kind: .incidents, how: "An incident.io admin creates API keys under Settings › API keys; one with read access to incidents is enough. Paste it as INCIDENT_API_KEY.")
            } else if all.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "No incidents", detail: "Nothing recent in incident.io.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        group("Active", all.filter { ["live", "triage", "paused"].contains($0["category"].string) }, tint: T.red)
                        group("Post-incident", all.filter { $0["category"].string == "learning" }, tint: T.orange)
                        group("Closed", all.filter { !["live", "triage", "paused", "learning"].contains($0["category"].string) }, tint: T.text3)
                    }
                }
            }
        }
    }

    @ViewBuilder func group(_ title: String, _ items: [JSON], tint: Color) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.self) { IncidentRow(i: $0) }
            } header: {
                GroupHeader(title: title, count: items.count, icon: AnyView(Image(systemName: "flame.fill").font(.system(size: 11)).foregroundStyle(tint)))
            }
        }
    }
}

struct IncidentRow: View {
    let i: JSON
    var live: Bool { ["live", "triage"].contains(i["category"].string) }
    var body: some View {
        HoverRow(height: i["summary"].string.isEmpty ? 44 : 56) {
            HStack(spacing: 12) {
                Text(i["ref"].string).font(T.mono(11.5)).foregroundStyle(T.text3).frame(width: 64, alignment: .leading)
                if !i["severity"].string.isEmpty {
                    Chip(text: i["severity"].string, tint: i["severityRank"].int >= 3 ? T.red : i["severityRank"].int == 2 ? T.orange : T.yellow)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(i["name"].string).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                    if !i["summary"].string.isEmpty { Text(i["summary"].string).font(T.ui(12)).foregroundStyle(T.text3).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Chip(text: i["status"].string, dot: live ? T.red : nil)
                if !i["lead"].string.isEmpty { Avatar(name: i["lead"].string, size: 18).help("Lead: \(i["lead"].string)") }
                Text(Fmt.ago(Fmt.iso(i["createdAt"].string))).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 34, alignment: .trailing)
            }
        }
        .onTapGesture { openURL(i["url"].string) }
        .contextMenu {
            Button { openURL(i["url"].string) } label: { Label("Open in incident.io", systemImage: "flame") }
            if !i["slack"].string.isEmpty { Button { openURL(i["slack"].string) } label: { Label("Open Slack Channel", systemImage: "number") } }
            Divider()
            Button { copyToPasteboard(i["url"].string) } label: { Label("Copy Link", systemImage: "link") }
            Button { copyToPasteboard(i["ref"].string) } label: { Label("Copy Reference", systemImage: "number") }
        }
    }
}

// MARK: Granola

struct GranolaView: View {
    @Environment(AppModel.self) var model
    @StateObject private var selected = Box("")
    @StateObject private var note = Box(JSON.null)

    var notes: [JSON] { model.granola["notes"].array }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Granola", subtitle: model.granola["configured"].bool ? "your meeting notes" : "", icon: "note.text") {
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.refreshing.contains("granola")) { Task { await model.load("granola", refresh: true) } }
            }
            if let e = model.errors["granola"], !e.isEmpty { ErrorBar(text: e) }
            if model.granola.isNull {
                EmptyState(icon: "note.text", title: model.loading.contains("granola") ? "Loading from Granola…" : "Nothing loaded")
            } else if !model.granola["configured"].bool {
                SourceSetup(kind: .granola, how: "In the Granola app: Settings › Connectors › API keys › Create new key (Business and Enterprise plans; on Enterprise an admin turns API access on first). Paste it as GRANOLA_API_KEY.")
            } else if notes.isEmpty {
                EmptyState(icon: "note.text", title: "No notes yet", detail: "Notes show up here once Granola has summarised them.")
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            let days = Dictionary(grouping: notes) { Fmt.day(Fmt.iso($0["createdAt"].string)) }
                            let order = days.keys.sorted { Fmt.iso(days[$0]?.first?["createdAt"].string ?? "") > Fmt.iso(days[$1]?.first?["createdAt"].string ?? "") }
                            ForEach(order, id: \.self) { day in
                                Section {
                                    ForEach(days[day] ?? [], id: \.self) { n in
                                        HoverRow(selected: current == n["id"].string, height: 44) {
                                            HStack(spacing: 10) {
                                                Image(systemName: "note.text").font(.system(size: 12)).foregroundStyle(T.green)
                                                Text(n["title"].string).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                                                Spacer(minLength: 6)
                                                Text(Fmt.time(Fmt.iso(n["createdAt"].string))).font(T.ui(11.5)).foregroundStyle(T.text3)
                                            }
                                        }
                                        .onTapGesture { selected.v = n["id"].string }
                                    }
                                } header: { GroupHeader(title: day) }
                            }
                        }
                    }
                    .frame(width: 380)
                    Rectangle().fill(T.line).frame(width: 1)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task(id: current) { await loadNote() }
            }
        }
    }

    var current: String { selected.v.isEmpty ? notes.first?["id"].string ?? "" : selected.v }

    @ViewBuilder var detail: some View {
        if note.v.isNull {
            ProgressView().controlSize(.small)
        } else if let e = note.v["error"].nonEmpty {
            EmptyState(icon: "exclamationmark.triangle", title: "Couldn't load the note", detail: e)
        } else {
            let n = note.v["note"]
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n["title"].string).font(T.ui(18, .semibold)).foregroundStyle(T.text)
                            Text(Fmt.day(Fmt.iso(n["createdAt"].string)) + " · " + Fmt.time(Fmt.iso(n["createdAt"].string))).font(T.ui(12)).foregroundStyle(T.text3)
                        }
                        Spacer()
                        if !n["url"].string.isEmpty {
                            Button { openURL(n["url"].string) } label: { Label("Open in Granola", systemImage: "arrow.up.right") }.buttonStyle(LButton())
                        }
                    }
                    if !n["attendees"].array.isEmpty {
                        HStack(spacing: -4) {
                            ForEach(n["attendees"].array.prefix(8), id: \.self) { a in Avatar(name: a.string, size: 22).overlay(Circle().stroke(T.panel, lineWidth: 2)).help(a.string) }
                        }
                        Text(n["attendees"].array.map(\.string).joined(separator: ", ")).font(T.ui(12)).foregroundStyle(T.text3)
                    }
                    Hairline()
                    MarkdownText(text: n["summary"].string, size: 13.5)
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    func loadNote() async {
        let id = current
        guard !id.isEmpty else { return }
        note.v = .null
        let out: JSON
        do { out = try await API.get("/api/sources/granola/\(API.q(id))") } catch { out = .obj(["error": .str(error.localizedDescription)]) }
        if current == id { note.v = out }
    }
}
