import SwiftUI

// MARK: - File icons

/// A file-type icon in the spirit of VS Code's icon themes (vscode-icons,
/// Material Icon Theme): a coloured language badge ("TS", "JS", "PY") or a
/// tinted symbol, keyed by file name, then extension. Drawn, not bundled:
/// no asset catalog or SVG resources (the app builds with the Command Line
/// Tools), and it stays sharp at any size. Brand colours are fixed across
/// light and dark, the way icon themes are.
struct FileGlyph: View {
    let name: String
    var folder = false
    var size: CGFloat = 16

    var body: some View {
        let g = folder ? FileGlyph.folderGlyph(name) : FileGlyph.glyph(for: name)
        Group {
            switch g {
            case .badge(let text, let fill, let ink):
                Text(verbatim: text)
                    .font(.system(size: size * (text.count > 2 ? 0.40 : 0.48), weight: .heavy, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: size * 0.86, height: size * 0.86)
                    .background(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(fill))
            case .symbol(let symbol, let tint):
                Image(systemName: symbol)
                    .font(.system(size: size * (folder ? 0.78 : 0.74), weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    enum Glyph { case badge(String, Color, Color), symbol(String, Color) }

    // The palette: VS Code icon themes' language colours.
    static let blue = Color(red: 0.19, green: 0.47, blue: 0.78)
    static let sky = Color(red: 0.26, green: 0.65, blue: 0.96)
    static let yellow = Color(red: 0.96, green: 0.80, blue: 0.20)
    static let orange = Color(red: 0.94, green: 0.45, blue: 0.20)
    static let red = Color(red: 0.89, green: 0.30, blue: 0.24)
    static let green = Color(red: 0.30, green: 0.69, blue: 0.31)
    static let teal = Color(red: 0.15, green: 0.65, blue: 0.60)
    static let purple = Color(red: 0.58, green: 0.40, blue: 0.85)
    static let pink = Color(red: 0.91, green: 0.36, blue: 0.58)
    static let slate = Color(red: 0.56, green: 0.64, blue: 0.68)   // Material's default folder
    static let ink = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let paper = Color(red: 1, green: 1, blue: 1)

    /// Whole names first (README, Dockerfile, package.json), then the extension.
    static func glyph(for path: String) -> Glyph {
        let file = (path as NSString).lastPathComponent
        let lower = file.lowercased()
        if let g = names[lower] { return g }
        if lower.hasPrefix("readme") { return .symbol("info.circle.fill", sky) }
        if lower.hasPrefix("license") || lower.hasPrefix("licence") { return .symbol("checkmark.seal.fill", yellow) }
        if lower.hasPrefix(".env") { return .symbol("gearshape.fill", yellow) }
        if lower.hasPrefix("dockerfile") || lower.hasPrefix("docker-compose") { return .symbol("shippingbox.fill", sky) }
        if lower.contains(".test.") || lower.contains(".spec.") || lower.hasSuffix("_test.go") || lower.hasPrefix("test_") { return .symbol("flask.fill", teal) }
        let ext = (lower as NSString).pathExtension
        return extensions[ext] ?? .symbol("doc.text", slate)
    }

    static let names: [String: Glyph] = [
        "package.json": .symbol("shippingbox.fill", green),
        "package-lock.json": .symbol("lock.fill", slate),
        "pnpm-lock.yaml": .symbol("lock.fill", slate),
        "yarn.lock": .symbol("lock.fill", slate),
        "cargo.lock": .symbol("lock.fill", slate),
        "package.resolved": .symbol("lock.fill", slate),
        "package.swift": .symbol("swift", orange),
        "makefile": .symbol("hammer.fill", orange),
        ".gitignore": .symbol("arrow.triangle.branch", orange),
        ".gitattributes": .symbol("arrow.triangle.branch", orange),
        ".gitmodules": .symbol("arrow.triangle.branch", orange),
        "claude.md": .symbol("sparkle", orange),
        "agents.md": .symbol("sparkle", purple),
        "memory.md": .symbol("brain", pink),
        "tsconfig.json": .badge("TS", blue, paper),
        "go.mod": .badge("GO", sky, paper),
        "go.sum": .symbol("lock.fill", slate),
        "gemfile": .badge("RB", red, paper),
    ]

    static let extensions: [String: Glyph] = [
        "ts": .badge("TS", blue, paper), "tsx": .symbol("atom", sky), "mts": .badge("TS", blue, paper), "cts": .badge("TS", blue, paper),
        "js": .badge("JS", yellow, ink), "mjs": .badge("JS", yellow, ink), "cjs": .badge("JS", yellow, ink), "jsx": .symbol("atom", sky),
        "swift": .symbol("swift", orange),
        "py": .badge("PY", blue, yellow), "pyi": .badge("PY", blue, yellow), "ipynb": .badge("NB", orange, paper),
        "go": .badge("GO", sky, paper), "rs": .badge("RS", orange, paper), "rb": .badge("RB", red, paper),
        "java": .badge("JV", red, paper), "kt": .badge("KT", purple, paper), "kts": .badge("KT", purple, paper),
        "c": .badge("C", blue, paper), "h": .badge("H", purple, paper), "cpp": .badge("C++", blue, paper), "cc": .badge("C++", blue, paper), "hpp": .badge("H", purple, paper),
        "m": .badge("M", sky, paper), "mm": .badge("M", sky, paper), "cs": .badge("C#", purple, paper),
        "php": .badge("PHP", purple, paper), "lua": .badge("LUA", blue, paper), "dart": .badge("DT", sky, paper),
        "ex": .badge("EX", purple, paper), "exs": .badge("EX", purple, paper), "scala": .badge("SC", red, paper),
        "sql": .symbol("cylinder.split.1x2.fill", pink), "prisma": .symbol("cylinder.split.1x2.fill", teal),
        "graphql": .symbol("point.3.connected.trianglepath.dotted", pink), "gql": .symbol("point.3.connected.trianglepath.dotted", pink),
        "json": .badge("{ }", yellow, ink), "jsonc": .badge("{ }", yellow, ink), "json5": .badge("{ }", yellow, ink),
        "yaml": .symbol("list.bullet.indent", red), "yml": .symbol("list.bullet.indent", red), "toml": .symbol("list.bullet.indent", slate),
        "xml": .symbol("chevron.left.forwardslash.chevron.right", orange), "plist": .symbol("list.bullet.rectangle", slate),
        "ini": .symbol("gearshape.fill", slate), "conf": .symbol("gearshape.fill", slate), "cfg": .symbol("gearshape.fill", slate),
        "html": .symbol("chevron.left.forwardslash.chevron.right", orange), "htm": .symbol("chevron.left.forwardslash.chevron.right", orange),
        "css": .badge("#", blue, paper), "scss": .badge("#", pink, paper), "sass": .badge("#", pink, paper), "less": .badge("#", blue, paper),
        "vue": .symbol("v.square.fill", green), "svelte": .symbol("s.square.fill", orange), "astro": .symbol("sparkles", orange),
        "md": .symbol("arrow.down.square.fill", sky), "mdx": .symbol("arrow.down.square.fill", orange), "txt": .symbol("doc.plaintext", slate),
        "rst": .symbol("doc.richtext", slate), "pdf": .symbol("doc.richtext.fill", red), "csv": .symbol("tablecells", green), "tsv": .symbol("tablecells", green),
        "xlsx": .symbol("tablecells.fill", green), "docx": .symbol("doc.fill", blue),
        "sh": .symbol("terminal.fill", green), "bash": .symbol("terminal.fill", green), "zsh": .symbol("terminal.fill", green), "fish": .symbol("terminal.fill", green),
        "ps1": .symbol("terminal.fill", blue), "bat": .symbol("terminal.fill", slate),
        "png": .symbol("photo.fill", purple), "jpg": .symbol("photo.fill", purple), "jpeg": .symbol("photo.fill", purple), "gif": .symbol("photo.fill", purple),
        "webp": .symbol("photo.fill", purple), "heic": .symbol("photo.fill", purple), "ico": .symbol("photo.fill", purple), "icns": .symbol("photo.fill", purple),
        "svg": .symbol("square.on.circle.fill", orange),
        "mp4": .symbol("film.fill", pink), "mov": .symbol("film.fill", pink), "mp3": .symbol("waveform", pink), "wav": .symbol("waveform", pink),
        "zip": .symbol("archivebox.fill", slate), "gz": .symbol("archivebox.fill", slate), "tar": .symbol("archivebox.fill", slate),
        "lock": .symbol("lock.fill", slate), "log": .symbol("text.alignleft", slate), "env": .symbol("gearshape.fill", yellow),
        "pem": .symbol("key.fill", yellow), "key": .symbol("key.fill", yellow),
        "ttf": .symbol("textformat", red), "otf": .symbol("textformat", red), "woff": .symbol("textformat", red), "woff2": .symbol("textformat", red),
        "patch": .symbol("plusminus", green), "diff": .symbol("plusminus", green),
    ]

    /// Folders: Material's blue-grey, with the usual suspects in their own colour.
    static func folderGlyph(_ path: String) -> Glyph {
        let name = ((path as NSString).lastPathComponent).lowercased()
        switch name {
        case "src", "source", "sources", "lib": return .symbol("folder.fill", green)
        case "test", "tests", "__tests__", "spec", "e2e", "fixtures": return .symbol("folder.fill", teal)
        case "docs", "doc", "documentation": return .symbol("folder.fill", sky)
        case "app", "apps", "pages", "views", "components", "ui": return .symbol("folder.fill", orange)
        case "public", "assets", "static", "images", "img", "icons", "styles", "css": return .symbol("folder.fill", yellow)
        case "server", "api", "routes", "backend", "services": return .symbol("folder.fill", red)
        case "scripts", "bin", "tools", "hooks": return .symbol("folder.fill", purple)
        case ".github", ".vscode", ".claude", "config", ".config": return .symbol("folder.fill", blue)
        case "node_modules", "vendor", "packages": return .symbol("folder.fill", pink)
        default: return .symbol("folder.fill", slate)
        }
    }
}
