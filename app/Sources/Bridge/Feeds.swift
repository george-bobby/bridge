import SwiftUI

// MARK: - More sources: Vercel, incident.io, Granola, Datadog, Models
//
// Read-only feeds from server/sources.js (`/api/sources/vercel|incidents|granola|datadog|models`),
// each on its own key in .env. Which sources the sidebar shows is a Settings
// choice (`SourceKind`, UserDefaults `sources.hidden`); a source that isn't
// connected yet says which key it needs.

enum SourceKind: String, CaseIterable, Identifiable {
    case slack, github, linear, vercel, incidents, granola, datadog, models
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
        case .models: return "Models"
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
        case .models: return "cpu"
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
        case .models: return .models
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
        case .models: return "OpenRouter and Anthropic: models, context, prices and spend"
        }
    }
    /// The .env key that connects it, for the ones that need one.
    var key: String? {
        switch self {
        case .vercel: return "VERCEL_TOKEN"
        case .incidents: return "INCIDENT_API_KEY"
        case .granola: return "GRANOLA_API_KEY"
        case .datadog: return "DD_API_KEY"
        case .models: return "OPENROUTER_KEY"
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
        case .models: feed = models
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

// MARK: Models

/// Model providers on their own keys: what each can call, context and output
/// limits, prices per million tokens where the API gives them, and spend.
struct ModelsView: View {
    @Environment(AppModel.self) var model
    @AppStorage("models.tab") private var tab = ""
    @StateObject private var query = Box("")

    var providers: [JSON] { model.models["providers"].array }
    var current: JSON { providers.first { $0["id"].string == tab } ?? providers.first ?? .null }
    var shown: [JSON] {
        let q = query.v.trimmingCharacters(in: .whitespaces).lowercased()
        let all = current["models"].array
        return q.isEmpty ? all : all.filter { "\($0["id"].string) \($0["name"].string)".lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Models", subtitle: current.isNull ? "" : "\(current["models"].array.count) models", icon: "cpu") {
                if providers.count > 1 {
                    SlidingTabs(tabs: providers.map { .init(id: $0["id"].string, label: $0["name"].string, count: $0["models"].array.count) },
                                selection: Binding(get: { current["id"].string }, set: { tab = $0 }))
                }
                if model.models["configured"].bool { SearchField(placeholder: "Filter models", text: $query.v).frame(width: 200) }
                IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: model.refreshing.contains("models")) { Task { await model.load("models", refresh: true) } }
            }
            if let e = model.errors["models"], !e.isEmpty { ErrorBar(text: e) }
            if let e = current["error"].nonEmpty { ErrorBar(text: "\(current["name"].string): \(e)") }
            if model.models.isNull {
                EmptyState(icon: "cpu", title: model.loading.contains("models") ? "Loading models…" : "Nothing loaded")
            } else if !model.models["configured"].bool {
                SourceSetup(kind: .models, how: "Paste an OpenRouter key (openrouter.ai › Settings › Keys) as OPENROUTER_KEY for every model with its context, prices and your spend, and an Anthropic API key (console.anthropic.com) as ANTHROPIC_KEY for the Claude models it can call. Either is enough.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if !current["account"].isNull { AccountStrip(a: current["account"]) }
                        Section {
                            if shown.isEmpty {
                                EmptyState(icon: "magnifyingglass", title: query.v.isEmpty ? "No models" : "No model matches").frame(height: 200)
                            }
                            ForEach(shown, id: \.self) { ModelRow(m: $0) }
                        } header: {
                            GroupHeader(title: current["id"].string == "anthropic" ? "Models · prices aren't in Anthropic's API" : "Models · $ per 1M tokens, in / out", count: shown.count)
                        }
                    }
                }
            }
        }
    }
}

/// Spend and limits for one key, as a row of figures.
struct AccountStrip: View {
    let a: JSON
    var cells: [(String, String)] {
        let usd = { (j: JSON) -> String? in j.isNull ? nil : String(format: "$%.2f", j.double) }
        var out: [(String, String)] = []
        if let v = usd(a["spentDay"]) { out.append(("Today", v)) }
        if let v = usd(a["spentWeek"]) { out.append(("This week", v)) }
        if let v = usd(a["spentMonth"]) { out.append(("This month", v)) }
        if let v = usd(a["spent"]) { out.append(("All time", v)) }
        if let v = usd(a["remaining"]), let l = usd(a["limit"]) { out.append(("Key limit left", "\(v) of \(l)")) }
        if let v = usd(a["balance"]) { out.append(("Credits", v)) }
        return out
    }
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(cells, id: \.0) { c in
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.0).font(T.ui(11.5)).foregroundStyle(T.text3)
                    Text(verbatim: c.1).font(T.mono(14, .medium)).foregroundStyle(T.text)
                }
            }
            Spacer(minLength: 0)
            if let l = a["label"].nonEmpty { Chip(text: l, icon: "key", mono: true) }
            if a["freeTier"].bool { Chip(text: "Free tier") }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

struct ModelRow: View {
    let m: JSON
    var price: String {
        guard !m["input"].isNull, !m["output"].isNull else { return "" }
        if m["input"].double == 0 && m["output"].double == 0 { return "free" }
        let f = { (d: Double) in d >= 10 || d.rounded() == d ? String(format: "%.0f", d) : String(format: "%.2f", d) }
        return "$\(f(m["input"].double)) / $\(f(m["output"].double))"
    }
    var body: some View {
        HoverRow(height: 44) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(m["name"].string).font(T.ui(13, .medium)).foregroundStyle(T.text).lineLimit(1)
                    Text(m["id"].string).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                ForEach(m["capabilities"].array.prefix(3), id: \.self) { Chip(text: $0.string) }
                if let mod = m["modality"].nonEmpty, mod != "text->text" { Chip(text: mod, mono: true) }
                Text(verbatim: m["context"].int > 0 ? Fmt.tokens(m["context"].int) : "")
                    .font(T.mono(11.5)).foregroundStyle(T.text2).frame(width: 52, alignment: .trailing).help("Context window, tokens")
                Text(verbatim: m["maxOutput"].int > 0 ? Fmt.tokens(m["maxOutput"].int) : "")
                    .font(T.mono(11.5)).foregroundStyle(T.text3).frame(width: 48, alignment: .trailing).help("Most output tokens per reply")
                Text(verbatim: price).font(T.mono(11.5)).foregroundStyle(T.text2).frame(width: 96, alignment: .trailing).help("$ per million tokens, input / output")
            }
        }
        .onTapGesture { openURL(m["url"].string) }
        .contextMenu {
            Button { copyToPasteboard(m["id"].string) } label: { Label("Copy Model ID", systemImage: "doc.on.doc") }
            Button { openURL(m["url"].string) } label: { Label("Open Model Page", systemImage: "arrow.up.right") }
        }
    }
}
