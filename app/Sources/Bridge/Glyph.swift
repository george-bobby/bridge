import AppKit
import SwiftUI

/// The menu bar item: the app icon's bridge mark (`BridgeMark`) as a template
/// image, so macOS tints it for light and dark menu bars. `badge` adds a dot
/// (ringed in clear space) while something needs attention.
enum MenuGlyph {
    static let size = NSSize(width: 24, height: 16)

    /// Only the packaged app gets a menu bar item: dev builds (`.build/release/Bridge`,
    /// demo runs) and snapshot runs would each add a second icon next to it.
    static let shown = Bundle.main.bundlePath.hasSuffix(".app")
        && ProcessInfo.processInfo.environment["BRIDGE_SNAPSHOT_DIR"] == nil

    static func image(badge: Bool) -> NSImage {
        let img = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // The mark fitted by its own bounds to the canvas's left, leaving the
            // top-right corner for the badge so the item never changes width.
            let mark = BridgeMark(weight: 1.2, hangers: true).path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).cgPath
            let b = mark.boundingBoxOfPath
            let pad: CGFloat = 2, k = (rect.height - pad * 2) / b.height
            var t = CGAffineTransform(translationX: 1 - b.minX * k, y: rect.midY - b.midY * k).scaledBy(x: k, y: k)
            guard let fitted = mark.copy(using: &t) else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(fitted); ctx.fillPath()
            if badge {
                let r: CGFloat = 3, c = CGPoint(x: rect.maxX - r, y: rect.minY + r)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: c.x - r - 1.2, y: c.y - r - 1.2, width: (r + 1.2) * 2, height: (r + 1.2) * 2))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = badge ? "Bridge, needs attention" : "Bridge"
        return img
    }

    static let plain = image(badge: false)
    static let badged = image(badge: true)
}
