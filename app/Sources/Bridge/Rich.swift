import AppKit
import SwiftUI

// MARK: - Selectable rich text
//
// SwiftUI's `.textSelection(.enabled)` selects inside one `Text` at a time, so
// a reply rendered as a stack of paragraphs could only be selected a
// paragraph at a time. RichText draws a whole block of Markdown (or any
// attributed string) in one TextKit 1 NSTextView: drag across headings,
// lists and code, ⌘A, ⌘C, Look Up and Services all work like a native app.

struct RichText: NSViewRepresentable {
    /// Changes whenever the content does; the attributed string is rebuilt only then.
    let key: String
    let build: () -> NSAttributedString

    init(key: String, build: @escaping () -> NSAttributedString) {
        self.key = key
        self.build = build
    }

    init(markdown: String, size: CGFloat = 13, color: NSColor = NT.text) {
        self.key = "md|\(size)|\(color.hash)|\(markdown)"
        self.build = { RichMarkdown.render(markdown, size: size, color: color) }
    }

    init(plain: String, font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular), color: NSColor = NT.text2) {
        self.key = "plain|\(font.pointSize)|\(color.hash)|\(plain)"
        self.build = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2
            return NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        }
    }

    func makeNSView(context: Context) -> RichTextView { RichTextView() }

    func updateNSView(_ v: RichTextView, context: Context) {
        if v.key != key { v.set(RichCache.get(key, build), key: key) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: RichTextView, context: Context) -> CGSize? {
        let w = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return v.fit(width: w ?? 10_000, natural: w == nil)
    }
}

/// Rendered blocks shared across views: a chat switched back to, a pane
/// reopened or a message scrolled back into a lazy stack draws from here
/// instead of parsing its Markdown again. Bounded by characters held.
enum RichCache {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.totalCostLimit = 12_000_000
        return c
    }()

    static func get(_ key: String, _ build: () -> NSAttributedString) -> NSAttributedString {
        let k = key as NSString
        if let hit = cache.object(forKey: k) { return hit }
        let s = build()
        cache.setObject(s, forKey: k, cost: s.length + k.length)
        return s
    }
}

final class RichTextView: NSTextView {
    private(set) var key = ""
    private var heights: [CGFloat: CGSize] = [:]
    private var copyButtons: [NSButton] = []
    /// Code blocks, as ranges in the text, for their copy buttons.
    var codeRanges: [NSRange] = []

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        backgroundColor = .clear
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFontPanel = false
        isAutomaticLinkDetectionEnabled = false
        selectedTextAttributes = [.backgroundColor: NT.accent.withAlphaComponent(0.38)]
        linkTextAttributes = [.foregroundColor: NT.link, .cursor: NSCursor.pointingHand]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    func set(_ s: NSAttributedString, key: String) {
        self.key = key
        heights = [:]
        codeRanges = []
        s.enumerateAttribute(.richCode, in: NSRange(location: 0, length: s.length)) { v, r, _ in if v != nil { codeRanges.append(r) } }
        textStorage?.setAttributedString(s)
        setSelectedRange(NSRange(location: min(selectedRange().location, s.length), length: 0))
        placeCopyButtons()
        invalidateIntrinsicContentSize()
    }

    /// Height for a width (or the natural size when SwiftUI asks for the ideal one).
    func fit(width: CGFloat, natural: Bool) -> CGSize {
        if let h = heights[width] { return h }
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let old = tc.size
        tc.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        tc.size = old
        let out = CGSize(width: natural ? ceil(used.width) : width, height: ceil(used.height))
        if heights.count > 32 { heights.removeAll() }
        heights[width] = out
        return out
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        if let tc = textContainer, tc.size.width != bounds.width {
            tc.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
        placeCopyButtons()
    }

    private func placeCopyButtons() {
        while copyButtons.count > codeRanges.count { copyButtons.removeLast().removeFromSuperview() }
        while copyButtons.count < codeRanges.count {
            let b = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")!, target: self, action: #selector(copyCode(_:)))
            b.isBordered = false
            b.contentTintColor = NT.text3
            b.symbolConfiguration = .init(pointSize: 10.5, weight: .regular)
            b.toolTip = "Copy code"
            addSubview(b)
            copyButtons.append(b)
        }
        guard let lm = layoutManager, let tc = textContainer else { return }
        for (i, r) in codeRanges.enumerated() where r.location + r.length <= (textStorage?.length ?? 0) {
            let g = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: min(1, r.length)), actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: g, in: tc)
            copyButtons[i].tag = i
            copyButtons[i].frame = NSRect(x: bounds.width - 30, y: rect.minY - 2, width: 22, height: 18)
        }
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard codeRanges.indices.contains(sender.tag), let s = textStorage else { return }
        let code = (s.string as NSString).substring(with: codeRanges[sender.tag])
        // The first line of a fenced block is its language label.
        let body = s.attribute(.richCodeLabel, at: codeRanges[sender.tag].location, effectiveRange: nil) != nil
            ? code.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
            : code
        copyToPasteboard(body)
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        sender.contentTintColor = NT.green
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            sender.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
            sender.contentTintColor = NT.text3
        }
    }

    // Scrolling over the text scrolls the transcript, not nothing.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) ?? super.scrollWheel(with: event) }

    /// Plain text with list markers as Markdown, ready to paste into a prompt.
    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        let t = (string as NSString).substring(with: selectedRange())
        copyToPasteboard(t.replacingOccurrences(of: "•\t", with: "- ")
            .replacingOccurrences(of: #"(?m)^(\d+[.)])\t"#, with: "$1 ", options: .regularExpression))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        // Keep the useful system items, drop the editing ones a read-only view can't use.
        for item in menu.items where [#selector(cut(_:)), #selector(paste(_:))].contains(item.action) { menu.removeItem(item) }
        if selectedRange().length > 0 {
            let quote = NSMenuItem(title: "Quote in Reply", action: #selector(quoteSelection), keyEquivalent: "l")
            quote.keyEquivalentModifierMask = .command
            quote.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
            quote.target = self
            menu.insertItem(quote, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func quoteSelection() {
        let s = (string as NSString).substring(with: selectedRange())
        NotificationCenter.default.post(name: .richQuote, object: s)
    }
}

extension Notification.Name {
    static let richQuote = Notification.Name("bridge.richQuote")
}

extension NSAttributedString.Key {
    static let richCode = NSAttributedString.Key("bridge.code")
    static let richCodeLabel = NSAttributedString.Key("bridge.codeLabel")
}

// MARK: - Blocks that draw their own background

/// A fenced code block, a quote's bar or a diff line: TextKit draws block
/// backgrounds square, so this one draws its own.
final class RichBlock: NSTextBlock {
    enum Style { case code, quote, band(NSColor) }
    let style: Style

    init(_ style: Style) {
        self.style = style
        super.init()
        switch style {
        case .code:
            setWidth(12, type: .absoluteValueType, for: .padding)
            setWidth(9, type: .absoluteValueType, for: .padding, edge: .minY)
            setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxY)
            setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
            setWidth(2, type: .absoluteValueType, for: .margin, edge: .maxY)
        case .quote:
            setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        case .band:
            setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
            setWidth(1, type: .absoluteValueType, for: .padding, edge: .minY)
            setWidth(1, type: .absoluteValueType, for: .padding, edge: .maxY)
        }
        setContentWidth(100, type: .percentageValueType)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(withFrame frame: NSRect, in view: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager) {
        let r = frame.insetBy(dx: 0, dy: 0)
        (view?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            switch style {
            case .code:
                let box = NSRect(x: r.minX, y: r.minY + 2, width: r.width, height: r.height - 4)
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
                NT.codeBg.setFill(); path.fill()
                NT.line.setStroke(); path.lineWidth = 1; path.stroke()
            case .quote:
                NT.line.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY + 1, width: 2.5, height: r.height - 2), xRadius: 1.25, yRadius: 1.25).fill()
            case .band(let c):
                c.setFill(); NSBezierPath(rect: r).fill()
            }
        }
    }
}

// MARK: - Markdown to an attributed string

enum RichMarkdown {
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    static func render(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = MarkdownText.parse(text)
        let wide = blocks.contains { if case .numbered(let n, _) = $0 { return n.count > 2 }; return false }
        for (i, b) in blocks.enumerated() {
            let gap: CGFloat = size >= 13 ? 9 : 7
            let piece: NSAttributedString
            switch b {
            case .para(let s):
                piece = inline(s, size: size, color: color, style: para(gap: gap))
            case .heading(let level, let s):
                let p = para(gap: gap - 3)
                p.paragraphSpacingBefore = i == 0 ? 0 : 7
                piece = inline(s, size: level == 1 ? size + 5 : level == 2 ? size + 3 : size + 1, color: NT.text, style: p, weight: .semibold)
            case .bullet(let s, let depth):
                let indent = CGFloat(depth) * 18
                let p = para(gap: nextIsList(blocks, i) ? 4 : gap, indent: indent, marker: 16)
                let line = NSMutableAttributedString(string: "•\t", attributes: [.font: font(size, .bold), .foregroundColor: NT.text3, .paragraphStyle: p])
                line.append(inline(s, size: size, color: color, style: p))
                piece = line
            case .numbered(let n, let s):
                let p = para(gap: nextIsList(blocks, i) ? 4 : gap, marker: wide ? 28 : 22)
                let line = NSMutableAttributedString(string: "\(n)\t", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: NT.text3, .paragraphStyle: p])
                line.append(inline(s, size: size, color: color, style: p))
                piece = line
            case .quote(let s):
                let p = para(gap: gap)
                p.textBlocks = [RichBlock(.quote)]
                piece = inline(s, size: size, color: NT.text2, style: p)
            case .code(let lang, let s):
                let block = RichBlock(.code)
                block.setWidth(gap + 4, type: .absoluteValueType, for: .margin, edge: .maxY)
                let p = NSMutableParagraphStyle()
                p.textBlocks = [block]
                p.lineSpacing = 2.5
                let code = NSMutableAttributedString()
                if !lang.isEmpty {
                    let lp = p.mutableCopy() as! NSMutableParagraphStyle
                    lp.paragraphSpacing = 6
                    code.append(NSAttributedString(string: lang + "\n", attributes: [.font: font(10.5, .medium), .foregroundColor: NT.text3, .paragraphStyle: lp, .richCodeLabel: true]))
                }
                code.append(NSAttributedString(string: s.isEmpty ? " " : s, attributes: [.font: mono(size - 1.5), .foregroundColor: NT.text, .paragraphStyle: p]))
                code.addAttribute(.richCode, value: true, range: NSRange(location: 0, length: code.length))
                piece = code
            case .rule:
                let p = para(gap: gap)
                let band = RichBlock(.band(NT.line))
                band.setWidth(0, type: .absoluteValueType, for: .padding)
                band.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
                band.setValue(1, type: .absoluteValueType, for: .height)
                band.setValue(1, type: .absoluteValueType, for: .maximumHeight)
                p.textBlocks = [band]
                p.maximumLineHeight = 1
                piece = NSAttributedString(string: " ", attributes: [.font: font(1), .paragraphStyle: p])
            }
            if out.length > 0 {
                // A paragraph's terminator carries its paragraph's style.
                let prev = out.attributes(at: out.length - 1, effectiveRange: nil).filter { $0.key == .paragraphStyle || $0.key == .font }
                out.append(NSAttributedString(string: "\n", attributes: prev))
            }
            out.append(piece)
        }
        return out
    }

    static func nextIsList(_ blocks: [MarkdownText.Block], _ i: Int) -> Bool {
        guard blocks.indices.contains(i + 1) else { return false }
        switch blocks[i + 1] { case .bullet, .numbered: return true; default: return false }
    }

    static func para(gap: CGFloat, indent: CGFloat = 0, marker: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = gap
        if marker > 0 {
            p.firstLineHeadIndent = indent
            p.headIndent = indent + marker
            p.tabStops = [NSTextTab(textAlignment: .left, location: indent + marker)]
        }
        return p
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) through Foundation's parser.
    static func inline(_ s: String, size: CGFloat, color: NSColor, style: NSParagraphStyle, weight: NSFont.Weight = .regular) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let parsed = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: style]
            var f = font(size, intent.contains(.stronglyEmphasized) ? .semibold : weight)
            if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) {
                f = mono(size - 1)
                attrs[.backgroundColor] = NT.selected
                attrs[.foregroundColor] = NT.text
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, isWebLink(link) { attrs[.link] = link }
            attrs[.font] = f
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

// MARK: - Live Markdown editor

/// Markdown source styled while it is edited — one surface, no preview tab.
/// The storage always holds the raw source (what you type is what saves),
/// and every edit re-applies block and inline attributes over it: a heading
/// reads big, a fence sits in a code box and the `#`/`*`/`>` markers stay
/// put but dimmed. The settings panes that edit Markdown (Pipeline, Common
/// rules) share it.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var enabled = true
    var size: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let tv = MarkdownEditView()
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
        tv.typingAttributes = MarkdownStyle.base(size)
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.view = tv
        context.coordinator.set(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = enabled
        if tv.string != text { context.coordinator.set(text) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var view: MarkdownEditView?
        private var styling = false
        private var syncing = false

        init(_ parent: MarkdownEditor) { self.parent = parent }

        /// Programmatic replace (load, revert, reset) — kept off the undo stack.
        func set(_ s: String) {
            guard let tv = view, let ts = tv.textStorage else { return }
            syncing = true
            tv.undoManager?.disableUndoRegistration()
            ts.setAttributedString(NSAttributedString(string: s))
            tv.undoManager?.enableUndoRegistration()
            syncing = false
        }

        func textStorage(_ ts: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !styling, view?.hasMarkedText() != true else { return }
            styling = true
            MarkdownStyle.apply(ts, size: parent.size)
            styling = false
        }

        func textDidChange(_ note: Notification) {
            guard !syncing, let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

final class MarkdownEditView: NSTextView {
    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isRichText = true
        drawsBackground = false
        textContainerInset = NSSize(width: 5, height: 8)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFindPanel = true
        allowsUndo = true
        insertionPointColor = NT.text
        selectedTextAttributes = [.backgroundColor: NT.accent.withAlphaComponent(0.38)]
        linkTextAttributes = [.foregroundColor: NT.link, .cursor: NSCursor.pointingHand]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
}

/// Attributes over the raw Markdown in an editable storage: base text for
/// everything, then a block pass (headings, lists, quotes, code, rules) and
/// an inline pass (code spans, bold, italic, strike, links, placeholders)
/// per line. Ranges a construct claims are left alone by later constructs.
enum MarkdownStyle {
    static func base(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 5
        return [.font: RichMarkdown.font(size), .foregroundColor: NT.text, .paragraphStyle: p]
    }

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let heading = rx(#"^ {0,3}(#{1,6})[ \t]+"#)
    private static let bullet = rx(#"^( *)([-*+])[ \t]+"#)
    private static let numbered = rx(#"^( *)(\d+[.)])[ \t]+"#)
    private static let quote = rx(#"^ {0,3}>[ \t]?"#)
    private static let rule = rx(#"^ {0,3}(-{3,}|\*{3,})[ \t]*$"#)
    private static let codeSpan = rx(#"`[^`\n]+`"#)
    private static let bold = rx(#"(\*\*|__)([^\n]+?)\1"#)
    private static let italicStar = rx(#"\*([^\s*][^*\n]*?)\*"#)
    private static let italicLine = rx(#"(?<![A-Za-z0-9_])_([^\s_][^_\n]*?)_(?![A-Za-z0-9_])"#)
    private static let strike = rx(#"~~([^\n]+?)~~"#)
    private static let link = rx(#"\[([^\]\n]+)\]\(([^)\n]*)\)"#)
    private static let placeholder = rx(#"\{\{[A-Z_]+\}\}"#)

    static func apply(_ ts: NSTextStorage, size: CGFloat) {
        let ns = ts.string as NSString
        ts.setAttributes(base(size), range: NSRange(location: 0, length: ns.length))
        guard ns.length > 0 else { return }
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: NT.text3]
        var loc = 0
        var code = NSRange(location: NSNotFound, length: 0)
        while loc < ns.length {
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(line)
            var end = line.length
            while end > 0, [10, 13].contains(ns.character(at: line.location + end - 1)) { end -= 1 }
            let body = NSRange(location: line.location, length: end)
            let trimmed = ns.substring(with: body).trimmingCharacters(in: .whitespaces)
            if code.location != NSNotFound {
                code.length = NSMaxRange(line) - code.location
                if trimmed.hasPrefix("```") {
                    ts.addAttributes([.font: RichMarkdown.mono(size - 1.5), .foregroundColor: NT.text3], range: body)
                    codeBox(ts, code, size)
                    code.location = NSNotFound
                } else {
                    ts.addAttributes([.font: RichMarkdown.mono(size - 1.5), .foregroundColor: NT.text], range: body)
                }
                continue
            }
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("```") {
                code = line
                ts.addAttributes([.font: RichMarkdown.mono(size - 1.5), .foregroundColor: NT.text3], range: body)
                continue
            }
            var content = body
            if let m = heading.firstMatch(in: ts.string, range: body) {
                let level = m.range(at: 1).length
                ts.addAttributes(dim, range: m.range)
                content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(body) - NSMaxRange(m.range))
                ts.addAttribute(.font, value: RichMarkdown.font(level == 1 ? size + 5 : level == 2 ? size + 3 : size + 1, .semibold), range: content)
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 3
                p.paragraphSpacing = 4
                if line.location > 0 { p.paragraphSpacingBefore = 7 }
                ts.addAttribute(.paragraphStyle, value: p, range: line)
            } else if let m = bullet.firstMatch(in: ts.string, range: body) ?? numbered.firstMatch(in: ts.string, range: body) {
                let depth = min(m.range(at: 1).length / 2, 3)
                let marker = m.range(at: 2)
                let digits = ns.substring(with: marker).first?.isNumber == true
                ts.addAttributes([.font: digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : RichMarkdown.font(size, .bold), .foregroundColor: NT.text3], range: NSRange(location: marker.location, length: NSMaxRange(m.range) - marker.location))
                let indent = CGFloat(depth) * 18
                let hang: CGFloat = digits ? (marker.length > 3 ? 28 : 22) : 16
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 3
                p.paragraphSpacing = 4
                p.firstLineHeadIndent = indent
                p.headIndent = indent + hang
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent + hang)]
                ts.addAttribute(.paragraphStyle, value: p, range: line)
                content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(body) - NSMaxRange(m.range))
            } else if let m = quote.firstMatch(in: ts.string, range: body) {
                ts.addAttributes(dim, range: m.range)
                content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(body) - NSMaxRange(m.range))
                ts.addAttribute(.foregroundColor, value: NT.text2, range: content)
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 3
                p.paragraphSpacing = 5
                p.textBlocks = [RichBlock(.quote)]
                ts.addAttribute(.paragraphStyle, value: p, range: line)
            } else if rule.firstMatch(in: ts.string, range: body) != nil {
                ts.addAttributes([.foregroundColor: NT.line, .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NT.text3], range: body)
                continue
            }
            inline(ts, content, size)
        }
        if code.location != NSNotFound { codeBox(ts, code, size) }
    }

    /// One rounded box around the whole fenced region, fences included —
    /// the same block instance on every paragraph is what merges them.
    private static func codeBox(_ ts: NSTextStorage, _ r: NSRange, _ size: CGFloat) {
        let block = RichBlock(.code)
        block.setWidth(size >= 13 ? 13 : 11, type: .absoluteValueType, for: .margin, edge: .maxY)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2.5
        p.textBlocks = [block]
        ts.addAttribute(.paragraphStyle, value: p, range: r)
    }

    private static func inline(_ ts: NSTextStorage, _ r: NSRange, _ size: CGFloat) {
        guard r.length > 0 else { return }
        let s = ts.string
        var claimed: [NSRange] = []
        func free(_ m: NSTextCheckingResult) -> Bool {
            !claimed.contains { NSIntersectionRange($0, m.range).length > 0 }
        }
        for m in codeSpan.matches(in: s, range: r) where free(m) {
            claimed.append(m.range)
            ts.addAttributes([.font: RichMarkdown.mono(size - 1), .foregroundColor: NT.text, .backgroundColor: NT.selected], range: m.range)
        }
        for m in bold.matches(in: s, range: r) where free(m) {
            claimed.append(m.range)
            ts.addAttribute(.font, value: RichMarkdown.font(size, .semibold), range: m.range(at: 2))
            ts.addAttribute(.foregroundColor, value: NT.text3, range: m.range(at: 1))
            ts.addAttribute(.foregroundColor, value: NT.text3, range: NSRange(location: NSMaxRange(m.range(at: 2)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 2))))
        }
        for m in italicStar.matches(in: s, range: r) + italicLine.matches(in: s, range: r) where free(m) {
            claimed.append(m.range)
            let i = NSFontManager.shared.convert(RichMarkdown.font(size), toHaveTrait: .italicFontMask)
            ts.addAttribute(.font, value: i, range: m.range(at: 1))
            ts.addAttribute(.foregroundColor, value: NT.text3, range: NSRange(location: m.range.location, length: 1))
            ts.addAttribute(.foregroundColor, value: NT.text3, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        for m in strike.matches(in: s, range: r) where free(m) {
            claimed.append(m.range)
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            ts.addAttribute(.foregroundColor, value: NT.text3, range: NSRange(location: m.range.location, length: 2))
            ts.addAttribute(.foregroundColor, value: NT.text3, range: NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for m in link.matches(in: s, range: r) where free(m) {
            claimed.append(m.range)
            ts.addAttributes([.foregroundColor: NT.link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 1))
            ts.addAttribute(.foregroundColor, value: NT.text3, range: NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))))
            ts.addAttribute(.foregroundColor, value: NT.text3, range: NSRange(location: m.range.location, length: 1))
        }
        for m in placeholder.matches(in: s, range: r) where free(m) {
            ts.addAttributes([.font: RichMarkdown.font(size, .semibold), .foregroundColor: NT.accent], range: m.range)
        }
    }
}
