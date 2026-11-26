#!/usr/bin/env swift
//
// Renders Bridge's app icon: a macOS-style squircle (824pt body on a 1024
// canvas, the standard icon grid) with an indigo gradient and a bridge mark.
//
//   swift scripts/icon.swift [out.png]          1024px PNG (default app/icon.png)
//   swift scripts/icon.swift --iconset DIR      every iconutil size, each drawn at its own
//                                                    resolution (strokes thickened at 16/32px)
//
// The in-app `Logo` view (app/Sources/Bridge/App.swift) draws the same
// mark from the same unit coordinates; keep the two in step.

import AppKit
import CoreGraphics
import SwiftUI

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

/// Apple's icon shape: a rounded rect with continuous-curvature corners, taken
/// from SwiftUI so it is exactly the curve the in-app Logo draws.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

// Mark geometry in unit space (0…1 across the body, y down), shared with Logo.
enum Mark {
    static let corner: CGFloat = 0.225
    static let deckY: CGFloat = 0.615
    static let deckL: CGFloat = 0.17, deckR: CGFloat = 0.83
    static let archCX: CGFloat = 0.5, archR: CGFloat = 0.255   // semicircular arch on the deck
    static let pierBottom: CGFloat = 0.76
    static let hangers: [CGFloat] = [-0.125, 0, 0.125]
    static let stroke: CGFloat = 0.068
    static let hanger: CGFloat = 0.03
}

func render(px: Int) -> CGImage {
    let S: CGFloat = 1024, body: CGFloat = 824, origin = (S - body) / 2
    // Small sizes get heavier strokes so the mark survives the downscale.
    let weight: CGFloat = px <= 16 ? 1.45 : px <= 32 ? 1.25 : px <= 64 ? 1.1 : 1
    let hangers = px <= 16 ? [] : Mark.hangers

    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Flip to y-down so the geometry reads like SwiftUI, then work in 1024 units.
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)

    let rect = CGRect(x: origin, y: origin, width: body, height: body)
    let shape = squircle(rect, radius: body * Mark.corner)
    func U(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin + x * body, y: origin + y * body) }
    let k = CGFloat(px) / S   // shadows are specified in device pixels

    // Drop shadow beneath the body (the grid leaves room for it).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 24 * k, color: rgb(0x000000, 0.30))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x2A2370)); ctx.fillPath()
    ctx.restoreGState()

    // Body: lit indigo top-left to deep violet bottom-right, a soft top glow,
    // and a darker band under the deck like water under the bridge.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let base = CGGradient(colorsSpace: space, colors: [rgb(0x8A8FF7), rgb(0x5E6AD2), rgb(0x3B2C9C), rgb(0x24185E)] as CFArray, locations: [0, 0.38, 0.78, 1])!
    ctx.drawLinearGradient(base, start: U(0.15, 0), end: U(0.85, 1), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: U(0.5, -0.1), startRadius: 0, endCenter: U(0.5, -0.1), endRadius: body * 0.85, options: [])
    let water = CGGradient(colorsSpace: space, colors: [rgb(0x000000, 0), rgb(0x0A0630, 0.32)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(water, start: U(0.5, Mark.deckY), end: U(0.5, 1), options: [])
    ctx.restoreGState()

    // Mark: arch, deck, piers and hangers, filled as one shape so overlaps don't double up.
    let m = CGMutablePath()
    func stroke(_ w: CGFloat, _ build: (CGMutablePath) -> Void) {
        let q = CGMutablePath(); build(q)
        m.addPath(q.copy(strokingWithWidth: w * weight * body, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }
    stroke(Mark.stroke) { $0.addArc(center: U(Mark.archCX, Mark.deckY), radius: Mark.archR * body, startAngle: .pi, endAngle: 0, clockwise: false) }
    stroke(Mark.stroke) { $0.move(to: U(Mark.deckL, Mark.deckY)); $0.addLine(to: U(Mark.deckR, Mark.deckY)) }
    for side: CGFloat in [-1, 1] {
        let x = Mark.archCX + side * Mark.archR
        stroke(Mark.stroke) { $0.move(to: U(x, Mark.deckY)); $0.addLine(to: U(x, Mark.pierBottom)) }
    }
    for dx in hangers {
        let top = Mark.deckY - sqrt(Mark.archR * Mark.archR - dx * dx)
        stroke(Mark.hanger) { $0.move(to: U(Mark.archCX + dx, top)); $0.addLine(to: U(Mark.archCX + dx, Mark.deckY)) }
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: rgb(0x120A40, 0.5))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(m); ctx.clip(using: .winding)
    let ink = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xE4E3FF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ink, start: U(0.5, 0.3), end: U(0.5, Mark.pierBottom + 0.05), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Rim: bright along the top edge, faintly dark along the bottom.
    if px >= 64 {
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.addPath(shape); ctx.setLineWidth(5); ctx.replacePathWithStrokedPath(); ctx.clip()
        let rim = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0.04), rgb(0x000000, 0.18)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(rim, start: U(0.5, 0), end: U(0.5, 1), options: [])
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--iconset", args.count > 1 {
    let dir = args[1]
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for s in [16, 32, 128, 256, 512] {
        write(render(px: s), "\(dir)/icon_\(s)x\(s).png")
        write(render(px: s * 2), "\(dir)/icon_\(s)x\(s)@2x.png")
    }
    print("wrote \(dir)")
} else {
    let out = args.first ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../app/icon.png").standardized.path
    write(render(px: 1024), out)
    print("wrote \(out)")
}
