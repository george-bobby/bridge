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
    @Environment(AppModel.self) var model

    var dirty: Bool { text.v != saved.v }

    var body: some View {
        SSection(title: "Pipeline", detail: "Markdown, styled as you type. Sent after the task in a new session's first message (Linear, Slack, New task, bridge spawn, relaunch), for every agent. {{URL}} is the task's Linear or Slack link, {{BRIEF}} the brief's path, {{USER}} your name, {{BRIDGE}} the bridge tool. Clear it to turn it off") {
            if Prefs.hit(q, "pipeline opening fetch new session first message linear slack plan build pr review") { editor }
        } trailing: {
            actions
        }
        .task { apply(try? await API.get("/api/pipeline")) }
    }

    var editor: some View {
        MarkdownEditor(text: $text.v, enabled: loaded.v)
            .frame(minHeight: 560)
            .padding(8)
            .opacity(loaded.v ? 1 : 0.5)
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
