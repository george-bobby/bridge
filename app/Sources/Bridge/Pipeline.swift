import SwiftUI

/// Settings › Pipeline: what every new session opens with, after its task
/// (server/pipeline.js). prompts/pipeline.md until edited here, then
/// data/pipeline.md; blank turns it off.
struct PipelineSettings: View {
    let q: String
    @StateObject private var text = Box("")
    @StateObject private var saved = Box("")
    @StateObject private var custom = Box(false)
    @StateObject private var loaded = Box(false)
    @StateObject private var tab = Box("edit")
    @Environment(AppModel.self) var model

    var dirty: Bool { text.v != saved.v }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if q.isEmpty {
                SlidingTabs(tabs: [
                    .init(id: "edit", label: "Edit", icon: "pencil"),
                    .init(id: "preview", label: "Preview", icon: "eye"),
                ], selection: $tab.v)
            }
            SSection(title: "Pipeline", detail: "Markdown, sent after the task in a new session's first message (Linear, Slack, New task, bridge spawn, relaunch), for every agent. {{URL}} is the task's Linear or Slack link, {{BRIEF}} the brief's path, {{USER}} your name, {{BRIDGE}} the bridge tool. Clear it to turn it off") {
                if Prefs.hit(q, "pipeline opening fetch new session first message linear slack plan build pr review") {
                    if tab.v == "preview" && q.isEmpty { preview } else { editor }
                }
            } trailing: {
                actions
            }
        }
        .task { apply(try? await API.get("/api/pipeline")) }
    }

    var editor: some View {
        TextEditor(text: $text.v)
            .font(T.mono(12))
            .scrollContentBackground(.hidden)
            .padding(12)
            .frame(minHeight: 560)
            .disabled(!loaded.v)
            .opacity(loaded.v ? 1 : 0.5)
    }

    var preview: some View {
        Group {
            if text.v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Off: new sessions just read their brief.").font(T.ui(12.5)).foregroundStyle(T.text3)
            } else {
                MarkdownText(text: text.v)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .topLeading)
        .padding(16)
    }

    var actions: some View {
        HStack(spacing: 8) {
            if dirty { Button("Revert") { text.v = saved.v }.buttonStyle(LButton(small: true)) }
            else if custom.v { Button("Reset to Default") { post(["reset": true], done: "Pipeline reset") }.buttonStyle(LButton(small: true)) }
            Button("Save") { post(["text": text.v], done: "Pipeline saved") }
                .buttonStyle(LButton(primary: true, small: true)).keyboardShortcut("s").disabled(!dirty)
        }
    }

    func apply(_ j: JSON?) {
        guard let j else { return }
        text.v = j["text"].string
        saved.v = text.v
        custom.v = j["custom"].bool
        loaded.v = true
    }

    func post(_ body: [String: Any], done: String) {
        Task {
            await model.act {
                self.apply(try await API.post("/api/pipeline", body))
                self.model.say(done)
            }
        }
    }
}
