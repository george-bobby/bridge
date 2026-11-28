import SwiftUI

/// Settings › Agents › Automation: how far workers go on their own in one
/// project (`auto` on /api/projects). The server renders the enabled ones into
/// each worker's prompt; auto-merge also relaxes the guard's merge gate.
struct ProjectAutomation: View {
    @Environment(AppModel.self) var model
    let q: String
    @StateObject private var picked = Box("default")
    /// Switches flipped here, shown until the server's copy catches up.
    @StateObject private var pending = Box([String: Bool]())
    /// The accounts `gh` is logged in to (`/api/github/accounts`).
    @StateObject private var accounts = Box([JSON]())

    static let toggles: [(key: String, title: String, detail: String, on: Bool)] = [
        ("merge", "Merge PRs when green", "Workers merge their own PR once CI passes and it's mergeable; never an admin merge", false),
        ("review", "Review PRs", "Run the review flow (/review where installed) after opening a PR", false),
        ("resolve", "Resolve review comments", "Fix the real ones and reply to every thread", false),
        ("rebase", "Rebase before every push", "Onto origin/main; off makes it only for conflicts", true),
        ("decide", "Take small decisions", "Go with the recommended option instead of asking; costly calls still ask", false),
    ]

    var project: Project? { model.projects.first { $0.id == picked.v } ?? model.projects.first }

    func value(_ p: Project, _ t: (key: String, title: String, detail: String, on: Bool)) -> Bool {
        if let v = pending.v["\(p.id).\(t.key)"] { return v }
        let j = p.j["auto"][t.key]
        return j.isNull ? t.on : j.bool
    }

    var body: some View {
        if let p = project {
            SSection(title: "Automation", detail: "What workers in \(p.name) do without asking. Slack, Linear and new threads always stay drafts") {
                identityRows(p)
                ForEach(Self.toggles.filter { Prefs.hit(q, $0.title, $0.detail, "automation auto merge review resolve rebase decide") }, id: \.key) { t in
                    SRow(title: t.title, detail: t.detail) {
                        SToggle(on: Binding(get: { value(p, t) }, set: { v in
                            pending.v["\(p.id).\(t.key)"] = v
                            Task { await model.updateProject(p.id, ["auto": [t.key: v]]) }
                        }))
                    }
                }
            } trailing: {
                SSelect(value: p.id, choices: model.projects.map { ($0.id, $0.name) }) { picked.v = $0 }
            }
            .onChange(of: model.projects) { pending.v = [:] }
            .task {
                if let out = try? await API.get("/api/github/accounts") { accounts.v = out["accounts"].array }
                if model.identity.isNull { await model.loadIdentity() }
            }
        }
    }

    /// GitHub account (commits, gh and pushes) and Linear team for the project.
    @ViewBuilder func identityRows(_ p: Project) -> some View {
        if Prefs.hit(q, "github account commit push gh") {
            SRow(title: "GitHub account", detail: "Workers commit, push and use gh as this account; your active gh account stays as it is") {
                SSelect(value: p.j["github"]["login"].string, choices: githubChoices(p)) { v in
                    Task { await model.updateProject(p.id, ["github": v]) }
                }
            }
        }
        if Prefs.hit(q, "linear team key issues branches") {
            SRow(title: "Linear team", detail: "Issues and branch names for this project; overrides the team in Integrations") {
                SSelect(value: p.j["linear"].string, choices: linearChoices(p)) { v in
                    Task { await model.updateProject(p.id, ["linear": v]) }
                }
            }
        }
    }

    func githubChoices(_ p: Project) -> [(String, String)] {
        var out: [(String, String)] = [("", "gh's active account")]
        for a in accounts.v { out.append((a["login"].string, a["login"].string)) }
        let cur = p.j["github"]["login"].string
        if !cur.isEmpty && !out.contains(where: { $0.0 == cur }) { out.append((cur, cur)) }
        return out
    }

    func linearChoices(_ p: Project) -> [(String, String)] {
        var out: [(String, String)] = [("", "Integrations' team")]
        for t in model.identity["linear"]["teams"].array { out.append((t["key"].string, "\(t["name"].string) · \(t["key"].string)")) }
        let cur = p.j["linear"].string
        if !cur.isEmpty && !out.contains(where: { $0.0 == cur }) { out.append((cur, cur)) }
        return out
    }
}
