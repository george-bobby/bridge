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
        if v.key != key { v.set(build(), key: key) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: RichTextView, context: Context) -> CGSize? {
        let w = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return v.fit(width: w ?? 10_000, natural: w == nil)
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
        linkTextAttributes = [.foregroundColor: NSColor(srgbRed: 0.52, green: 0.58, blue: 0.98, alpha: 1), .cursor: NSCursor.pointingHand]
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
            if let link = run.link { attrs[.link] = link }
            attrs[.font] = f
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}
