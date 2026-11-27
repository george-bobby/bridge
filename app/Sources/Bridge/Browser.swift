import AppKit
import Combine
import ImageIO
import QuickLook
import SwiftUI
import WebKit

// MARK: - Browser tabs

struct BrowserTab: Identifiable, Hashable {
    let id = UUID().uuidString
    var url: String
}

@MainActor
final class WebPage: ObservableObject {
    let view: WKWebView
    @Published var title = ""
    @Published var url = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var progress = 0.0
    private var watches: [NSKeyValueObservation] = []

    init(url: String) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        watches = [
            view.observe(\.title) { [weak self] v, _ in Task { @MainActor in self?.title = v.title ?? "" } },
            view.observe(\.url) { [weak self] v, _ in Task { @MainActor in self?.url = v.url?.absoluteString ?? "" } },
            view.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
            view.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.loading = v.isLoading } },
            view.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
        ]
        load(url)
    }

    func load(_ raw: String) {
        guard let u = WebPage.normalize(raw) else { return }
        url = u.absoluteString
        view.load(URLRequest(url: u))
    }

    static func normalize(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return URL(string: t).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        }
        if t.range(of: #"^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?(/.*)?$"#, options: .regularExpression) != nil || t.range(of: #"^:\d+"#, options: .regularExpression) != nil {
            return URL(string: "http://" + (t.hasPrefix(":") ? "localhost" + t : t))
        }
        if !t.contains(" ") && t.contains(".") { return URL(string: "https://" + t) }
        return URL(string: "https://duckduckgo.com/?q=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t))
    }

    var label: String {
        if !title.isEmpty { return title }
        if let h = URL(string: url)?.host { return h + (URL(string: url)?.port.map { ":\($0)" } ?? "") }
        return "New tab"
    }
}

@MainActor
final class WebStore {
    private var pages: [String: WebPage] = [:]

    func page(for tab: BrowserTab) -> WebPage {
        if let p = pages[tab.id] { return p }
        let p = WebPage(url: tab.url)
        pages[tab.id] = p
        return p
    }

    func existing(_ id: String) -> WebPage? { pages[id] }

    func drop(_ id: String) {
        pages[id]?.view.stopLoading()
        pages[id] = nil
    }
}

struct WebViewHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @Environment(AppModel.self) var model
    @ObservedObject var page: WebPage
    @StateObject private var address = Box("")
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IconButton(icon: "chevron.left", help: "Back") { page.view.goBack() }.disabled(!page.canGoBack).opacity(page.canGoBack ? 1 : 0.4)
                IconButton(icon: "chevron.right", help: "Forward") { page.view.goForward() }.disabled(!page.canGoForward).opacity(page.canGoForward ? 1 : 0.4)
                IconButton(icon: page.loading ? "xmark" : "arrow.clockwise", help: page.loading ? "Stop" : "Reload") {
                    if page.loading { page.view.stopLoading() } else { page.view.reload() }
                }
                HStack(spacing: 7) {
                    Image(systemName: page.url.hasPrefix("https") ? "lock.fill" : "globe").font(.system(size: 10.5)).foregroundStyle(T.text3)
                    TextField("Search or enter an address", text: $address.v)
                        .textFieldStyle(.plain).font(T.ui(12.5)).focused($editing)
                        .onSubmit { page.load(address.v); editing = false }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.raised))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(editing ? T.accent.opacity(0.6) : T.line, lineWidth: 1))
                .overlay(alignment: .bottomLeading) {
                    if page.loading {
                        GeometryReader { g in
                            Capsule().fill(T.accent).frame(width: g.size.width * max(page.progress, 0.05), height: 2)
                                .animation(M.snappy, value: page.progress)
                        }
                        .frame(height: 2).padding(.horizontal, 6).transition(.opacity)
                    }
                }
                .animation(M.hover, value: editing)
                IconButton(icon: "safari", help: "Open in your browser") { openURL(page.url) }
                IconButton(icon: "doc.on.doc", help: "Copy address") { copyToPasteboard(page.url) }
            }
            .padding(.horizontal, 14).frame(height: 48)
            Hairline()
            ZStack {
                WebViewHost(view: page.view).opacity(page.url.isEmpty ? 0 : 1)
                if page.url.isEmpty { start.transition(.opacity) }
            }
            .animation(M.page, value: page.url.isEmpty)
        }
        .onAppear {
            address.v = page.url
            if page.url.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { editing = true } }
        }
        .onChange(of: page.url) { if !editing { address.v = page.url } }
    }
}

extension BrowserView {
    var start: some View {
        VStack(spacing: 18) {
            Image(systemName: "globe").font(.system(size: 30, weight: .light)).foregroundStyle(T.text3)
                .frame(width: 64, height: 64).background(Circle().fill(T.raised.opacity(0.6)))
            Text("Type an address above, or open one of these").font(T.ui(14, .medium)).foregroundStyle(T.text2)
            let ports = model.servers.flatMap { sv in sv.ports.map { (port: $0, sv: sv) } }
            VStack(spacing: 6) {
                ForEach(ports, id: \.port) { p in
                    Button { page.load("http://localhost:\(p.port)") } label: {
                        HStack(spacing: 10) {
                            Chip(text: ":\(p.port)", icon: "play.fill", tint: T.green, mono: true)
                            Text(p.sv.folder).font(T.ui(12.5)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.head)
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(width: 440, height: 38)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(T.raised.opacity(0.6)))
                    }
                    .buttonStyle(Pressable(scale: 0.98))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Attachments

struct Attachment: Identifiable, Hashable {
    enum Kind: Hashable { case image, text, file, session }
    let id: String
    let kind: Kind
    let name: String
    var path = ""
    var text = ""

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Bridge/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func image(_ img: NSImage) -> Attachment? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let id = UUID().uuidString.prefix(8).lowercased()
        let url = dir.appendingPathComponent("pasted-\(id).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return Attachment(id: String(id), kind: .image, name: "Image", path: url.path)
    }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"]
    static func isImage(_ path: String) -> Bool { imageExts.contains((path as NSString).pathExtension.lowercased()) }

    static func file(_ url: URL) -> Attachment {
        Attachment(id: UUID().uuidString, kind: isImage(url.path) ? .image : .file, name: url.lastPathComponent, path: url.path)
    }

    /// Text that is nothing but existing file paths (one per line, `~` or
    /// absolute, maybe quoted or `file://`), as files; else nil.
    static func paths(in text: String) -> [URL]? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 20 else { return nil }
        var out: [URL] = []
        for raw in lines {
            var l = raw
            if l.count > 1, let f = l.first, f == l.last, f == "'" || f == "\"" { l = String(l.dropFirst().dropLast()) }
            if l.hasPrefix("file://"), let u = URL(string: l) { l = u.path }
            l = (l as NSString).expandingTildeInPath
            var dir: ObjCBool = false
            guard l.hasPrefix("/"), FileManager.default.fileExists(atPath: l, isDirectory: &dir), !dir.boolValue else { return nil }
            out.append(URL(fileURLWithPath: l))
        }
        return out
    }

    /// What ⌘V should attach instead of pasting text: copied files, a copied
    /// image, text that is only file paths, or a big paste. nil = paste as text.
    @MainActor static func fromPasteboard(_ pb: NSPasteboard = .general) -> [Attachment]? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(file)
        }
        let str = pb.string(forType: .string)
        if let str, let urls = paths(in: str) { return urls.map(file) }
        // Screenshot tools and browsers put a path or URL next to the image: the image wins.
        let hasImage = pb.availableType(from: [.png, .tiff]) != nil
        if hasImage, str == nil || !str!.contains(where: \.isWhitespace) || str!.hasPrefix("/"), let img = NSImage(pasteboard: pb), let a = image(img) {
            return [a]
        }
        if let str, isLarge(str) { return [pasted(str)] }
        return nil
    }

    static func pasted(_ text: String) -> Attachment {
        Attachment(id: UUID().uuidString, kind: .text, name: "Pasted text", text: text)
    }

    var lines: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

    static func isLarge(_ text: String) -> Bool { text.count > 1200 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 15 }

    static func compose(_ text: String, _ items: [Attachment]) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for a in items {
            switch a.kind {
            case .text: out += "\n\n```\n\(a.text)\n```"
            case .image: out += "\n\n[Attached image, read it with your file tool: \(a.path)]"
            case .file: out += "\n\n[Attached file: \(a.path)]"
            case .session: out += "\n\n[Referenced session \"\(a.name)\": read its briefing (with the path to its full transcript) at \(a.path)]"
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AttachmentChip: View {
    let item: Attachment
    let remove: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if item.kind == .image, let img = thumb.v {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: item.kind == .text ? "text.alignleft" : item.kind == .session ? "number" : "doc").font(.system(size: 13)).foregroundStyle(T.text2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(T.hover)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind == .image ? URL(fileURLWithPath: item.path).lastPathComponent : item.name).font(T.ui(12, .medium)).foregroundStyle(T.text).lineLimit(1)
                Text(item.kind == .text ? "\(item.lines) lines" : item.kind == .image ? "Image" : item.kind == .session ? "Session" : "File").font(T.ui(11)).foregroundStyle(T.text3)
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(5).padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(T.panel))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text)
                    .frame(width: 16, height: 16).background(Circle().fill(T.selected)).overlay(Circle().stroke(T.line, lineWidth: 1))
            }
            .buttonStyle(Pressable(scale: 0.85))
            .offset(x: 6, y: -6)
            .opacity(hover.v ? 1 : 0)
        }
        .hoverBox(hover)
        .help(item.kind == .text ? String(item.text.prefix(400)) : item.path)
        .onTapGesture { if !item.path.isEmpty { preview.v = URL(fileURLWithPath: item.path) } }
        .quickLookPreview($preview.v)
        .task(id: item.path) { if item.kind == .image { thumb.v = await Thumbs.load(item.path, max: 34) } }
    }
    @StateObject private var preview = Box<URL?>(nil)
    @StateObject private var thumb = Box<NSImage?>(nil)
}

// MARK: - Files in sent messages

extension Attachment {
    /// A sent message without the files it references, and those files: the
    /// `[Attached …: path]` lines the composer adds, and lines that are just
    /// an existing file's path. Cached per text (transcripts re-render often).
    @MainActor static func split(_ text: String) -> (text: String, files: [Attachment]) {
        if let hit = splitCache[text] { return hit }
        var kept: [Substring] = [], files: [Attachment] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            var path: String? = nil
            for prefix in ["[Attached image, read it with your file tool: ", "[Attached file: "] where t.hasPrefix(prefix) && t.hasSuffix("]") {
                path = String(t.dropFirst(prefix.count).dropLast())
            }
            if path == nil, t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("file://"), let u = paths(in: t)?.first { path = u.path }
            if let path {
                let url = URL(fileURLWithPath: path)
                files.append(Attachment(id: path, kind: isImage(path) ? .image : .file, name: url.lastPathComponent, path: path))
            } else {
                kept.append(line)
            }
        }
        var seen = Set<String>()
        let out = (files.isEmpty ? text : kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                   files.filter { seen.insert($0.path).inserted })
        if splitCache.count > 400 { splitCache.removeAll() }
        splitCache[text] = out
        return out
    }
    @MainActor private static var splitCache: [String: (text: String, files: [Attachment])] = [:]
}

/// Downsampled thumbnails, read off the main thread and kept in memory.
enum Thumbs {
    nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    static func load(_ path: String, max: CGFloat) async -> NSImage? {
        let key = "\(path)@\(Int(max))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max * 2]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

/// The images and files a sent message references: image thumbnails and
/// file cards; a click opens Quick Look (space bar zooms, arrows step).
struct MessageFiles: View {
    let files: [Attachment]
    @StateObject private var preview = Box<URL?>(nil)

    var body: some View {
        let images = files.filter { $0.kind == .image }
        let others = files.filter { $0.kind != .image }
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(images) { a in ImageTile(item: a) { preview.v = URL(fileURLWithPath: a.path) } }
                }
            }
            if !others.isEmpty {
                HStack(spacing: 8) {
                    ForEach(others) { a in FileTile(item: a) { preview.v = URL(fileURLWithPath: a.path) } }
                }
            }
        }
        .quickLookPreview($preview.v, in: files.map { URL(fileURLWithPath: $0.path) })
    }
}

struct ImageTile: View {
    let item: Attachment
    let open: () -> Void
    @StateObject private var img = Box<NSImage?>(nil)
    @StateObject private var missing = Box(false)
    @StateObject private var hover = Box(false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let i = img.v {
                let h: CGFloat = 120
                let w = min(260, max(60, h * i.size.width / max(1, i.size.height)))
                Image(nsImage: i).resizable().scaledToFill().frame(width: w, height: h).clipped()
            } else {
                Image(systemName: missing.v ? "photo.badge.exclamationmark" : "photo").font(.system(size: 18)).foregroundStyle(T.text3)
                    .frame(width: 120, height: 120).background(T.hover)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(hover.v ? T.accent.opacity(0.6) : T.line, lineWidth: 1))
        .scaleEffect(hover.v ? 1.015 : 1)
        .contentShape(shape)
        .onTapGesture(perform: open)
        .hoverBox(hover)
        .help(item.path)
        .contextMenu {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button { copyToPasteboard(item.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
        .task(id: item.path) {
            img.v = await Thumbs.load(item.path, max: 260)
            missing.v = img.v == nil
        }
    }
}

struct FileTile: View {
    let item: Attachment
    let open: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: item.path)
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(T.ui(12, .medium)).foregroundStyle(T.text).lineLimit(1)
                Text(exists ? (item.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "Missing")
                    .font(T.ui(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(6).padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover.v ? T.hover : T.panel))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .hoverBox(hover)
        .help(item.path)
        .contextMenu {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button { copyToPasteboard(item.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
    }
}
