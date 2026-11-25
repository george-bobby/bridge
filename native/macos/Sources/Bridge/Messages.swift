import AppKit
import SwiftUI

// MARK: - Message navigation
//
// A long chat steps prompt to prompt instead of scrolling: the floating
// stepper at the transcript's top right (and ⌥↑ / ⌥↓ in the focused pane;
// ⌥⇧ for every message) scrolls the target to the top and flashes it. Each
// transcript has its own `MessageNav`, so panes navigate independently. The
// current message comes from the scroll position, so "3 / 20" follows the
// reader rather than the last click.

@MainActor final class MessageNav: ObservableObject {
    /// The topmost visible message, from the scroll view.
    @Published var top: Int?
    @Published var atBottom = true
    /// Indices of the prompts (your messages and the Slack thread's).
    @Published private(set) var prompts: [Int] = []
    private(set) var count = 0
    /// The flashed message lives apart, so a flash doesn't redraw the stepper
    /// and a scroll doesn't redraw every row's highlight.
    let flash = Box<Int?>(nil)
    var proxy: ScrollViewProxy?
    private var flashGen = 0
    /// The last message stepped to, until the reader scrolls by hand: a
    /// target near the end can't reach the top, so the scroll position alone
    /// would leave the stepper stuck there.
    @Published var pinned: Int?

    static func isPrompt(_ m: JSON) -> Bool {
        !["assistant", "event", "outcome", "relay", "harness"].contains(m["role"].string)
    }

    func update(_ messages: [JSON]) {
        count = messages.count
        let p = messages.indices.filter { Self.isPrompt(messages[$0]) }
        if p != prompts { prompts = p }
    }

    /// Where the reader is: the topmost visible message, or the end.
    var cursor: Int { pinned ?? top ?? count - 1 }

    /// The prompt the reader is in (0-based into `prompts`).
    var current: Int? {
        if pinned == nil, atBottom, let last = prompts.indices.last { return last }
        return prompts.lastIndex { $0 <= cursor }
    }

    func targets(all: Bool) -> [Int] { all ? Array(0..<count) : prompts }

    /// Up: the start of the message the reader is in, else the one before.
    /// Down: the next one, and past the last prompt, the end of the chat.
    func target(_ delta: Int, all: Bool = false) -> Int?? {
        let t = targets(all: all)
        if delta < 0 { return t.last { $0 < cursor }.map { .some($0) } }
        if let n = t.first(where: { $0 > cursor }) { return .some(n) }
        return atBottom && pinned == nil ? nil : .some(nil)
    }

    func scrolledByHand() { if pinned != nil { pinned = nil } }

    func canStep(_ delta: Int) -> Bool { target(delta) != nil }

    func step(_ delta: Int, all: Bool = false) {
        guard let proxy, let t = target(delta, all: all) else { NSSound.beep(); return }
        withAnimation(M.page) {
            // A little air above the target, so its highlight isn't clipped.
            if let i = t { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.035)) } else { proxy.scrollTo("end", anchor: .bottom) }
        }
        pinned = t
        guard let i = t else { return }
        flashGen += 1
        let gen = flashGen
        withAnimation(M.hover) { flash.v = i }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, self.flashGen == gen else { return }
            withAnimation(.easeOut(duration: 0.6)) { self.flash.v = nil }
        }
    }

    func excerpt(_ messages: [JSON], _ i: Int) -> String {
        guard messages.indices.contains(i) else { return "" }
        let text = Session.plain(messages[i]["text"].string).replacingOccurrences(of: "\n", with: " ")
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }
}

/// Owns a transcript's nav without publishing anything itself, so the
/// transcript never re-renders on scroll; only the stepper and the
/// highlights observe the nav.
final class NavHolder: ObservableObject {
    @MainActor let nav = MessageNav()
    @MainActor init() {}
}

struct MessageStepper: View {
    @ObservedObject var nav: MessageNav
    let messages: [JSON]
    @StateObject private var hover = Box(false)

    var body: some View {
        if nav.prompts.count >= 2 {
            let cur = nav.current
            let prev = nav.target(-1).flatMap { $0 }
            let next = nav.target(1)
            VStack(spacing: 0) {
                StepButton(icon: "chevron.up", help: "Previous prompt (⌥↑, ⌥⇧↑ for any message)" + (prev.map { ": " + nav.excerpt(messages, $0) } ?? ""), enabled: prev != nil) { nav.step(-1) }
                Text(verbatim: cur.map { "\($0 + 1)" } ?? "–")
                    .font(T.ui(11, .semibold)).foregroundStyle(T.text)
                    .monospacedDigit().contentTransition(.numericText())
                    .padding(.top, 1)
                Text(verbatim: "\(nav.prompts.count)")
                    .font(T.ui(9.5)).foregroundStyle(T.text3).monospacedDigit()
                    .overlay(alignment: .top) { Rectangle().fill(T.line).frame(width: 12, height: 1).offset(y: -1) }
                    .padding(.top, 2).padding(.bottom, 1)
                StepButton(icon: "chevron.down", help: next == .some(nil) ? "Jump to the latest" : "Next prompt (⌥↓, ⌥⇧↓ for any message)" + (next.flatMap { $0 }.map { ": " + nav.excerpt(messages, $0) } ?? ""), enabled: next != nil) { nav.step(1) }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.raised.opacity(0.92)))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .opacity(hover.v ? 1 : 0.82)
            .hoverBox(hover)
            .animation(M.snappy, value: cur)
            .help("Prompt \((cur ?? 0) + 1) of \(nav.prompts.count)")
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
        }
    }
}

/// The brief highlight on a message the stepper landed on.
struct FlashMark: View {
    @ObservedObject var flash: Box<Int?>
    let index: Int

    var body: some View {
        let on = flash.v == index
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(T.accent.opacity(on ? 0.1 : 0))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T.accent.opacity(on ? 0.45 : 0), lineWidth: 1))
            .padding(.horizontal, -14).padding(.vertical, -10)
            .allowsHitTesting(false)
    }
}

extension AppModel {
    /// ⌥↑ / ⌥↓ (⌥⇧ for any message) in the focused pane's chat. Typing
    /// wins: with text in the composer the keys stay the editor's.
    func messageKey(_ e: NSEvent) -> Bool {
        guard isChatRoute, !paletteOpen, !composeOpen, e.keyCode == 126 || e.keyCode == 125 else { return false }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard flags == .option || flags == [.option, .shift] else { return false }
        if let tv = e.window?.firstResponder as? NSTextView, tv.isEditable, !tv.string.isEmpty { return false }
        guard panes.indices.contains(focusedPane), panes[focusedPane].tab == "chat",
              let nav = messageNavs[panes[focusedPane].run] else { return false }
        nav.step(e.keyCode == 126 ? -1 : 1, all: flags.contains(.shift))
        return true
    }
}
