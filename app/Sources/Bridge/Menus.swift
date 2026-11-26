import AppKit
import SwiftUI

// Window chrome and the header controls every page shares: traffic-light
// placement, Linear-style pill buttons, icon segmented controls, and the
// Display / Filter popover pieces.

// MARK: - Window chrome

enum Chrome {
    /// The vertical center every top-left control shares: the traffic lights,
    /// the sidebar/back/forward buttons and each page header's title.
    static let center: CGFloat = T.panelInset + T.headerHeight / 2
    static let lightsLeft: CGFloat = 18
    static let buttonsLeft: CGFloat = 84
}

/// Moves the standard window buttons onto `Chrome.center`. AppKit lays the
/// title bar out again on resize, key changes and full screen, so this
/// re-applies itself then (the way Electron's trafficLightPosition does).
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeProbe() }
    func updateNSView(_ v: NSView, context: Context) { (v as? ChromeProbe)?.place() }
}

final class ChromeProbe: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let w = window else { return }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didChangeBackingPropertiesNotification,
        ]
        for n in names {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        place()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    override func layout() {
        super.layout()
        place()
    }

    func place() { if let w = window { TrafficLights.place(in: w) } }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor enum TrafficLights {
    static func place(in w: NSWindow) {
        guard !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let mini = w.standardWindowButton(.miniaturizeButton),
              let zoom = w.standardWindowButton(.zoomButton),
              let bar = close.superview, let container = bar.superview else { return }
        let h = (Chrome.center * 2).rounded()
        var f = container.frame
        if abs(f.height - h) > 0.5 || abs(f.minY - (w.frame.height - h)) > 0.5 {
            f.size.height = h
            f.origin.y = w.frame.height - h
            container.frame = f
        }
        let spacing = zoom.frame.minX - mini.frame.minX > 10 ? zoom.frame.minX - mini.frame.minX : 20
        for (i, b) in [close, mini, zoom].enumerated() {
            let o = NSPoint(x: Chrome.lightsLeft + CGFloat(i) * spacing, y: ((bar.frame.height - b.frame.height) / 2).rounded())
            if b.frame.origin != o { b.setFrameOrigin(o) }
        }
    }
}

// MARK: - Header controls

/// The bordered pill behind Display, Filter and the project scope.
struct HeaderPill: View {
    let icon: String
    var text: String = ""
    var count = 0
    var active = false
    var chevron = false
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(active ? T.accent : hover.v ? T.text : T.text2)
            if !text.isEmpty { Text(text).font(T.ui(12, .medium)).lineLimit(1) }
            if count > 0 {
                Text(verbatim: "\(count)").font(T.ui(10.5, .semibold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 15)
                    .background(Capsule().fill(T.accent))
                    .contentTransition(.numericText())
            }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3) }
        }
        .foregroundStyle(active || hover.v ? T.text : T.text2)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? T.accentSoft : hover.v ? T.hover : T.raised.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(active ? T.accent.opacity(0.45) : T.line, lineWidth: 1))
        .contentShape(Rectangle())
        .hoverBox(hover)
        .animation(M.hover, value: active)
    }
}

/// A header pill that opens a popover panel.
struct PopoverButton<Content: View>: View {
    let icon: String
    var text: String = ""
    var count = 0
    var active = false
    var help = ""
    var width: CGFloat = 300
    @ViewBuilder let content: () -> Content
    @StateObject private var open = Box(false)

    var body: some View {
        Button { open.v.toggle() } label: { HeaderPill(icon: icon, text: text, count: count, active: active || open.v) }
            .buttonStyle(Pressable(scale: 0.96))
            .help(help)
            .popover(isPresented: $open.v, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.vertical, 8)
                    .frame(width: width)
            }
    }
}

/// Compact icon-only segmented control with a sliding selection.
struct IconTabs: View {
    struct Item: Identifiable {
        let id: String
        let icon: String
        let help: String
    }

    let items: [Item]
    @Binding var selection: String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { i in
                let on = selection == i.id
                Button { withAnimation(M.snappy) { selection = i.id } } label: {
                    Image(systemName: i.icon).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? T.text : T.text3)
                        .frame(width: 30, height: 22)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6).fill(T.selected)
                                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(i.help)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(T.raised.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
        .fixedSize()
    }
}

/// Board or list, for Sessions.
struct LayoutPicker: View {
    @Environment(AppModel.self) var model
    var body: some View {
        IconTabs(items: [
            .init(id: "list", icon: "list.bullet", help: "List"),
            .init(id: "board", icon: "rectangle.split.3x1", help: "Board"),
        ], selection: Binding(get: { model.route == .sessions ? "list" : "board" }, set: { model.route = $0 == "list" ? .sessions : .board }))
    }
}

// MARK: - Popover pieces

struct PopLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(T.ui(11, .semibold)).foregroundStyle(T.text3)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
    }
}

struct PopDivider: View {
    var body: some View { Rectangle().fill(T.line).frame(height: 1).padding(.vertical, 6) }
}

/// A row in a popover: icon, label, and a control on the right.
struct PopRow<Trailing: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(T.text2).frame(width: 16)
            Text(label).font(T.ui(12.5)).foregroundStyle(T.text)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}

/// A popover row that toggles: checkmark on the right when on.
struct PopCheckRow<Icon: View>: View {
    let label: String
    let on: Bool
    @ViewBuilder var icon: () -> Icon
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon().frame(width: 16)
                Text(label).font(T.ui(12.5)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(T.accent)
                    .opacity(on ? 1 : 0).scaleEffect(on ? 1 : 0.6)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover.v ? T.hover : .clear))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBox(hover)
        .animation(M.pop, value: on)
    }
}

/// Small Linear-style switch.
struct LSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(M.snappy) { configuration.isOn.toggle() } } label: {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? T.accent : T.line)
                    Circle().fill(.white).frame(width: 12, height: 12).padding(2)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                }
                .frame(width: 28, height: 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A value picker as a pill that opens a native menu with icons.
struct ValueMenu: View {
    struct Option: Identifiable {
        let id: String
        let label: String
        let icon: String
    }

    let options: [Option]
    @Binding var selection: String

    var body: some View {
        let current = options.first { $0.id == selection } ?? options[0]
        Menu {
            ForEach(options) { o in
                Button { withAnimation(M.snappy) { selection = o.id } } label: {
                    Label(o.label, systemImage: o.id == selection ? "checkmark" : o.icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.icon).font(.system(size: 10.5, weight: .medium)).foregroundStyle(T.text2)
                Text(current.label).font(T.ui(12, .medium)).foregroundStyle(T.text)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// Toggle chips (Linear's "Display properties").
struct PropChips: View {
    let options: [(id: String, label: String)]
    @Binding var selected: Set<String>

    var body: some View {
        FlowRows(spacing: 6) {
            ForEach(options, id: \.id) { o in
                let on = selected.contains(o.id)
                Button {
                    withAnimation(M.snappy) { if on { selected.remove(o.id) } else { selected.insert(o.id) } }
                } label: {
                    Text(o.label).font(T.ui(11.5, .medium))
                        .foregroundStyle(on ? T.text : T.text3)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? T.selected : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? T.text3.opacity(0.6) : T.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 4)
    }
}

/// Lays children out left to right, wrapping onto new rows.
struct FlowRows: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing
            row = max(row, sz.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            row = max(row, sz.height)
        }
    }
}

/// An active filter under a page header, removable.
struct FilterChip: View {
    let label: String
    let value: String
    let clear: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(T.ui(11.5)).foregroundStyle(T.text3).padding(.leading, 8).padding(.trailing, 5)
            Text(value).font(T.ui(11.5, .medium)).foregroundStyle(T.text).lineLimit(1).padding(.trailing, 6)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(hover.v ? T.text : T.text3)
                    .frame(width: 20, height: 22)
                    .background(hover.v ? T.hover : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverBox(hover)
            .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
        }
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

// MARK: - Menu helpers

extension Column {
    var symbol: String {
        switch self {
        case .backlog: return "circle.dashed"
        case .doing: return "circle.lefthalf.filled"
        case .needs: return "exclamationmark.circle"
        case .review: return "eye.circle"
        case .done: return "checkmark.circle"
        }
    }
}

/// "Start session with ▸ Claude / Codex / Cursor / Devin" for a Linear issue.
struct StartWithMenu: View {
    @Environment(AppModel.self) var model
    let issue: Issue
    var body: some View {
        Button { Task { await model.startIssue(issue) } } label: { Label("Start Session", systemImage: "sparkles") }
        Menu {
            ForEach(AgentKind.allCases.filter { model.installed($0) }) { a in
                Button { Task { await model.startIssue(issue, agent: a) } } label: { Label(a.label, systemImage: a.symbol) }
            }
        } label: { Label("Start Session With", systemImage: "person.crop.circle.badge.plus") }
    }
}
