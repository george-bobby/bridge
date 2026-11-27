import AppKit
import SwiftUI

// MARK: - Palette
//
// Linear's palette: layered surfaces, hairline borders, three steps of gray
// text, one indigo accent. Every color resolves per appearance: near-black
// surfaces in dark; in light a cool off-white window, white content and
// deeper status hues so they read as text on white.

private func ndyn(_ dark: UInt32, _ light: UInt32, alpha da: CGFloat = 1, light la: CGFloat = 1) -> NSColor {
    NSColor(name: nil) { a in
        let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hex = isDark ? dark : light
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? da : la)
    }
}

/// The palette as NSColors, for AppKit views (RichText); `T` wraps these.
enum NT {
    static let bg = ndyn(0x0B0B0D, 0xF2F2F5)
    static let panel = ndyn(0x111113, 0xFFFFFF)
    static let raised = ndyn(0x18181B, 0xF6F6F8)
    static let hover = ndyn(0x1C1C20, 0xF0F0F4)
    static let selected = ndyn(0x222228, 0xE7E7EE)
    static let line = ndyn(0x232327, 0xE3E3E9)
    static let lineSoft = ndyn(0x1A1A1E, 0xEDEDF1)
    static let text = ndyn(0xEDEDEF, 0x18181D)
    static let text2 = ndyn(0x9A9AA3, 0x55555F)
    static let text3 = ndyn(0x5F5F68, 0x8A8A95)
    static let codeBg = ndyn(0x0E0E10, 0xF6F6F9)
    static let accent = ndyn(0x5E6AD2, 0x5560D0)
    static let link = ndyn(0x8594FA, 0x4C57C9)
    static let green = ndyn(0x4CB878, 0x1F9254)
    static let yellow = ndyn(0xF2C94C, 0xB98300)
    static let orange = ndyn(0xF28C45, 0xD9661A)
    static let red = ndyn(0xEB5757, 0xD63A3A)
    static let purple = ndyn(0x8C6BF2, 0x7048E0)
    static let slack = ndyn(0xCC73D9, 0xA846B8)
    /// Shadows and scrims: black in dark, a softer cool ink in light.
    static let shade = ndyn(0x000000, 0x1A1C3A, light: 0.55)
    /// The hairline around floating panels: a light rim in dark, a dark one in light.
    static let rim = ndyn(0xFFFFFF, 0x000000, alpha: 0.09, light: 0.10)
}

/// Light, dark or follow the system. Applied app-wide through
/// `NSApp.appearance`, so SwiftUI, the dynamic NSColors above, AppKit text
/// views and terminals all switch together. `BRIDGE_APPEARANCE=light|dark`
/// overrides it for a run (snapshots) without saving.
enum Appearance {
    static let key = "appearance"
    static var current: String {
        if let v = ProcessInfo.processInfo.environment["BRIDGE_APPEARANCE"], ["system", "light", "dark"].contains(v) { return v }
        return UserDefaults.standard.string(forKey: key) ?? "system"
    }
    @MainActor static func save(_ v: String) {
        UserDefaults.standard.set(v, forKey: key)
        apply(v)
    }
    @MainActor static func apply(_ v: String) {
        NSApp.appearance = v == "light" ? NSAppearance(named: .aqua) : v == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}

func hexColor(_ s: String, fallback: Color = T.text3) -> Color {
    let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return fallback }
    return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

enum T {
    static let bg = Color(nsColor: NT.bg)          // window / sidebar
    static let panel = Color(nsColor: NT.panel)       // content surface
    static let raised = Color(nsColor: NT.raised)      // cards, inputs
    static let hover = Color(nsColor: NT.hover)
    static let selected = Color(nsColor: NT.selected)
    static let line = Color(nsColor: NT.line)
    static let lineSoft = Color(nsColor: NT.lineSoft)
    static let text = Color(nsColor: NT.text)
    static let text2 = Color(nsColor: NT.text2)
    static let text3 = Color(nsColor: NT.text3)
    static let accent = Color(nsColor: NT.accent)   // #5E6AD2
    static let accentSoft = Color(nsColor: NT.accent).opacity(0.16)

    static let green = Color(nsColor: NT.green)
    static let yellow = Color(nsColor: NT.yellow)
    static let orange = Color(nsColor: NT.orange)
    static let red = Color(nsColor: NT.red)
    static let purple = Color(nsColor: NT.purple)
    static let slack = Color(nsColor: NT.slack)
    static let shade = Color(nsColor: NT.shade)
    static let rim = Color(nsColor: NT.rim)
    static let codeBg = Color(nsColor: NT.codeBg)

    static let lightsInset: CGFloat = 158
    static let panelInset: CGFloat = 8
    static let headerHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 264
    static let sideHover = Color.primary.opacity(0.055)
    static let sideSelected = Color.primary.opacity(0.10)

    static func ui(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

// MARK: - Status icon (Linear's workflow circles)

enum StatusKind: String, CaseIterable {
    case triage, backlog, todo, progress, review, done, canceled, attention

    static func linear(type: String, name: String) -> StatusKind {
        switch type {
        case "triage": return .triage
        case "backlog": return .backlog
        case "unstarted": return .todo
        case "started": return name.lowercased().contains("review") ? .review : .progress
        case "completed": return .done
        case "canceled", "duplicate": return .canceled
        default: return .todo
        }
    }

    var color: Color {
        switch self {
        case .triage: return T.orange
        case .backlog, .todo, .canceled: return T.text3
        case .progress: return T.yellow
        case .review: return T.green
        case .done: return T.accent
        case .attention: return T.orange
        }
    }
}

struct StatusIcon: View {
    let kind: StatusKind
    var color: Color? = nil
    var size: CGFloat = 14

    var body: some View {
        let c = color ?? kind.color
        ZStack {
            switch kind {
            case .backlog:
                Circle().stroke(c, style: StrokeStyle(lineWidth: 1.5, dash: [1.6, 1.9]))
            case .todo:
                Circle().stroke(c, lineWidth: 1.5)
            case .progress, .review:
                Circle().stroke(c, lineWidth: 1.5)
                Pie(fraction: kind == .review ? 0.75 : 0.5).fill(c).padding(size * 0.2)
            case .done:
                Circle().fill(c)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(T.panel)
            case .canceled:
                Circle().fill(c)
                Image(systemName: "xmark").font(.system(size: size * 0.45, weight: .heavy)).foregroundStyle(T.panel)
            case .triage:
                Circle().stroke(c, lineWidth: 1.5)
                Circle().fill(c).padding(size * 0.3)
            case .attention:
                Circle().fill(c)
                Text("!").font(.system(size: size * 0.7, weight: .heavy)).foregroundStyle(T.panel)
            }
        }
        .frame(width: size, height: size)
    }
}

struct Pie: Shape {
    let fraction: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: c)
        p.addArc(center: c, radius: r.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Progress ring for an issue's sub-issues.
struct Ring: View {
    let done: Int
    let total: Int
    var size: CGFloat = 13
    var body: some View {
        ZStack {
            Circle().stroke(T.line, lineWidth: 2)
            Circle()
                .trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                .stroke(done == total ? T.accent : T.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Priority icon

struct PriorityIcon: View {
    let priority: Int // 0 none, 1 urgent, 2 high, 3 medium, 4 low
    var body: some View {
        Group {
            if priority == 1 {
                RoundedRectangle(cornerRadius: 3).fill(T.orange)
                    .overlay(Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white))
            } else if priority == 0 {
                HStack(spacing: 1.5) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(T.text3).frame(width: 2.5, height: 1.6) } }
            } else {
                let lit = priority == 2 ? 3 : priority == 3 ? 2 : 1
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(i < lit ? T.text2 : T.text3.opacity(0.45))
                            .frame(width: 3, height: CGFloat(5 + i * 3))
                    }
                }
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Small pieces

struct Chip: View {
    let text: String
    var icon: String? = nil
    var dot: Color? = nil
    var tint: Color? = nil
    var mono = false

    var body: some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).font(mono ? T.mono(10.5, .medium) : T.ui(11, .medium)).lineLimit(1)
        }
        .foregroundStyle(tint ?? T.text2)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill((tint ?? T.text3).opacity(tint == nil ? 0.0 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint == nil ? T.line : (tint ?? T.line).opacity(0.25), lineWidth: 1))
        .fixedSize()
    }
}

struct Avatar: View {
    let name: String
    var url: String = ""
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(Avatar.color(for: name))
            Text(Avatar.initials(name)).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            if let u = URL(string: url), !url.isEmpty {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }

    static func initials(_ s: String) -> String {
        let parts = s.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }

    static func color(for s: String) -> Color {
        let palette: [Color] = [T.accent, T.purple, T.green, T.orange, Color(red: 0.25, green: 0.6, blue: 0.85), Color(red: 0.85, green: 0.4, blue: 0.6)]
        let h = s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }
}

struct Kbd: View {
    let keys: String
    var body: some View {
        Text(keys).font(T.ui(10.5, .medium)).foregroundStyle(T.text3)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(T.line, lineWidth: 1))
    }
}

/// A row that lights on hover, the way every Linear list does.
struct HoverRow<Content: View>: View {
    var selected = false
    var height: CGFloat? = 40
    /// A hairline under the row, inset like its content, so long lists read
    /// as rows (in light mode especially). Cards hide the last one under their border.
    var divider = true
    let content: () -> Content
    @StateObject private var hover = Box(false)

    var body: some View {
        content()
            .frame(minHeight: height)
            .padding(.horizontal, 20)
            .background(selected ? T.selected : hover.v ? T.hover : Color.clear)
            .overlay(alignment: .bottom) { if divider { RowDivider() } }
            .contentShape(Rectangle())
            .hoverBox(hover)
    }
}

/// The hairline between list rows.
struct RowDivider: View {
    var inset: CGFloat = 20
    var body: some View { Rectangle().fill(T.line.opacity(0.7)).frame(height: 1).padding(.horizontal, inset) }
}

/// Group header in a list: icon, label, count — on a faint band.
struct GroupHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var icon: AnyView? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let icon { icon }
            Text(title).font(T.ui(12.5, .medium)).foregroundStyle(T.text)
            if let count { Text(verbatim: "\(count)").font(T.ui(12)).foregroundStyle(T.text3) }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
        .background(T.raised.opacity(0.55))
    }
}

extension GroupHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, icon: AnyView? = nil) {
        self.init(title: title, count: count, icon: icon) { EmptyView() }
    }
}

/// The bar across the top of every page: title on the left, actions right.
struct PageHeader<Actions: View>: View {
    @Environment(AppModel.self) var model
    let title: String
    var subtitle: String = ""
    var icon: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(T.text2) }
            Text(title).font(T.ui(14, .semibold)).foregroundStyle(T.text)
            if !subtitle.isEmpty { Text(subtitle).font(T.ui(12.5)).foregroundStyle(T.text3).lineLimit(1) }
            Spacer()
            actions()
        }
        .padding(.horizontal, 20)
        .padding(.leading, model.sidebarHidden ? T.lightsInset : 0)
        .frame(height: T.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String = "", icon: String? = nil) {
        self.init(title: title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

/// Small borderless toolbar button with an SF Symbol.
struct IconButton: View {
    let icon: String
    var help: String = ""
    var spinning = false
    var size: CGFloat = 28
    var on = false
    var tint: Color? = nil
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 13 / 28, weight: .medium))
                .foregroundStyle(tint ?? (hover.v || on ? T.text : T.text2))
                // A symbol effect stops as soon as `spinning` goes false; a
                // repeatForever rotation could keep turning after the load ended.
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: spinning)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size / 4, style: .continuous).fill(hover.v ? T.hover : on ? T.selected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.9))
        .help(help)
        .hoverBox(hover)
    }
}

/// Linear's buttons: compact, 6pt radius, either filled accent or hairline.
struct LButton: ButtonStyle {
    var primary = false
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        LButtonBody(label: configuration.label, pressed: configuration.isPressed, primary: primary, danger: danger)
    }
}

private struct LButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let primary: Bool
    let danger: Bool
    @Environment(\.isEnabled) private var enabled
    @StateObject private var hover = Box(false)

    var body: some View {
        label
            .font(T.ui(12.5, .medium))
            .foregroundStyle(primary ? .white : danger ? T.red : T.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(primary ? T.accent : hover.v ? T.hover : T.raised))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(primary && hover.v ? 0.08 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(primary ? Color.clear : T.line, lineWidth: 1))
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(enabled ? (pressed ? 0.85 : 1) : 0.45)
            .contentShape(Rectangle())
            .hoverBox(hover)
            .animation(pressed ? .easeOut(duration: 0.08) : M.pop, value: pressed)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var detail: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(T.text3)
                .frame(width: 64, height: 64)
                .background(Circle().fill(T.raised.opacity(0.6)))
            Text(title).font(T.ui(14, .medium)).foregroundStyle(T.text2)
            if !detail.isEmpty { Text(detail).font(T.ui(12)).foregroundStyle(T.text3).multilineTextAlignment(.center).frame(maxWidth: 340) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// A hairline-bordered text field in Linear's input style.
struct LField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(T.ui(13))
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.raised))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(focused ? T.accent.opacity(0.7) : T.line, lineWidth: 1))
            .shadow(color: T.accent.opacity(focused ? 0.25 : 0), radius: 4)
            .animation(M.hover, value: focused)
            .onSubmit(onSubmit)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(T.lineSoft).frame(height: 1) }
}

// MARK: - Motion

//
// Springs throughout, so an animation interrupted mid-flight (hover out before
// hover in finished, a second click on a tab) carries its velocity instead of
// restarting along a fixed curve.

enum M {
    /// Hover tints: quick and critically damped, no overshoot.
    static let hover = Animation.spring(response: 0.18, dampingFraction: 1)
    /// Layout changes (rows, tabs, panels, sidebar): settles in ~0.35s, a hint of give.
    static let snappy = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Page and tab cross-fades: no bounce, slightly slower than layout.
    static let page = Animation.spring(response: 0.3, dampingFraction: 1)
    /// Small pops (press, badges, toasts, popovers): lively with a touch of overshoot.
    static let pop = Animation.spring(response: 0.28, dampingFraction: 0.78)
    /// Leaving content gets out of the way faster than new content arrives.
    static let exit = Animation.easeOut(duration: 0.12)
}

extension AnyTransition {
    /// Route changes: the new page eases up a few points as it fades in; the
    /// old one fades out quickly so two heavy pages overlap only briefly.
    static var page: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity.animation(M.exit))
    }
    /// Popovers and sheets: grow from just under full size at the top edge.
    static var panel: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)).animation(M.exit))
    }
}

extension View {
    func hoverBox(_ box: Box<Bool>) -> some View {
        onHover { h in if box.v != h { withAnimation(M.hover) { box.v = h } } }
    }

    /// Staggered entrance; the stagger caps out so long lists don't trickle in for seconds.
    func rise(_ index: Int) -> some View { modifier(Rise(delay: Double(min(max(index, 0), 10)) * 0.035)) }

    func shimmer(_ on: Bool = true) -> some View { modifier(Shimmer(on: on)) }

    /// The grouped-card surface shared by Settings and Usage.
    func card(radius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(T.raised.opacity(0.5), in: shape)
            .clipShape(shape)
            .overlay(shape.stroke(T.line, lineWidth: 1))
    }

    func floatingPanel(radius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(T.raised.opacity(0.72), in: shape)
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(T.rim, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: T.shade.opacity(0.5), radius: 40, y: 18)
    }
}

struct Rise: ViewModifier {
    let delay: Double
    @StateObject private var shown = Box(false)
    func body(content: Content) -> some View {
        content
            .opacity(shown.v ? 1 : 0)
            .offset(y: shown.v ? 0 : 8)
            .onAppear { if !shown.v { withAnimation(M.snappy.delay(delay)) { shown.v = true } } }
    }
}

struct Shimmer: ViewModifier {
    let on: Bool
    @StateObject private var phase = Box(false)
    func body(content: Content) -> some View {
        content
            .overlay {
                if on {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(g.size.width * 0.5, 30))
                            .offset(x: phase.v ? g.size.width : -max(g.size.width * 0.5, 30))
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear { if !phase.v { withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { phase.v = true } } }
    }
}

// MARK: - Native pieces

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var active = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = active ? .active : .followsWindowActiveState
    }
}

/// The page filter: a quiet pill that lights up while you type. ⌘F focuses
/// it, Esc clears it, the × empties it.
struct SearchField: View {
    var placeholder = "Filter"
    @Binding var text: String
    @FocusState private var focused: Bool
    @StateObject private var hover = Box(false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focused || !text.isEmpty ? T.accent : T.text3)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(T.text3))
                .textFieldStyle(.plain).font(T.ui(12.5)).foregroundStyle(T.text)
                .focused($focused)
                .onExitCommand { if text.isEmpty { focused = false } else { text = "" } }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(T.text3)
                }
                .buttonStyle(.plain).help("Clear (Esc)")
                .transition(.scale.combined(with: .opacity))
            } else if !focused {
                Text("⌘F").font(T.ui(10.5, .medium)).foregroundStyle(T.text3.opacity(0.8)).transition(.opacity)
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(shape.fill(focused ? T.panel : hover.v ? T.hover : T.raised.opacity(0.55)))
        .overlay(shape.stroke(focused ? T.accent.opacity(0.65) : T.line, lineWidth: 1))
        .shadow(color: focused ? T.accent.opacity(0.25) : .clear, radius: 6)
        .contentShape(shape)
        .onTapGesture { focused = true }
        .hoverBox(hover)
        .animation(M.hover, value: focused)
        .animation(M.hover, value: text.isEmpty)
        .background(Button("") { focused = true }.keyboardShortcut("f").opacity(0).allowsHitTesting(false))
    }
}

struct SlidingTabs: View {
    struct Tab: Identifiable {
        let id: String
        let label: String
        var count = 0
        var hot = false
        var icon: String? = nil
    }

    let tabs: [Tab]
    @Binding var selection: String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { t in
                let on = selection == t.id
                Button { withAnimation(M.snappy) { selection = t.id } } label: {
                    HStack(spacing: 6) {
                        if let icon = t.icon { Image(systemName: icon).font(.system(size: 10.5, weight: .medium)) }
                        Text(t.label).font(T.ui(12, .medium))
                        if t.count > 0 {
                            Text(verbatim: "\(t.count)").font(T.ui(10.5, .semibold)).monospacedDigit()
                                .foregroundStyle(t.hot ? .white : T.text2)
                                .padding(.horizontal, 5).frame(minHeight: 15)
                                .background(Capsule().fill(t.hot ? T.orange : T.line))
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(on ? T.text : T.text2)
                    .padding(.horizontal, 11).frame(height: 26)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6).fill(T.selected)
                                .shadow(color: T.shade.opacity(0.25), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(T.raised.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.lineSoft, lineWidth: 1))
        .fixedSize()
    }
}

struct Pressable: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            // Press down immediately, spring back on release.
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : M.pop, value: configuration.isPressed)
    }
}
