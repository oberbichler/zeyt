// Generates the app icon, a colored hash sign (variant A), and the design alternatives B and C.
//   swiftc -O icon/make-icon.swift -o /tmp/icongen
//   /tmp/icongen <dir>            -> A.png, B.png, C.png, sheet.png (1024 px)
//   /tmp/icongen <iconset> A      -> PNGs for iconutil -c icns <iconset> -o icon/AppIcon.icns
import AppKit

// Apple icon grid: 1024 canvas, 824 body, ~185 corner radius.
let S: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func squircle(_ ctx: CGContext, top: UInt32, bottom: UInt32) {
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: c(0x000000, 0.35))
    ctx.addPath(path); ctx.setFillColor(c(bottom)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(top), c(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    // soft top highlight
    let h = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(0xFFFFFF, 0.10), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(h, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY), options: [])
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(c(0xFFFFFF, 0.08)); ctx.setLineWidth(2); ctx.strokePath()
}

let palette: [UInt32] = [0x4C8DFF, 0x2EC4B6, 0xFF9F43, 0xA77BFF, 0x5AD06E]

/// One stroke of the hash sign, as a round-capped line.
struct Bar {
    var from: CGPoint, to: CGPoint, color: UInt32

    func stroke(_ ctx: CGContext, width: CGFloat, color: CGColor) {
        ctx.setLineCap(.round); ctx.setLineWidth(width); ctx.setStrokeColor(color)
        ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
    }
}

/// Two slanted verticals and two horizontals, centered in the body.
func hashBars(colors: [UInt32]) -> [Bar] {
    let gap: CGFloat = 112, half: CGFloat = 255, slant: CGFloat = 46
    return [
        Bar(from: CGPoint(x: 512 - half + 14, y: 512 + gap), to: CGPoint(x: 512 + half + 14, y: 512 + gap), color: colors[0]),
        Bar(from: CGPoint(x: 512 - half - 14, y: 512 - gap), to: CGPoint(x: 512 + half - 14, y: 512 - gap), color: colors[1]),
        Bar(from: CGPoint(x: 512 - gap + slant, y: 512 + half), to: CGPoint(x: 512 - gap - slant, y: 512 - half), color: colors[2]),
        Bar(from: CGPoint(x: 512 + gap + slant, y: 512 + half), to: CGPoint(x: 512 + gap - slant, y: 512 - half), color: colors[3]),
    ]
}

/// Draws the hash; with `woven` the bars go over and under each other, separated by a thin cut.
func hash(_ ctx: CGContext, colors: [UInt32], width: CGFloat = 92, woven: Bool, shadow: CGFloat) {
    let bars = hashBars(colors: colors)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: c(0x000000, shadow))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for b in bars { b.stroke(ctx, width: width, color: c(b.color)) }
    if woven {
        // (horizontal, vertical, vertical on top) for the four crossings, alternating like a weave
        for (h, v, vOnTop) in [(0, 2, true), (0, 3, false), (1, 2, false), (1, 3, true)] {
            let top = vOnTop ? bars[v] : bars[h]
            let p = intersection(bars[h], bars[v])
            ctx.saveGState()
            // Hard clip edge: with antialiasing, clear + redraw leave a faint seam along the circle.
            ctx.setShouldAntialias(false)
            ctx.addEllipse(in: CGRect(x: p.x - width, y: p.y - width, width: 2 * width, height: 2 * width)); ctx.clip()
            ctx.setShouldAntialias(true)
            ctx.setBlendMode(.clear); top.stroke(ctx, width: width + 36, color: c(0x000000))
            ctx.setBlendMode(.normal); top.stroke(ctx, width: width, color: c(top.color))
            ctx.restoreGState()
        }
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func intersection(_ a: Bar, _ b: Bar) -> CGPoint {
    let d1 = CGPoint(x: a.to.x - a.from.x, y: a.to.y - a.from.y), d2 = CGPoint(x: b.to.x - b.from.x, y: b.to.y - b.from.y)
    let t = ((b.from.x - a.from.x) * d2.y - (b.from.y - a.from.y) * d2.x) / (d1.x * d2.y - d1.y * d2.x)
    return CGPoint(x: a.from.x + t * d1.x, y: a.from.y + t * d1.y)
}

// A: woven colored hash on dark
func variantA(_ ctx: CGContext) {
    squircle(ctx, top: 0x26324F, bottom: 0x111827)
    hash(ctx, colors: Array(palette.prefix(4)), woven: true, shadow: 0.35)
}

// B: woven colored hash on light
func variantB(_ ctx: CGContext) {
    squircle(ctx, top: 0xFFFFFF, bottom: 0xE6EBF2)
    hash(ctx, colors: Array(palette.prefix(4)), woven: true, shadow: 0.12)
}

// C: plain, slightly thinner hash on dark, without weave
func variantC(_ ctx: CGContext) {
    squircle(ctx, top: 0x26324F, bottom: 0x111827)
    hash(ctx, colors: [palette[0], palette[2], palette[1], palette[3]], width: 80, woven: false, shadow: 0.35)
}

func render(_ draw: (CGContext) -> Void, size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = g.cgContext
    ctx.scaleBy(x: CGFloat(size) / S, y: CGFloat(size) / S)
    draw(ctx)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
let variants: [String: (CGContext) -> Void] = ["A": variantA, "B": variantB, "C": variantC]
if CommandLine.arguments.count > 2 {
    // iconset for one variant
    let v = variants[CommandLine.arguments[2]]!
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                       ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        render(v, size: px, to: "\(out)/icon_\(name).png")
    }
} else {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1560, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.setFillColor(c(0x2A2A2E)); ctx.fill(CGRect(x: 0, y: 0, width: 1560, height: 600))
    for (i, k) in ["A", "B", "C"].enumerated() {
        ctx.saveGState(); ctx.translateBy(x: CGFloat(30 + i * 510), y: 90); ctx.scaleBy(x: 480 / S, y: 480 / S); variants[k]!(ctx); ctx.restoreGState()
        let label = NSAttributedString(string: k, attributes: [.font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        label.draw(at: CGPoint(x: CGFloat(30 + i * 510) + 225, y: 30)); NSGraphicsContext.restoreGraphicsState()
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/sheet.png"))
    for (k, v) in variants { render(v, size: 1024, to: "\(out)/\(k).png") }
}
