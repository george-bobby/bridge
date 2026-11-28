import SwiftUI

// MARK: - More sources: Vercel, incident.io, Granola, Datadog, Modal
//
// Read-only feeds from server/sources.js (`/api/sources/vercel|incidents|granola|datadog|modal`),
// each on its own key in .env (Modal: the modal CLI, on its token pair or profile). Which sources the sidebar shows is a Settings
// choice (`SourceKind`, UserDefaults `sources.hidden`); a source that isn't
// connected yet says which key it needs.

enum SourceKind: String, CaseIterable, Identifiable {
    case slack, github, linear, vercel, incidents, granola, datadog, modal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .slack: return "Slack"
        case .github: return "GitHub"
        case .linear: return "Linear"
        case .vercel: return "Vercel"
        case .incidents: return "Incidents"
        case .granola: return "Granola"
        case .datadog: return "Datadog"
        case .modal: return "Modal"
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
        case .datadog: return "waveform.path.ecg"
        case .modal: return "server.rack"
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
        case .datadog: return .datadog
        case .modal: return .modal
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
        case .datadog: return "Datadog: alerting monitors and error issues"
        case .modal: return "Modal: apps, live containers, GPUs and spend"
        }
    }
    /// The .env key that connects it, for the ones that need one.
    var key: String? {
        switch self {
        case .vercel: return "VERCEL_TOKEN"
        case .incidents: return "INCIDENT_API_KEY"
        case .granola: return "GRANOLA_API_KEY"
        case .datadog: return "DD_API_KEY"
        case .modal: return "MODAL_TOKEN_ID"
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
    /// In the sidebar and connected (or not loaded yet): ⌘K leaves the rest out.
    func sourceLive(_ s: SourceKind) -> Bool {
        guard sourceShown(s) else { return false }
        let feed: JSON
        switch s {
        case .slack: feed = slack
        case .linear: feed = linear
        case .vercel: feed = vercel
        case .incidents: feed = incidents
        case .granola: feed = granola
        case .datadog: feed = datadog
        case .modal: feed = modal
        case .github: return true
        }
        return feed["configured"].isNull || feed["configured"].bool
    }
    /// A page that isn't a source, or a source that's live.
    func routeLive(_ r: Route) -> Bool {
        guard let s = SourceKind.allCases.first(where: { $0.route == r }) else { return true }
        return sourceLive(s)
    }
    func setSource(_ s: SourceKind, shown: Bool) {
        var h = hiddenSources
        if shown { h.remove(s.rawValue) } else { h.insert(s.rawValue) }
        withAnimation(M.snappy) { hiddenSources = h }
        UserDefaults.standard.set(h.sorted().joined(separator: ","), forKey: Sources.key)
        if shown { Task { if s == .slack { await loadSlack() } else { await load(s == .github ? "pulls" : s.rawValue) } } }
    }
    var vercelDeployments: [JSON] { vercel["deployments"].array }
    var alertingMonitors: [JSON] { datadog["monitors"].array.filter { $0["status"].string == "alert" && !$0["muted"].bool } }
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
            if !blocked.isEmpty { ErrorBar(text: blockedText) }
            if model.vercel.isNull {
                EmptyState(icon: "triangle", title: model.loading.contains("vercel") ? "Loading from Vercel…" : "Nothing loaded")
            } else if !model.vercel["configured"].bool {
                SourceSetup(kind: .vercel, how: "Create a token at vercel.com › Account Settings › Tokens (any Vercel account can), then paste it as VERCEL_TOKEN. A team that enforces SAML needs a token scoped to it: add one per team, comma-separated. Bridge only reads deployments.")
            } else if shown.isEmpty {
                EmptyState(icon: "checkmark.circle", title: "Nothing here", detail: blocked.isEmpty || !all.isEmpty ? "No deployments in this view." : "No deployments in the teams this token can read.")
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

extension VercelView {
    /// Teams no token could read (SAML-enforced ones need a token made for them).
    var blocked: [JSON] { model.vercel["blocked"].array }
    var blockedText: String {
        let names = blocked.map(\.["team"].string).joined(separator: ", ")
        if blocked.allSatisfy({ $0["saml"].bool }) {
            return "Can't read \(names): SAML is enforced there. Create a token with that team as its scope (Account Settings › Tokens) and add it to VERCEL_TOKEN, comma-separated."
        }
        return "Can't read \(names): " + blocked.map(\.["reason"].string).joined(separator: "; ")
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

extension AppModel {
    /// Granola's notes, only your own when Settings › Integrations › Granola says so
    /// (and the server knew who you are: git's user.email).
    var granolaNotes: [JSON] {
        let all = granola["notes"].array
        guard config["harness"]["granolaMine"].bool, !granola["me"].string.isEmpty else { return all }
        return all.filter { $0["mine"].bool }
    }
}

struct GranolaView: View {
    @Environment(AppModel.self) var model
    @StateObject private var selected = Box("")
    @StateObject private var note = Box(JSON.null)

    var notes: [JSON] { model.granolaNotes }

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
                EmptyState(icon: "note.text", title: "No notes yet", detail: model.granola["notes"].array.isEmpty ? "Notes show up here once Granola has summarised them." : "Only my notes is on (Settings › Integrations › Granola): the recent ones are all shared with you.")
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

// MARK: Datadog

struct DatadogView: View {
    @Environment(AppModel.self) var model
    @AppStorage("datadog.tab") private var tab = "monitors"

    var monitors: [JSON] { model.datadog["monitors"].array }
    var issues: [JSON] { model.datadog["issues"].array }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Datadog", subtitle: model.datadog["site"].string, icon: "waveform.path.ecg") {
                if model.datadog["configured"].bool {
                    SlidingTabs(tabs: [
                        .init(id: "monitors", label: "Monitors", count: model.alertingMonitors.count, hot: true),
                        .init(id: "errors", label: "Errors", count: issues.count),
                    ], selection: $tab)
                }
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.refreshing.contains("datadog")) { Task { await model.load("datadog", refresh: true) } }
            }
            if let e = model.errors["datadog"], !e.isEmpty { ErrorBar(text: e) }
            if let e = model.datadog["errors"][tab == "errors" ? "issues" : "monitors"].nonEmpty { ErrorBar(text: e) }
            if model.datadog.isNull {
                EmptyState(icon: "waveform.path.ecg", title: model.loading.contains("datadog") ? "Loading from Datadog…" : "Nothing loaded")
            } else if !model.datadog["configured"].bool {
                SourceSetup(kind: .datadog, how: "Paste an API key (Organization Settings › API Keys) as DD_API_KEY and an application key with monitors_read and error_tracking_read (Personal Settings › Application Keys) as DD_APP_KEY. Set DD_SITE if your org isn't on datadoghq.com (e.g. us5.datadoghq.com).")
            } else if tab == "errors" {
                if issues.isEmpty {
                    EmptyState(icon: "checkmark.circle", title: "No open issues", detail: "Nothing new in Error Tracking in the last day.")
                } else {
                    ScrollView { LazyVStack(spacing: 0) { ForEach(issues, id: \.self) { ErrorIssueRow(i: $0) } } }
                }
            } else if monitors.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "All clear", detail: "No monitor is alerting, warning or missing data.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        group("Alert", "alert", tint: T.red)
                        group("Warn", "warn", tint: T.orange)
                        group("No data", "nodata", tint: T.text3)
                    }
                }
            }
        }
    }

    @ViewBuilder func group(_ title: String, _ status: String, tint: Color) -> some View {
        let items = monitors.filter { $0["status"].string == status }
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.self) { MonitorRow(m: $0, tint: tint) }
            } header: {
                GroupHeader(title: title, count: items.count, icon: AnyView(Circle().fill(tint).frame(width: 7, height: 7)))
            }
        }
    }
}

struct MonitorRow: View {
    let m: JSON
    let tint: Color
    var body: some View {
        HoverRow(height: 44) {
            HStack(spacing: 12) {
                if m["status"].string == "alert" && !m["muted"].bool { PulseDot(color: tint) } else { Circle().fill(tint).frame(width: 7, height: 7) }
                if m["priority"].int > 0 { Chip(text: "P\(m["priority"].int)", tint: m["priority"].int <= 2 ? T.red : nil, mono: true) }
                Text(m["name"].string).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 8)
                ForEach(m["tags"].array.prefix(2), id: \.self) { Chip(text: $0.string, mono: true) }
                if m["muted"].bool { Image(systemName: "bell.slash").font(.system(size: 11)).foregroundStyle(T.text3).help("Muted") }
                Text(m["triggeredAt"].double > 0 ? Fmt.ago(m["triggeredAt"].double / 1000) : "").font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 34, alignment: .trailing)
            }
        }
        .onTapGesture { openURL(m["url"].string) }
        .contextMenu {
            Button { openURL(m["url"].string) } label: { Label("Open in Datadog", systemImage: "waveform.path.ecg") }
            Divider()
            Button { copyToPasteboard(m["url"].string) } label: { Label("Copy Link", systemImage: "link") }
        }
    }
}

struct ErrorIssueRow: View {
    let i: JSON
    var body: some View {
        HoverRow(height: 56) {
            HStack(spacing: 12) {
                Text(verbatim: i["count"].int >= 1000 ? String(format: "%.1fk", Double(i["count"].int) / 1000) : "\(i["count"].int)")
                    .font(T.mono(11.5, .medium)).foregroundStyle(T.text2).frame(width: 44, alignment: .trailing)
                    .help("Errors in the last day")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(i["type"].nonEmpty ?? "Error").font(T.ui(13, .semibold)).foregroundStyle(T.text).lineLimit(1)
                        Text(i["message"].string).font(T.ui(13)).foregroundStyle(T.text2).lineLimit(1)
                    }
                    Text(i["where"].string).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if i["state"].string == "acknowledged" { Chip(text: "Acknowledged") }
                if !i["service"].string.isEmpty { Chip(text: i["service"].string, mono: true) }
                Text(Fmt.ago(i["lastSeen"].double / 1000)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 34, alignment: .trailing).help("Last seen")
            }
        }
        .onTapGesture { openURL(i["url"].string) }
        .contextMenu {
            Button { openURL(i["url"].string) } label: { Label("Open in Datadog", systemImage: "waveform.path.ecg") }
            Divider()
            Button { copyToPasteboard(i["url"].string) } label: { Label("Copy Link", systemImage: "link") }
            Button { copyToPasteboard([i["type"].string, i["message"].string].filter { !$0.isEmpty }.joined(separator: ": ")) } label: { Label("Copy Error", systemImage: "doc.on.doc") }
        }
    }
}

// MARK: Modal

/// Modal (modal.com): apps per environment with their running containers and
/// today's cost, live containers, and this month's bill. One app's functions,
/// last hour's calls and deploys load on selection (`/api/sources/modal/:id`).
struct ModalView: View {
    @Environment(AppModel.self) var model
    @AppStorage("modal.tab") private var tab = "apps"
    @StateObject private var query = Box("")

    var feed: JSON { model.modal }
    var apps: [JSON] {
        let q = query.v.trimmingCharacters(in: .whitespaces).lowercased()
        let all = feed["apps"].array
        return q.isEmpty ? all : all.filter { "\($0["name"].string) \($0["id"].string) \($0["env"].string)".lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Modal", subtitle: feed["workspace"].string, icon: SourceKind.modal.icon) { actions }
            if let e = model.errors["modal"], !e.isEmpty { ErrorBar(text: e) }
            if let e = feed["errors"]["containers"].nonEmpty, tab == "containers" { ErrorBar(text: e) }
            content
        }
    }

    @ViewBuilder var actions: some View {
        if feed["configured"].bool {
            SlidingTabs(tabs: [
                .init(id: "apps", label: "Apps", count: feed["apps"].array.count),
                .init(id: "containers", label: "Containers", count: feed["containers"].array.count, hot: true),
            ], selection: $tab)
            if tab == "apps" { SearchField(placeholder: "Filter apps", text: $query.v).frame(width: 180) }
            IconButton(icon: "arrow.up.right", help: "Open the Modal dashboard") { openURL(feed["dashboard"].string) }
        }
        IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.refreshing.contains("modal")) { Task { await model.load("modal", refresh: true) } }
    }

    @ViewBuilder var content: some View {
        if feed.isNull {
            EmptyState(icon: SourceKind.modal.icon, title: model.loading.contains("modal") ? "Loading from Modal…" : "Nothing loaded")
        } else if !feed["configured"].bool {
            SourceSetup(kind: .modal, how: "Bridge reads Modal through the modal CLI. Sign it in once with `modal setup` (it saves ~/.modal.toml), or paste a token pair from modal.com › Settings › API Tokens as MODAL_TOKEN_ID and MODAL_TOKEN_SECRET.")
        } else {
            ModalSpend(feed: feed)
            Hairline()
            if tab == "containers" { ModalContainers(items: feed["containers"].array) } else { ModalApps(apps: apps, filtered: !query.v.isEmpty) }
        }
    }
}

/// This month's bill and today's GPU spend, from Modal's billing API (needs a
/// workspace manager; otherwise it says so).
struct ModalSpend: View {
    let feed: JSON
    var spend: JSON { feed["spend"] }
    var cells: [(String, String)] {
        let usd = { (j: JSON) -> String? in j.isNull ? nil : Burn.money(j.double) }
        var out: [(String, String)] = []
        if let v = usd(spend["billed"]) { out.append(("Billed this month", v)) }
        if let v = usd(spend["metered"]) { out.append(("Metered", v)) }
        if spend["credits"].double > 0, let v = usd(spend["credits"]) { out.append(("Credits", v)) }
        if let v = usd(spend["today"]) { out.append(("Today", v)) }
        return out
    }
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            if spend.isNull {
                Text(feed["errors"]["billing"].nonEmpty.map { "Billing: \($0)" } ?? "No billing data")
                    .font(T.ui(12)).foregroundStyle(T.text3).lineLimit(2)
            }
            ForEach(cells, id: \.0) { c in
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.0).font(T.ui(11.5)).foregroundStyle(T.text3)
                    Text(verbatim: c.1).font(T.mono(14, .medium)).foregroundStyle(T.text)
                }
            }
            Spacer(minLength: 0)
            gpus
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { openURL(feed["usage"].string) }
        .help("Open usage in Modal")
    }
    @ViewBuilder var gpus: some View {
        let g = feed["gpus"].array
        if !g.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                Text("GPU spend today").font(T.ui(11.5)).foregroundStyle(T.text3)
                HStack(spacing: 2) {
                    ForEach(g.prefix(4), id: \.self) { Chip(text: "\($0["type"].string) \(Burn.money($0["cost"].double))", icon: "cpu", mono: true) }
                }
            }
        }
    }
}

/// Apps grouped by environment, with the selected one's details beside them.
struct ModalApps: View {
    let apps: [JSON]
    let filtered: Bool
    @StateObject private var selected = Box("")
    var current: JSON { apps.first { $0["id"].string == selected.v } ?? apps.first ?? .null }

    var body: some View {
        if apps.isEmpty {
            EmptyState(icon: "magnifyingglass", title: filtered ? "No app matches" : "No apps", detail: filtered ? "" : "Nothing deployed or running in any environment.")
        } else {
            HStack(spacing: 0) {
                list.frame(width: 420)
                Rectangle().fill(T.line).frame(width: 1)
                ModalAppDetail(app: current).id(current["id"].string).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                let envs = apps.reduce(into: [String]()) { if !$0.contains($1["env"].string) { $0.append($1["env"].string) } }
                ForEach(envs, id: \.self) { env in
                    let items = apps.filter { $0["env"].string == env }
                    Section {
                        ForEach(items, id: \.self) { a in
                            ModalAppRow(a: a, selected: current["id"].string == a["id"].string).onTapGesture { selected.v = a["id"].string }
                        }
                    } header: { GroupHeader(title: env, count: items.count) }
                }
            }
        }
    }
}

/// deployed + running · deployed idle · ephemeral · stopped.
func modalStateTint(_ a: JSON) -> Color {
    let s = a["state"].string
    if s.hasPrefix("stop") { return T.red }
    if s.hasPrefix("ephemeral") { return T.orange }
    return a["tasks"].int > 0 ? T.green : T.text3
}

struct ModalAppRow: View {
    let a: JSON
    let selected: Bool
    var body: some View {
        HoverRow(selected: selected, height: 48) {
            HStack(spacing: 10) {
                if a["tasks"].int > 0 { PulseDot(color: modalStateTint(a)) } else { Circle().fill(modalStateTint(a)).frame(width: 6, height: 6) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(a["name"].string).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                    Text(subtitle).font(T.ui(11)).foregroundStyle(T.text3).lineLimit(1)
                }
                Spacer(minLength: 6)
                ForEach(a["gpus"].array.prefix(2), id: \.self) { Chip(text: $0.string, icon: "cpu", mono: true) }
                Text(verbatim: a["costToday"].isNull ? "" : Burn.money(a["costToday"].double))
                    .font(T.mono(11.5)).foregroundStyle(T.text2).frame(width: 64, alignment: .trailing).help("Cost today")
            }
        }
        .contextMenu {
            Button { openURL(a["url"].string) } label: { Label("Open in Modal", systemImage: "arrow.up.right") }
            Divider()
            Button { copyToPasteboard(a["id"].string) } label: { Label("Copy App ID", systemImage: "doc.on.doc") }
        }
    }
    var subtitle: String {
        var parts = [a["state"].string]
        if a["tasks"].int > 0 { parts.append(a["tasks"].int == 1 ? "1 container" : "\(a["tasks"].int) containers") }
        if a["createdAt"].double > 0 { parts.append("created \(Fmt.ago(a["createdAt"].double / 1000))") }
        return parts.joined(separator: " · ")
    }
}

/// One app's lifecycle, functions (web URL, schedule, GPU, last hour's calls)
/// and recent deploys.
struct ModalAppDetail: View {
    let app: JSON
    @StateObject private var out = Box(JSON.null)
    var d: JSON { out.v["app"] }

    var body: some View {
        Group {
            if out.v.isNull {
                ProgressView().controlSize(.small)
            } else if let e = out.v["error"].nonEmpty {
                EmptyState(icon: "exclamationmark.triangle", title: "Couldn't load the app", detail: e)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        functions
                        deploys
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
        .task(id: app["id"].string) { await load() }
    }

    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(d["name"].string).font(T.ui(18, .semibold)).foregroundStyle(T.text)
                Text(lifecycle).font(T.ui(12)).foregroundStyle(T.text3)
            }
            Spacer()
            Button { openURL(d["url"].string) } label: { Label("Open in Modal", systemImage: "arrow.up.right") }.buttonStyle(LButton())
        }
    }
    var lifecycle: String {
        var parts = [d["state"].string, app["env"].string]
        if d["version"].int > 0 { parts.append("v\(d["version"].int)") }
        if d["deployedAt"].double > 0 { parts.append("deployed \(Fmt.ago(d["deployedAt"].double / 1000)) ago by \(d["deployedBy"].string)") }
        if d["stoppedAt"].double > 0 { parts.append("stopped \(Fmt.ago(d["stoppedAt"].double / 1000)) ago" + (d["stoppedBy"].string.isEmpty ? "" : " by \(d["stoppedBy"].string)")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder var functions: some View {
        let fns = d["functions"].array
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "Functions · calls in the last hour", count: fns.count)
            ForEach(fns, id: \.self) { ModalFunctionRow(f: $0) }
        }
    }

    @ViewBuilder var deploys: some View {
        let h = d["history"].array
        if !h.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader(title: "Deploys", count: h.count)
                ForEach(h, id: \.self) { v in
                    HStack(spacing: 10) {
                        Text(v["version"].string).font(T.mono(11.5, .medium)).foregroundStyle(T.text).frame(width: 44, alignment: .leading)
                        Text(v["by"].string).font(T.ui(12.5)).foregroundStyle(T.text2)
                        if !v["commit"].string.isEmpty { Chip(text: v["commit"].string, mono: true) }
                        Spacer()
                        Text(Fmt.day(v["at"].double / 1000) + " · " + Fmt.time(v["at"].double / 1000)).font(T.ui(11.5)).foregroundStyle(T.text3)
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                }
            }
        }
    }

    func load() async {
        out.v = .null
        let id = app["id"].string
        guard !id.isEmpty else { return }
        do { out.v = try await API.get("/api/sources/modal/\(API.q(id))?env=\(API.q(app["env"].string))") } catch { out.v = .obj(["error": .str(error.localizedDescription)]) }
    }
}

struct ModalFunctionRow: View {
    let f: JSON
    var s: JSON { f["stats"] }
    var body: some View {
        HoverRow(height: f["webUrl"].string.isEmpty ? 36 : 48) {
            HStack(spacing: 10) {
                Image(systemName: f["web"].bool ? "globe" : f["schedule"].string.isEmpty ? "function" : "clock").font(.system(size: 11)).foregroundStyle(T.text3).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f["name"].string).font(T.mono(12.5, .medium)).foregroundStyle(T.text).lineLimit(1)
                    if !f["webUrl"].string.isEmpty { Text(f["webUrl"].string).font(T.mono(11)).foregroundStyle(T.accent).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 6)
                if !f["schedule"].string.isEmpty { Chip(text: f["schedule"].string, mono: true) }
                ForEach(f["gpus"].array.prefix(2), id: \.self) { Chip(text: $0.string, icon: "cpu", mono: true) }
                calls
            }
        }
        .onTapGesture { openURL(f["webUrl"].string.isEmpty ? f["url"].string : f["webUrl"].string) }
        .contextMenu {
            Button { openURL(f["url"].string) } label: { Label("Open in Modal", systemImage: "arrow.up.right") }
            if !f["webUrl"].string.isEmpty {
                Button { openURL(f["webUrl"].string) } label: { Label("Open Endpoint", systemImage: "globe") }
                Button { copyToPasteboard(f["webUrl"].string) } label: { Label("Copy Endpoint URL", systemImage: "link") }
            }
        }
    }
    @ViewBuilder var calls: some View {
        if !s.isNull {
            let bad = s["failed"].int + s["timedOut"].int + s["containerErrors"].int
            HStack(spacing: 8) {
                if s["running"].int > 0 { Text(verbatim: "\(s["running"].int) running").foregroundStyle(T.green) }
                Text(verbatim: "\(Burn.count(s["ok"].int)) ok").foregroundStyle(T.text2)
                if bad > 0 { Text(verbatim: "\(bad) failed").foregroundStyle(T.red).help("\(s["failed"].int) failed, \(s["timedOut"].int) timed out, \(s["containerErrors"].int) container errors") }
            }
            .font(T.mono(11.5))
        }
    }
}

struct ModalContainers: View {
    let items: [JSON]
    var body: some View {
        if items.isEmpty {
            EmptyState(icon: "shippingbox", title: "No containers running", detail: "Containers show up here while an app is serving or working.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.self) { c in
                        HoverRow(height: 40) {
                            HStack(spacing: 10) {
                                PulseDot(color: T.green)
                                Text(c["app"].string).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                                Chip(text: c["env"].string)
                                Spacer(minLength: 6)
                                Text(c["id"].string).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1)
                                Text(Fmt.ago(c["startedAt"].double / 1000)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 34, alignment: .trailing).help("Started")
                            }
                        }
                        .onTapGesture { openURL(c["url"].string) }
                        .contextMenu {
                            Button { openURL(c["url"].string) } label: { Label("Open in Modal", systemImage: "arrow.up.right") }
                            Button { copyToPasteboard(c["id"].string) } label: { Label("Copy Container ID", systemImage: "doc.on.doc") }
                        }
                    }
                }
            }
        }
    }
}
