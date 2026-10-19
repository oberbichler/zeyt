// Frames a capture from the UI test for the README: a popover under a drawn menu bar, or a window
// with a drawn title bar, on a plain wallpaper.
//   swift docs/make-screenshot.swift <in.png> <out.png> light|dark popover "<status item title>"
//   swift docs/make-screenshot.swift <in.png> <out.png> light|dark window "<window title>"
// A real screen capture would contain whatever else is on the screen; this only shows zeyt.
import AppKit

let args = CommandLine.arguments
guard args.count == 6, let content = NSImage(contentsOfFile: args[1]), ["popover", "window"].contains(args[4]) else {
    print("usage: make-screenshot.swift <in.png> <out.png> light|dark popover|window <title>")
    exit(1)
}
let dark = args[3] == "dark"
let isPopover = args[4] == "popover"
let title = args[5]

let scale: CGFloat = 2
let contentRep = NSBitmapImageRep(data: content.tiffRepresentation!)!
let inner = NSSize(width: CGFloat(contentRep.pixelsWide) / 2, height: CGFloat(contentRep.pixelsHigh) / 2)  // captures are 2x
let barHeight: CGFloat = 24, arrow: CGFloat = 9, titleHeight: CGFloat = 28
let radius: CGFloat = isPopover ? 12 : 10
let size = isPopover ? NSSize(width: inner.width + 200, height: inner.height + 80)
                     : NSSize(width: inner.width + 80, height: inner.height + titleHeight + 80)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Wallpaper
let wall = dark
    ? NSGradient(colors: [NSColor(red: 0.10, green: 0.12, blue: 0.24, alpha: 1), NSColor(red: 0.28, green: 0.16, blue: 0.36, alpha: 1)])!
    : NSGradient(colors: [NSColor(red: 0.62, green: 0.76, blue: 0.95, alpha: 1), NSColor(red: 0.86, green: 0.74, blue: 0.93, alpha: 1)])!
wall.draw(in: NSRect(origin: .zero, size: size), angle: -60)

let fg = dark ? NSColor.white : NSColor.black
// A popover's frame takes its own background (top left pixel). Window captures have no background
// of their own (it is drawn by the window), so they get the system's window color.
let background = isPopover ? contentRep.colorAt(x: 4, y: 4) ?? .windowBackgroundColor
                           : dark ? NSColor(white: 0.196, alpha: 1) : NSColor(white: 0.925, alpha: 1)

/// Fills `shape` with a shadow, draws `image` into `rect` clipped to it, and outlines it.
func drawFramed(_ shape: NSBezierPath, image: NSImage, in rect: NSRect, extra: () -> Void = {}) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.6 : 0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    background.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    background.setFill()
    shape.fill()
    image.draw(in: rect)
    extra()
    NSGraphicsContext.restoreGraphicsState()
    (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.12)).setStroke()
    shape.lineWidth = 1
    shape.stroke()
}

if isPopover {
    // Menu bar
    let bar = NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
    (dark ? NSColor(white: 0, alpha: 0.35) : NSColor(white: 1, alpha: 0.55)).setFill()
    bar.fill()

    let font = NSFont.menuBarFont(ofSize: 0)
    func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular).applying(.init(paletteColors: [fg]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    }
    func drawSymbol(_ image: NSImage, x: CGFloat) {
        image.draw(in: NSRect(x: x, y: bar.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
    }

    // Right to left: clock, control center, wifi, battery, zeyt
    var x = size.width - 12
    let clockFormat = DateFormatter()
    clockFormat.locale = Locale(identifier: "en_GB")
    clockFormat.dateFormat = "EEE d MMM  HH:mm"
    let clock = NSAttributedString(string: clockFormat.string(from: Date()), attributes: [.font: font, .foregroundColor: fg])
    x -= clock.size().width
    clock.draw(at: NSPoint(x: x, y: bar.midY - clock.size().height / 2))
    for name in ["switch.2", "wifi", "battery.75percent"] {
        let image = symbol(name)
        x -= image.size.width + 16
        drawSymbol(image, x: x)
    }

    let icon = symbol("clock")
    let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: fg])
    let itemWidth = icon.size.width + text.size().width + 16
    x -= itemWidth + 10
    let item = NSRect(x: x, y: bar.minY + 2, width: itemWidth, height: barHeight - 4)
    (dark ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.12)).setFill()
    NSBezierPath(roundedRect: item, xRadius: 5, yRadius: 5).fill()
    drawSymbol(icon, x: item.minX + 8)
    text.draw(at: NSPoint(x: item.minX + 8 + icon.size.width, y: bar.midY - text.size().height / 2))

    // Popover hanging off the status item, with its arrow
    let tip = NSPoint(x: item.midX, y: bar.minY - 3)
    let frame = NSRect(x: min(max(tip.x - inner.width / 2, 12), size.width - inner.width - 12),
                       y: tip.y - arrow - inner.height, width: inner.width, height: inner.height)
    let shape = NSBezierPath()
    shape.move(to: NSPoint(x: frame.minX + radius, y: frame.maxY))
    shape.line(to: NSPoint(x: tip.x - arrow - 2, y: frame.maxY))
    shape.curve(to: tip, controlPoint1: NSPoint(x: tip.x - arrow / 2, y: frame.maxY), controlPoint2: NSPoint(x: tip.x - 2, y: tip.y))
    shape.curve(to: NSPoint(x: tip.x + arrow + 2, y: frame.maxY),
                controlPoint1: NSPoint(x: tip.x + 2, y: tip.y), controlPoint2: NSPoint(x: tip.x + arrow / 2, y: frame.maxY))
    shape.appendArc(from: NSPoint(x: frame.maxX, y: frame.maxY), to: NSPoint(x: frame.maxX, y: frame.minY), radius: radius)
    shape.appendArc(from: NSPoint(x: frame.maxX, y: frame.minY), to: NSPoint(x: frame.minX, y: frame.minY), radius: radius)
    shape.appendArc(from: NSPoint(x: frame.minX, y: frame.minY), to: NSPoint(x: frame.minX, y: frame.maxY), radius: radius)
    shape.appendArc(from: NSPoint(x: frame.minX, y: frame.maxY), to: NSPoint(x: frame.maxX, y: frame.maxY), radius: radius)
    shape.close()
    drawFramed(shape, image: content, in: frame)
} else {
    // Window: title bar with traffic lights and title above the content
    let window = NSRect(x: 40, y: 48, width: inner.width, height: inner.height + titleHeight)
    let contentRect = NSRect(x: window.minX, y: window.minY, width: inner.width, height: inner.height)
    let titleBar = NSRect(x: window.minX, y: contentRect.maxY, width: window.width, height: titleHeight)
    drawFramed(NSBezierPath(roundedRect: window, xRadius: radius, yRadius: radius), image: content, in: contentRect) {
        background.setFill()
        titleBar.fill()
        for (i, color) in [NSColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                           NSColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: titleBar.minX + 14 + CGFloat(i) * 20, y: titleBar.midY - 6, width: 12, height: 12)).fill()
        }
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.titleBarFont(ofSize: 0),
                                                                 .foregroundColor: fg.withAlphaComponent(0.85)])
        text.draw(at: NSPoint(x: titleBar.midX - text.size().width / 2, y: titleBar.midY - text.size().height / 2))
    }
}

NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
