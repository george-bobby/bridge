import AppKit
import SwiftTerm
import SwiftUI

// MARK: - VS Code key bindings
//
// The bindings a VS Code hand reaches for, on one key monitor (menus can't
// express ⌃Tab or ⌃⇧`, and a focused terminal would eat ⌃ keys first):
//
//   ⌃`  toggle the terminal panel   ⌃⇧`  new terminal     ⌘J  toggle panel
//   ⌘K  clear (in the panel)        ⌘W   close tab / pane / panel terminal
//   ⌃Tab ⌃⇧Tab, ⇧⌘] ⇧⌘[  next / previous tab (in the panel: terminal)
//   ⌃-  ⌃⇧-  back / forward         ⌘P ⇧⌘P ⇧⌘F  command menu
//   ⌘B  toggle sidebar (⌃⌘S too)    ⇧⌘G  Changes        ⇧⌘E  Sessions

@MainActor enum Keys {
    private static var monitor: Any?

    static func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            MainActor.assumeIsolated { handle(e, model) } ? nil : e
        }
    }

    static let grave: UInt16 = 50, tab: UInt16 = 48, minus: UInt16 = 27, openBracket: UInt16 = 33, closeBracket: UInt16 = 30

    static func handle(_ e: NSEvent, _ model: AppModel) -> Bool {
        guard e.window?.isKeyWindow ?? true, !model.importOpen, model.mcpSheet == nil, model.archiveAsk == nil else { return false }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let console = ConsoleStore.shared
        let inPanel = console.focused
        let inTerminal = e.window?.firstResponder is TerminalView

        // The palette keeps its own keys, but the terminal toggles still work over it.
        if model.paletteOpen && e.keyCode != grave { return false }

        switch (e.keyCode, f) {
        case (grave, [.control]):
            model.paletteOpen = false
            console.toggle(model)
            return true
        case (grave, [.control, .shift]):
            model.paletteOpen = false
            console.add(model.contextFolder)
            return true
        case (tab, [.control]), (closeBracket, [.command, .shift]):
            if inPanel { console.step(1); return true }
            return model.stepTab(1)
        case (tab, [.control, .shift]), (openBracket, [.command, .shift]):
            if inPanel { console.step(-1); return true }
            return model.stepTab(-1)
        case (minus, [.control]) where !inTerminal:
            model.back(); return true
        case (minus, [.control, .shift]) where !inTerminal:
            model.forward(); return true
        default: break
        }

        switch (key, f) {
        case ("j", [.command]):
            console.togglePanel(model); return true
        case ("k", [.command]) where inPanel:
            console.active?.clear(); return true
        case ("w", [.command]):
            if inPanel { console.kill(); return true }
            return model.closeFocusedTab()
        case ("p", [.command]), ("p", [.command, .shift]), ("f", [.command, .shift]):
            model.paletteOpen = true; return true
        case ("b", [.command]) where !inTerminal, ("s", [.command, .control]):
            model.toggleSidebar(); return true
        case ("g", [.command, .shift]):
            guard case .session(let id) = model.route else { return false }
            withAnimation(M.snappy) { model.showTab("changes", of: id) }
            return true
        case ("e", [.command, .shift]):
            model.navigate(.sessions); return true
        default:
            return false
        }
    }
}

extension AppModel {
    /// The focused pane's tabs in strip order.
    func tabKeys(of run: String) -> [String] {
        var keys = ["chat", "changes"]
        if terminalTabs.contains(run) { keys.append("term") }
        keys += (browserTabs[run] ?? []).map { "web-\($0.id)" }
        keys += (taskTabs[run] ?? []).map { "task-\($0)" }
        return keys
    }

    /// ⌃Tab / ⌃⇧Tab: the next or previous tab of the focused pane, wrapping.
    @discardableResult func stepTab(_ delta: Int) -> Bool {
        guard isChatRoute, panes.indices.contains(focusedPane) else { return false }
        let p = panes[focusedPane]
        let keys = tabKeys(of: p.run)
        guard keys.count > 1, let i = keys.firstIndex(of: p.tab) else { return false }
        let next = keys[(i + delta + keys.count) % keys.count]
        withAnimation(M.snappy) { showTab(next, of: p.run, in: isSplit ? p.id : nil) }
        return true
    }

    /// ⌘W: close the focused pane's browser, terminal or task tab; on the
    /// chat or Changes side by side, the pane. Anything else is the window's.
    func closeFocusedTab() -> Bool {
        guard isChatRoute, panes.indices.contains(focusedPane) else { return false }
        let p = panes[focusedPane]
        if p.tab == "term" { closeTerminalTab(p.run); return true }
        if p.tab.hasPrefix("web-") { closeBrowser(p.run, String(p.tab.dropFirst(4))); return true }
        if p.tab.hasPrefix("task-") { closeTaskTab(p.run, String(p.tab.dropFirst(5))); return true }
        if isSplit { closePane(p.id); return true }
        return false
    }
}

/// The Terminal menu, VS Code's names and keys.
struct ConsoleCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Terminal") {
            Button { ConsoleStore.shared.toggle(model) } label: { Label("Toggle Terminal", systemImage: "terminal") }
                .keyboardShortcut("`", modifiers: .control)
            Button { ConsoleStore.shared.add(model.contextFolder) } label: { Label("New Terminal", systemImage: "plus.rectangle") }
                .keyboardShortcut("`", modifiers: [.control, .shift])
            Button { ConsoleStore.shared.kill() } label: { Label("Kill Terminal", systemImage: "trash") }
            Button { ConsoleStore.shared.active?.clear() } label: { Label("Clear Terminal (⌘K)", systemImage: "eraser") }
            Divider()
            Button { ConsoleStore.shared.togglePanel(model) } label: { Label("Toggle Panel", systemImage: "rectangle.bottomthird.inset.filled") }
                .keyboardShortcut("j")
            Button { ConsoleStore.shared.toggleMaximized() } label: { Label("Maximize Panel Size", systemImage: "arrow.up.left.and.arrow.down.right") }
            Divider()
            Button { if case .session(let id) = model.route { model.openTerminalTab(id) } } label: { Label("Resume Session in Terminal Tab", systemImage: "terminal.fill") }
                .disabled(!model.isChatRoute)
        }
    }
}
