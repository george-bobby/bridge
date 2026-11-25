// Bridge.app: a native window around the local dashboard.
//
// The dashboard server keeps running under launchd (npm start), so closing or
// quitting this app never kills a Claude worker. The app makes sure that server
// is up, loads it in a WKWebView, and adds what a browser tab can't: a Dock
// badge for sessions waiting on you, native notifications, a real menu bar and
// a hidden title bar.

import Cocoa
import UserNotifications
import WebKit

let info = Bundle.main.infoDictionary ?? [:]
let root = info["BridgeRoot"] as? String ?? ""
let port = info["BridgePort"] as? String ?? "4319"
let home = URL(string: "http://127.0.0.1:\(port)/")!
let topbarHeight: CGFloat = 56

// Swaps in for the web Notification API (WKWebView has none on macOS) and
// reports the top bar's clickable areas so the rest of it can drag the window.
let bridgeScript = """
(() => {
  const post = (m) => window.webkit.messageHandlers.bridge.postMessage(m);
  const open = new Map();
  let seq = 0;
  class BridgeNotification {
    static permission = "granted";
    static requestPermission() { return Promise.resolve("granted"); }
    constructor(title, opts = {}) {
      this.id = String(++seq);
      this.onclick = null;
      open.set(this.id, this);
      post({ type: "notify", id: this.id, title: String(title), body: String(opts.body || ""), tag: String(opts.tag || "") });
    }
    close() { open.delete(this.id); }
  }
  window.Notification = BridgeNotification;
  window.__bridgeNotificationClick = (id) => {
    const n = open.get(id);
    if (n && n.onclick) n.onclick({ target: n });
  };
  const sendRects = () => {
    const sel = ".topbar button, .topbar input, .topbar form, .topbar nav, .topbar a, .topbar select";
    const rects = [...document.querySelectorAll(sel)].map((e) => e.getBoundingClientRect())
      .filter((r) => r.width && r.height).map((r) => [r.left, r.top, r.width, r.height]);
    post({ type: "nodrag", rects });
  };
  addEventListener("load", () => {
    sendRects();
    new ResizeObserver(sendRects).observe(document.body);
    new MutationObserver(sendRects).observe(document.querySelector(".topbar") || document.body, { childList: true, subtree: true });
  });
})();
"""

final class DragWebView: WKWebView {
    var noDrag: [CGRect] = []

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // WKWebView is flipped, so y already counts down from the top.
        let y = isFlipped ? p.y : bounds.height - p.y
        let pt = CGPoint(x: p.x, y: y)
        if y < topbarHeight && !noDrag.contains(where: { $0.contains(pt) }) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
            return
        }
        super.mouseDown(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var web: DragWebView!
    var titleObserver: NSKeyValueObservation?
    var startedServer = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "BridgeApp/1.0"
        config.userContentController.addUserScript(WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "bridge")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        web = DragWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { web.isInspectable = true }
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Bridge"
        window.minSize = NSSize(width: 900, height: 560)
        window.backgroundColor = NSColor(red: 0.04, green: 0.047, blue: 0.063, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("BridgeMain")
        window.makeKeyAndOrderFront(nil)
        // Center the traffic lights on the 56px top bar.
        positionTrafficLights()
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.positionTrafficLights() }

        // "(3) Needs you · Bridge" is the page's own count of blocked sessions.
        titleObserver = web.observe(\.title, options: [.new]) { view, _ in
            let t = view.title ?? ""
            let n = t.range(of: #"^\((\d+)\)"#, options: .regularExpression).map { String(t[$0].dropFirst().dropLast()) }
            NSApp.dockTile.badgeLabel = n
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        showSplash("Starting Bridge…")
        ensureServer()
    }

    func positionTrafficLights() {
        guard let close = window.standardWindowButton(.closeButton), let bar = close.superview?.superview else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        bar.frame.size.height = topbarHeight
        bar.frame.origin.y = window.frame.height - topbarHeight
        for (i, t) in types.enumerated() {
            guard let b = window.standardWindowButton(t) else { continue }
            b.setFrameOrigin(NSPoint(x: 18 + CGFloat(i) * 20, y: (topbarHeight - b.frame.height) / 2))
        }
    }

    // MARK: server

    func ping(_ done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: home.appendingPathComponent("api/state"))
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { _, res, _ in
            DispatchQueue.main.async { done((res as? HTTPURLResponse)?.statusCode == 200) }
        }.resume()
    }

    func ensureServer(attempt: Int = 0) {
        ping { [self] up in
            if up { web.load(URLRequest(url: home)); return }
            if !startedServer { startedServer = true; startServer() }
            if attempt > 60 {
                return showSplash("The dashboard didn't start. Run <code>npm start</code> in \(root) and check logs/dashboard.err.log.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.ensureServer(attempt: attempt + 1) }
        }
    }

    // Same path as `npm start`: launchd owns the server, so it outlives this app.
    func startServer() {
        guard !root.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "cd \"$BRIDGE_ROOT\" && ./scripts/install.sh start"]
        p.environment = ProcessInfo.processInfo.environment.merging(["BRIDGE_ROOT": root]) { $1 }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func showSplash(_ text: String) {
        web.loadHTMLString("""
        <html><body style="margin:0;height:100vh;display:grid;place-items:center;background:#0a0c10;color:#aab3c2;
        font:14px -apple-system,sans-serif"><div style="text-align:center;max-width:460px;line-height:1.6">
        <div style="width:44px;height:44px;border-radius:12px;background:#7c74ff;margin:0 auto 16px"></div>\(text)</div></body></html>
        """, baseURL: nil)
    }

    // MARK: web view

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        let local = url.host == "127.0.0.1" || url.host == "localhost"
        if local || url.scheme == "about" || url.scheme == "data" { return decisionHandler(.allow) }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    // target="_blank" links go to the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { retryLater() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { retryLater() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func retryLater() {
        showSplash("Reconnecting to the dashboard…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.ensureServer() }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        if type == "nodrag", let rects = m["rects"] as? [[Double]] {
            web.noDrag = rects.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        }
        if type == "notify" {
            let content = UNMutableNotificationContent()
            content.title = m["title"] as? String ?? "Bridge"
            content.body = m["body"] as? String ?? ""
            content.sound = .default
            content.userInfo = ["id": m["id"] as? String ?? ""]
            let tag = (m["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: tag, content: content, trigger: nil))
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    // MARK: notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String ?? ""
        showWindow()
        web.evaluateJavaScript("window.__bridgeNotificationClick && window.__bridgeNotificationClick(\(jsString(id)))")
        done()
    }

    func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        return String(data: data ?? Data("[\"\"]".utf8), encoding: .utf8).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    // MARK: app

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func js(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { web.evaluateJavaScript(code) }
    }

    @objc func reload(_ sender: Any?) { web.reload() }
    @objc func openInBrowser(_ sender: Any?) { NSWorkspace.shared.open(web.url ?? home) }
    @objc func zoomIn(_ sender: Any?) { web.pageZoom = min(web.pageZoom + 0.1, 2) }
    @objc func zoomOut(_ sender: Any?) { web.pageZoom = max(web.pageZoom - 0.1, 0.6) }
    @objc func zoomReset(_ sender: Any?) { web.pageZoom = 1 }
    @objc func newWindowIfClosed(_ sender: Any?) { showWindow() }

    func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if let t = target { i.target = t }
            return i
        }
        func jsItem(_ title: String, _ code: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = item(title, #selector(js(_:)), key, mods, target: self)
            i.representedObject = code
            return i
        }

        menu("Bridge", [
            item("About Bridge", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            jsItem("Settings…", "togglePanel('settings')", ","),
            .separator(),
            item("Hide Bridge", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Bridge", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            jsItem("New Task…", "setView('board'); setTimeout(() => document.querySelector('.knew textarea')?.focus(), 50)", "n"),
            jsItem("Paste Slack Thread…", "document.getElementById('linkInput').focus()", "l"),
            .separator(),
            item("Open in Browser", #selector(openInBrowser(_:)), "o", [.command, .shift], target: self),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            jsItem("Search…", "openPalette(true)", "k"),
        ])
        menu("View", [
            jsItem("Overview", "setView('home')", "1"),
            jsItem("Board", "setView('board')", "2"),
            jsItem("Chats", "setView('chats')", "3"),
            jsItem("Pull Requests", "setView('prs')", "4"),
            jsItem("Linear", "setView('linear')", "5"),
            .separator(),
            jsItem("Inbox", "toggleInbox()", "i", [.command, .shift]),
            jsItem("Orchestrator", "openRun('orchestrator')", "o"),
            jsItem("Project Memory", "openMemory(!mem.open)", "m", [.command, .shift]),
            .separator(),
            item("Reload", #selector(reload(_:)), "r", target: self),
            item("Actual Size", #selector(zoomReset(_:)), "0", target: self),
            item("Zoom In", #selector(zoomIn(_:)), "=", target: self),
            item("Zoom Out", #selector(zoomOut(_:)), "-", target: self),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let windowMenu: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bridge", #selector(newWindowIfClosed(_:)), "0", [.command, .option], target: self),
        ]
        menu("Window", windowMenu)
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
