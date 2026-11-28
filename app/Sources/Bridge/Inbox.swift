import AppKit
import SwiftUI

// MARK: - Inbox

/// Everything waiting on you, one tab per kind. Every item opens its chat.
struct InboxView: View {
    @Environment(AppModel.self) var model
    @StateObject private var activity = Box(JSON.null)
    @StateObject private var since = Box("24h")

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) { content }.padding(.bottom, 14)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.inboxTab) { if model.inboxTab == "activity" { load() } }
    }

    var header: some View {
        PageHeader(title: "Inbox", icon: "tray") {
            SlidingTabs(tabs: [
                .init(id: "normal", label: "Normal", icon: "bell"),
                .init(id: "quiet", label: "Quiet", icon: "moon"),
                .init(id: "away", label: "Away", icon: "airplane"),
            ], selection: Binding(get: { model.inbox["mode"].nonEmpty ?? "normal" }, set: { m in Task { await model.setMode(m) } }))
            .help("Normal relays everything to the orchestrator; quiet only what needs you; away holds it all for one catch-up")
            BriefButton(orchestrator: model.orchestrator?.id ?? "orchestrator")
        }
    }

    var tabBar: some View {
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SlidingTabs(tabs: [
                    .init(id: "decisions", label: "Needs you", count: model.decisions.count + model.permissions.count, hot: true),
                    .init(id: "slack", label: "Slack", count: model.slackOpenCount, hot: model.slackOpenCount > 0),
                    .init(id: "todos", label: "To-dos", count: model.todos.count),
                    .init(id: "activity", label: "Activity"),
                ], selection: $m.inboxTab)
                Spacer()
                if model.inboxTab == "slack" { SlackWatchBar().transition(.opacity.combined(with: .move(edge: .trailing))) }
                if model.inboxTab == "activity" {
                    SlidingTabs(tabs: ["3h", "8h", "24h", "3d"].map { .init(id: $0, label: $0) }, selection: $since.v)
                        .onChange(of: since.v) { load() }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(height: 50)
            Text(hint).font(T.ui(12)).foregroundStyle(T.text3).padding(.bottom, 12)
        }
        .animation(M.snappy, value: model.inboxTab)
        .padding(.horizontal, 20)
    }

    /// What the open tab is for, in one line.
    var hint: String {
        switch model.inboxTab {
        case "decisions": return "Questions and approvals your sessions are waiting on. Answer here, or click a card to open its chat."
        case "slack": return "Slack mentions and posts in channels you watch that no session has picked up yet."
        case "todos": return "Things only you can do, like merging a PR or adding a token. Tick one off when it's done; click it to open its chat."
        default: return "What happened across your sessions, newest first. Click a row to open its chat."
        }
    }

    @ViewBuilder var content: some View {
        switch model.inboxTab {
        case "decisions":
            if model.decisions.isEmpty && model.permissions.isEmpty { EmptyState(icon: "checkmark.circle", title: "You're all caught up", detail: "When a session needs an answer or your OK, it lands here.") }
            ForEach(model.permissions, id: \.self) { PermissionRow(p: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
            ForEach(model.decisions, id: \.self) { DecisionRow(d: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
        case "slack":
            if model.slackItems.isEmpty {
                EmptyState(icon: "number", title: "Nothing new on Slack", detail: model.slack["configured"].bool ? "Mentions and posts in the channels you watch land here until you start or dismiss them." : "Connect Slack in Settings › Integrations to have mentions land here.")
            }
            ForEach(model.slackItems, id: \.self) { SlackItemRow(item: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
        case "todos":
            if model.todos.isEmpty { EmptyState(icon: "checklist", title: "No to-dos", detail: "Things only you can do, like merging a PR or adding a token, show up here.") }
            ForEach(model.todos, id: \.self) { TodoRow(t: $0).transition(.opacity.combined(with: .move(edge: .trailing))) }
        default:
            let ev = Array(activity.v["events"].array.reversed())
            if ev.isEmpty { EmptyState(icon: "clock", title: "Quiet", detail: "Nothing happened in the last \(since.v).") }
            ForEach(Array(ev.enumerated()), id: \.offset) { _, e in ActivityRow(e: e) }
        }
    }

    func load() {
        Task {
            if let a = try? await API.get("/api/catchup?since=\(since.v)") { activity.v = a }
        }
    }
}

/// How each kind of ask reads: its name, what acting on it does, its button.
private struct AskStyle {
    let label: String, icon: String, tint: Color, hint: String, verb: String, placeholder: String

    init(_ kind: String, options: Bool) {
        switch kind {
        case "action":
            (label, icon, tint, verb) = ("Approval", "hand.raised.fill", T.orange, "Approve")
            hint = "Approve sends the session to make this write; you see the exact payload once more before it goes out."
            placeholder = "Anything to add (optional)"
        case "resume":
            (label, icon, tint, verb) = ("Stopped", "arrow.clockwise.circle.fill", T.yellow, "Resume")
            hint = "The session stopped before it finished. Resume picks it up where it left off."
            placeholder = "Note for the session (optional)"
        default:
            (label, icon, tint, verb) = ("Question", "questionmark.circle.fill", T.accent, options ? "Send" : "Answer")
            hint = options ? "Pick an option, or write your own. It goes back to the session as its next message." : "Your answer goes back to the session as its next message."
            placeholder = options ? "Or write your own answer" : "Your answer"
        }
    }
}

/// One ask: the question, why it matters, its options as buttons. Click the
/// top of the card to open the chat it came from.
struct DecisionRow: View {
    @Environment(AppModel.self) var model
    let d: JSON
    @StateObject private var answer = Box("")

    var kind: String { d["kind"].string }
    var options: [JSON] { kind == "question" ? d["options"].array : [] }
    private var style: AskStyle { AskStyle(kind, options: !options.isEmpty) }
    var typed: String { answer.v.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            if !options.isEmpty { choices }
            controls
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.line, lineWidth: 1))
        .padding(.horizontal, 20).padding(.top, 14)
    }

    var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Chip(text: style.label, icon: style.icon, tint: style.tint)
                Text(d["title"].nonEmpty ?? d["taskId"].string).font(T.ui(12.5, .medium)).foregroundStyle(T.text2).lineLimit(1)
                Spacer()
                Text(Fmt.ago(d["createdAt"].double)).font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            Text(inline(d["question"].nonEmpty ?? d["text"].string)).font(T.ui(14, .semibold)).foregroundStyle(T.text)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = d["detail"].nonEmpty {
                Text(inline(detail)).font(T.ui(12.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            }
            Text(style.hint).font(T.ui(11.5)).foregroundStyle(T.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.open(d["taskId"].string) }
        .help("Open the chat")
    }

    var choices: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { o in
                Button { pick(o) } label: {
                    HStack(spacing: 8) {
                        Text(o["key"].string).font(T.mono(11.5, .semibold))
                        Text(inline(o["label"].string)).lineLimit(1)
                        if o["recommended"].bool { Text("Recommended").font(T.ui(11, .medium)).opacity(0.75) }
                    }
                }
                .buttonStyle(LButton(primary: o["recommended"].bool))
                .help(o["label"].string)
            }
        }
    }

    var controls: some View {
        HStack(spacing: 8) {
            LField(placeholder: style.placeholder, text: $answer.v) { send() }
            if kind == "question" {
                Button(style.verb) { send() }.buttonStyle(LButton(primary: options.isEmpty)).disabled(typed.isEmpty)
            } else {
                if kind == "action" { Button("Decline") { submit("dismiss") }.buttonStyle(LButton()).help("Don't make this write") }
                Button(style.verb) { submit("answer", typed) }.buttonStyle(LButton(primary: true))
            }
            Button { model.open(d["taskId"].string) } label: { Label("Open chat", systemImage: "arrow.up.right") }.buttonStyle(LButton())
            MoreMenu(help: "Later, or dismiss") {
                Button("Remind me tomorrow") { submit("defer", tomorrow()) }
                Button("Dismiss") { submit("dismiss") }
            }
        }
    }

    /// An option goes back as written ("B) Per IP"), with anything typed below it.
    func pick(_ o: JSON) {
        let choice = "\(o["key"].string)) \(o["label"].string)"
        submit("answer", typed.isEmpty ? choice : "\(choice)\n\(typed)")
    }

    func send() {
        if kind == "question" && typed.isEmpty { return }
        submit("answer", typed)
    }

    func tomorrow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date().addingTimeInterval(86400))
    }

    func submit(_ action: String, _ value: String = "") {
        Task { await model.decide(d["id"].string, action: action, answer: value) }
    }
}

/// A live allow/deny prompt a session is blocked on. Allow runs the call
/// once; Always allow (offered when the agent proposed its own rules) also
/// trusts them for calls like it. Click the card's top to open the chat.
struct PermissionRow: View {
    @Environment(AppModel.self) var model
    let p: JSON
    @StateObject private var busy = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            controls
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.orange.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 20).padding(.top, 14)
        .disabled(busy.v)
    }

    var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Chip(text: "Permission", icon: "lock.open.fill", tint: T.orange)
                Text(p["title"].nonEmpty ?? p["runId"].string).font(T.ui(12.5, .medium)).foregroundStyle(T.text2).lineLimit(1)
                Spacer()
                Text(Fmt.ago(p["askedAt"].double)).font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            Text("Allow \(p["display"].nonEmpty ?? p["tool"].string)?").font(T.ui(14, .semibold)).foregroundStyle(T.text)
            RichText(plain: p["command"].nonEmpty ?? p["summary"].string, font: .monospacedSystemFont(ofSize: 11.5, weight: .regular), color: NT.text)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.panel))
            if let d = p["description"].nonEmpty { Text(inline(d)).font(T.ui(12.5)).foregroundStyle(T.text2) }
            if let r = p["reason"].nonEmpty { Text(inline(r)).font(T.ui(12)).foregroundStyle(T.orange) }
            Text(p["always"].bool ? "Allow runs it once; Always allow also trusts the rules the agent proposed for calls like it." : "This call is gated by the harness policy; Allow runs it once.")
                .font(T.ui(11.5)).foregroundStyle(T.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.open(p["runId"].string) }
        .help("Open the chat")
    }

    var controls: some View {
        HStack(spacing: 8) {
            Button("Deny") { reply("deny") }.buttonStyle(LButton(danger: true))
            Button("Allow") { reply("allow") }.buttonStyle(LButton(primary: true))
            if p["always"].bool { Button("Always allow") { reply("allow", always: true) }.buttonStyle(LButton()).help("Trust the rules the agent proposed for calls like this one") }
            Spacer()
            Button { model.open(p["runId"].string) } label: { Label("Open chat", systemImage: "arrow.up.right") }.buttonStyle(LButton())
        }
    }

    func reply(_ behavior: String, always: Bool = false) {
        busy.v = true
        Task { await model.answer(run: p["runId"].string, askId: p["askId"].string, behavior: behavior, always: always); busy.v = false }
    }
}

/// The watcher's state, and a way to poll now, above the Slack tab.
struct SlackWatchBar: View {
    @Environment(AppModel.self) var model
    @StateObject private var checking = Box(false)

    var body: some View {
        let w = model.slackWatch
        HStack(spacing: 8) {
            if let e = w["lastError"].nonEmpty {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(T.ui(11.5)).foregroundStyle(T.orange).lineLimit(1)
            } else if w["mode"].string == "off" {
                Text("Watching is off").font(T.ui(11.5)).foregroundStyle(T.text3)
            } else if w["lastPollAt"].double > 0 {
                Text(Fmt.checked(w["lastPollAt"].double)).font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            IconButton(icon: "arrow.clockwise", help: "Check Slack now", spinning: checking.v) {
                checking.v = true
                Task { await model.slackCheckNow(); checking.v = false }
            }
            IconButton(icon: "gearshape", help: "Slack watch settings") { model.settingsPane = "integrations"; model.navigate(.settings) }
        }
    }
}

struct SlackItemRow: View {
    @Environment(AppModel.self) var model
    let item: JSON

    var body: some View {
        let skip = item["verdict"].string == "skip"
        VStack(alignment: .leading, spacing: 10) {
            head
            MarkdownText(text: Session.plain(item["text"].string), size: 12.5, color: NT.text2)
                .lineLimit(6)
            if let r = item["reason"].nonEmpty {
                Label("Orchestrator: \(r)", systemImage: "sparkles").font(T.ui(11.5)).foregroundStyle(T.text3)
            }
            actions
        }
        .padding(18)
        .opacity(skip ? 0.6 : 1)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.line, lineWidth: 1))
        .padding(.horizontal, 20).padding(.top, 14)
    }

    var head: some View {
        HStack(spacing: 8) {
            Avatar(name: item["who"].string, url: item["avatar"].string, size: 20)
            Text(item["who"].string).font(T.ui(13, .semibold))
            Text(item["channel"].nonEmpty ?? "Slack").font(T.ui(12)).foregroundStyle(T.text3)
            Chip(text: item["kind"].string == "channel" ? "Channel post" : "Mention", icon: item["kind"].string == "channel" ? "number" : "at")
            if item["count"].int > 1 { Chip(text: "\(item["count"].int) messages") }
            if let v = item["verdict"].nonEmpty { Chip(text: v == "skip" ? "Triage: skip" : "Triage: actionable", icon: v == "skip" ? "minus.circle" : "checkmark.circle") }
            Spacer()
            Text(Fmt.ago(item["ts"].double)).font(T.ui(11.5)).foregroundStyle(T.text3)
        }
    }

    var actions: some View {
        HStack(spacing: 8) {
            Button("Dismiss") { Task { await model.slackItem(item["id"].string, "dismiss") } }.buttonStyle(LButton())
            Spacer()
            if let link = item["permalink"].nonEmpty {
                Button { model.openThread(link) } label: { Label("Read thread", systemImage: "text.bubble") }.buttonStyle(LButton())
                Button { openURL(link) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(LButton(square: true)).help("Open in Slack")
                Menu {
                    ForEach(model.projects) { p in
                        Button(p.name) { Task { await model.slackItem(item["id"].string, "start", ["project": p.id]) } }
                    }
                } label: { Label("Hand to Claude", systemImage: "sparkles") } primaryAction: {
                    Task { await model.slackItem(item["id"].string, "start", model.projectFilter.map { ["project": $0] } ?? [:]) }
                }
                .menuStyle(.button).buttonStyle(LButton(primary: true)).fixedSize()
                .help("Run the Slack pipeline on this thread (pick a project from the arrow)")
            }
        }
    }
}

/// Something only you can do. The circle ticks it off; the row opens its chat.
struct TodoRow: View {
    @Environment(AppModel.self) var model
    let t: JSON
    var body: some View {
        HoverRow(height: 50) {
            HStack(spacing: 12) {
                Button { Task { await model.todoDone(t["key"].string) } } label: {
                    Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(T.text3)
                }
                .buttonStyle(.plain).help("Mark done")
                VStack(alignment: .leading, spacing: 2) {
                    Text(inline(t["text"].string)).font(T.ui(13)).foregroundStyle(T.text).lineLimit(2)
                    if let title = t["title"].nonEmpty { Text("From \(title)").font(T.ui(11.5)).foregroundStyle(T.text3).lineLimit(1) }
                }
                Spacer()
                if let u = t["url"].nonEmpty { IconButton(icon: "arrow.up.right.square", help: u, size: B.small) { openURL(u) } }
            }
            .padding(.vertical, 8)
        }
        .onTapGesture { if let id = t["taskId"].nonEmpty { model.open(id) } }
        .help(t["taskId"].nonEmpty == nil ? "" : "Open the chat")
    }
}

struct ActivityRow: View {
    @Environment(AppModel.self) var model
    let e: JSON
    var body: some View {
        HoverRow(height: 34) {
            HStack(spacing: 10) {
                Text(Fmt.clock(e["at"].double)).font(T.ui(11.5)).foregroundStyle(T.text3).frame(width: 90, alignment: .leading)
                Chip(text: e["name"].string)
                Text(e["text"].string).font(T.ui(12.5)).foregroundStyle(T.text2).lineLimit(1)
                Spacer()
            }
        }
        .onTapGesture { if let id = e["taskId"].nonEmpty { model.open(id) } }
        .help(e["taskId"].nonEmpty == nil ? "" : "Open the chat")
    }
}
