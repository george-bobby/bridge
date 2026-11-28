import AppKit
import SwiftUI

// MARK: - Explorer (VS Code's file tree, read-only)

/// A chat's second tab, with VS Code's activity strip down its left edge:
/// Explorer (every file in the folder) or Source Control / Changes.
struct WorkspacePage: View {
    @Environment(AppModel.self) var model
    let runId: String
    @AppStorage("changes.mode") private var mode = "scm"

    var orchestrator: Bool { model.sessions.first(where: { $0.id == runId })?.isOrchestrator == true }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                IconButton(icon: "doc.on.doc", help: "Explorer", size: B.regular, on: mode == "files") { mode = "files" }
                IconButton(icon: orchestrator ? "arrow.triangle.branch" : "plusminus", help: orchestrator ? "Source Control" : "Changes", size: B.regular, on: mode != "files") { mode = "scm" }
                Spacer()
            }
            .padding(.top, 8).frame(width: 40)
            .background(T.bg)
            .overlay(alignment: .trailing) { Rectangle().fill(T.lineSoft).frame(width: 1) }
            Group {
                if mode == "files" { ExplorerView(runId: runId) }
                else if orchestrator { SourceControlView(runId: runId) }
                else { ChangesView(runId: runId) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Every file in the folder as a tree (git ls-files, so .gitignore holds),
/// changed files tinted like VS Code; a click opens it read-only beside.
struct ExplorerView: View {
    let runId: String
    @StateObject private var nodes = Box<[ChangeNode]>([])
    @StateObject private var kinds = Box<[String: String]>([:])
    @StateObject private var info = Box(JSON.null)
    @StateObject private var open = Box(Set<String>())
    @StateObject private var query = Box("")
    @StateObject private var picked = Box("")
    @StateObject private var file = Box(JSON.null)
    @StateObject private var loading = Box(false)

    var base: String { "/api/runs/\(API.q(runId))" }

    var body: some View {
        GeometryReader { g in
            if g.size.width >= 680 {
                HSplitView {
                    sidebar.frame(minWidth: 240, idealWidth: 320, maxWidth: 460)
                    CodeViewer(file: file.v, path: picked.v, loading: loading.v).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VSplitView {
                    sidebar.frame(minHeight: 200, idealHeight: g.size.height * 0.45, maxHeight: .infinity)
                    CodeViewer(file: file.v, path: picked.v, loading: loading.v).frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: load)
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            SectionBar(title: folderName, count: nil) {
                IconButton(icon: "rectangle.compress.vertical", help: "Collapse Folders", size: B.small) { open.v = [] }
                IconButton(icon: "arrow.clockwise", help: "Refresh", size: B.small) { load() }
            }
            LField(placeholder: "Filter files", text: $query.v).padding(.horizontal, 10).padding(.bottom, 6)
            if info.v["truncated"].bool {
                Text("Showing the first 20,000 files").font(T.ui(11)).foregroundStyle(T.text3).padding(.horizontal, 14).padding(.bottom, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView { rows.padding(.bottom, 6) }
        }
        .background(T.panel)
    }

    var folderName: String {
        let root = info.v["root"].string
        return root.isEmpty ? "Explorer" : URL(fileURLWithPath: root).lastPathComponent
    }

    var rows: some View {
        let q = query.v.trimmingCharacters(in: .whitespaces).lowercased()
        // A filter shows every match with its folders open; else what's been expanded.
        let list: [(node: ChangeNode, depth: Int)] = q.isEmpty
            ? ChangeNode.rows(nodes.v, isOpen: { open.v.contains($0) })
            : Array(ChangeNode.rows(ChangeNode.filter(nodes.v, q), isOpen: { _ in true }).prefix(3000))
        return LazyVStack(spacing: 0) {
            ForEach(list, id: \.node.path) { r in
                let isFile = r.node.file != nil
                ChangeRow(node: r.node, depth: r.depth, selected: isFile && r.node.path == picked.v, folded: !isFile && q.isEmpty && !open.v.contains(r.node.path), plain: true, tint: tint(r.node.path))
                    .onTapGesture {
                        if isFile { show(r.node.path) } else if q.isEmpty { withAnimation(M.snappy) { open.v.formSymmetricDifference([r.node.path]) } }
                    }
            }
        }
    }

    /// VS Code's git decorations: modified yellow, added green.
    func tint(_ path: String) -> Color? {
        switch kinds.v[path] {
        case "modified", "renamed": return T.yellow
        case "added": return T.green
        case "deleted": return T.red
        default: return nil
        }
    }

    func load() {
        Task {
            async let t = try? API.get("\(base)/tree")
            async let s = try? API.get("\(base)/changes")
            if let t = await t {
                info.v = t
                nodes.v = ChangeNode.tree(t["files"].array.map { JSON.obj(["path": $0]) })
            }
            if let s = await s {
                kinds.v = Dictionary(s["files"].array.map { ($0["path"].string, $0["kind"].string) }, uniquingKeysWith: { a, _ in a })
            }
            // Start on the first changed file, its folders open, like the Changes tab.
            if picked.v.isEmpty, let first = kinds.v.keys.sorted().first(where: { kinds.v[$0] != "deleted" }) {
                var p = (first as NSString).deletingLastPathComponent
                while !p.isEmpty { open.v.insert(p); p = (p as NSString).deletingLastPathComponent }
                show(first)
            }
        }
    }

    func show(_ path: String) {
        picked.v = path
        loading.v = true
        Task {
            let out = try? await API.get("\(base)/file?path=\(API.q(path))")
            if picked.v == path { file.v = out ?? .null; loading.v = false }
        }
    }
}

/// A read-only file: path bar, then the code with line numbers and highlighting.
struct CodeViewer: View {
    let file: JSON
    let path: String
    let loading: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if path.isEmpty {
                    Text("Pick a file").font(T.ui(12)).foregroundStyle(T.text3)
                } else {
                    FileGlyph(name: path, size: 14)
                    Text(path).font(T.ui(12)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.head)
                    if file["lines"].int > 0 { Text(verbatim: "\(file["lines"].int) lines").font(T.ui(11)).foregroundStyle(T.text3) }
                    Chip(text: "Read-only", icon: "lock")
                }
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 34)
            Hairline()
            content
        }
        .background(T.bg)
    }

    @ViewBuilder var content: some View {
        if path.isEmpty || loading && file.isNull {
            Color.clear
        } else if file.isNull {
            EmptyState(icon: "exclamationmark.triangle", title: "Can't open this file")
        } else if file["binary"].bool {
            EmptyState(icon: "doc.zipper", title: "Binary file", detail: ByteCountFormatter.string(fromByteCount: Int64(file["size"].int), countStyle: .file))
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    RichText(key: "code|\(path)|\(file["text"].string.hashValue)") { CodeText.render(file["text"].string, path: path) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if file["truncated"].bool {
                        Text("Showing the first \(file["lines"].int) lines of \(ByteCountFormatter.string(fromByteCount: Int64(file["size"].int), countStyle: .file)). Open it in an editor for the rest.")
                            .font(T.ui(11.5)).foregroundStyle(T.text3)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.topLeading)
        }
    }
}

// MARK: - Highlighting

/// Line numbers (a gutter copy leaves out) and a light, line-by-line
/// highlighter: comments, strings, numbers, keywords and type names. Not a
/// parser; enough to read code the way an editor shows it.
enum CodeText {
    static let gutter = NSAttributedString.Key("bridgeGutter")

    static let keywords: Set<String> = [
        "import", "export", "from", "default", "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
        "break", "continue", "class", "struct", "enum", "interface", "type", "extends", "implements", "new", "this", "self", "super", "static",
        "public", "private", "protected", "internal", "fileprivate", "final", "async", "await", "try", "catch", "throw", "throws", "finally",
        "in", "of", "as", "is", "func", "guard", "defer", "where", "extension", "protocol", "init", "deinit", "some", "any", "mutating", "override",
        "def", "lambda", "pass", "with", "yield", "elif", "not", "and", "or", "None", "True", "False", "nil", "null", "undefined", "true", "false",
        "fn", "pub", "impl", "use", "mod", "match", "mut", "package", "go", "chan", "select", "defer", "range", "typeof", "instanceof", "void",
        "require", "module", "echo", "then", "fi", "done", "esac", "local", "readonly",
    ]

    static func lineComment(_ path: String) -> [String] {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml", "ini", "conf", "r", "pl", "dockerfile", "mk": return ["#"]
        case "sql", "lua", "hs": return ["--"]
        case "md", "txt", "json": return []
        default:
            let name = (path as NSString).lastPathComponent.lowercased()
            return name == "dockerfile" || name == "makefile" || name.hasPrefix(".env") || name.hasPrefix(".git") ? ["#"] : ["//", "#!"]
        }
    }

    static let token = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d[\d_.xXa-fA-F]*\b|\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    static func render(_ text: String, path: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let digits = max(3, String(lines.count).count)
        let indent = CGFloat(digits + 2) * ("0" as NSString).size(withAttributes: [.font: font]).width
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byCharWrapping
        para.lineSpacing = 1.5
        para.headIndent = indent   // wrapped lines start past the numbers
        let comments = lineComment(path)
        let markdown = ["md", "mdx"].contains((path as NSString).pathExtension.lowercased())
        var inBlock = false
        for (i, line) in lines.enumerated() {
            let num = String(i + 1)
            out.append(NSAttributedString(string: String(repeating: " ", count: digits - num.count) + num + "  ", attributes: [.font: font, .foregroundColor: NT.text3.withAlphaComponent(0.7), gutter: true, .paragraphStyle: para]))
            let l = String(line)
            let start = out.length
            out.append(NSAttributedString(string: l + (i == lines.count - 1 ? "" : "\n"), attributes: [.font: font, .foregroundColor: NT.text, .paragraphStyle: para]))
            if markdown { if l.hasPrefix("#") { out.addAttribute(.foregroundColor, value: NT.accent, range: NSRange(location: start, length: (l as NSString).length)) }; continue }
            inBlock = colour(l, at: start, in: out, comments: comments, inBlock: inBlock)
        }
        return out
    }

    /// Colours one line in place; returns whether a /* */ comment is still open.
    static func colour(_ l: String, at start: Int, in out: NSMutableAttributedString, comments: [String], inBlock: Bool) -> Bool {
        let ns = l as NSString
        let full = NSRange(location: 0, length: ns.length)
        let paint = { (r: NSRange, c: NSColor) in out.addAttribute(.foregroundColor, value: c, range: NSRange(location: start + r.location, length: r.length)) }
        var from = 0
        if inBlock {
            let end = ns.range(of: "*/")
            if end.location == NSNotFound { paint(full, NT.text3); return true }
            from = end.location + 2
            paint(NSRange(location: 0, length: from), NT.text3)
        }
        var open = false
        token.enumerateMatches(in: l, range: NSRange(location: from, length: ns.length - from)) { m, _, stop in
            guard let r = m?.range else { return }
            // A comment before this token ends the line (or opens a block).
            let before = ns.substring(with: NSRange(location: from, length: r.location - from))
            if let c = comments.first(where: { before.contains($0) }) {
                let at = from + (before as NSString).range(of: c).location
                paint(NSRange(location: at, length: ns.length - at), NT.text3); stop.pointee = true; from = ns.length; return
            }
            if comments.contains("//"), before.contains("/*") {
                let at = from + (before as NSString).range(of: "/*").location
                let end = ns.range(of: "*/", options: [], range: NSRange(location: at + 2, length: ns.length - at - 2))
                if end.location == NSNotFound { paint(NSRange(location: at, length: ns.length - at), NT.text3); open = true; stop.pointee = true; from = ns.length; return }
                paint(NSRange(location: at, length: end.location + 2 - at), NT.text3)
                if r.location < end.location + 2 { from = end.location + 2; return }
            }
            from = r.location + r.length
            let word = ns.substring(with: r)
            let first = word.unicodeScalars.first!
            if first == "\"" || first == "'" || first == "`" { paint(r, NT.green) }
            else if CharacterSet.decimalDigits.contains(first) { paint(r, NT.orange) }
            else if keywords.contains(word) { paint(r, NT.purple) }
            else if CharacterSet.uppercaseLetters.contains(first) && word.count > 1 { paint(r, NT.yellow) }
        }
        if !open, from < ns.length {
            let rest = ns.substring(from: from)
            if let c = comments.first(where: { rest.contains($0) }) {
                let at = from + (rest as NSString).range(of: c).location
                paint(NSRange(location: at, length: ns.length - at), NT.text3)
            } else if comments.contains("//"), (rest as NSString).range(of: "/*").location != NSNotFound {
                let at = from + (rest as NSString).range(of: "/*").location
                let end = ns.range(of: "*/", options: [], range: NSRange(location: at + 2, length: ns.length - at - 2))
                paint(NSRange(location: at, length: (end.location == NSNotFound ? ns.length : end.location + 2) - at), NT.text3)
                open = end.location == NSNotFound
            }
        }
        return open
    }
}
