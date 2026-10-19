#if ZEYT_UITEST
import AppKit

/// Scripted UI run for layout tests, only in builds with `-DZEYT_UITEST` (`./build.sh uitest`).
///
/// `ZEYT_UISCRIPT=<file>` holds one command per line, `ZEYT_UIOUT=<dir>` gets the frames and `log.txt`:
///
///     open                    show the popover
///     reopen                  close the popover and show it again
///     settings general|export|agent   open that settings tab (not activated) and capture it
///     labels                  open the labels window (not activated) and capture it
///     burst 8                 after every following action, capture 8 frames ~16 ms apart (0 = off)
///     key up|down|left|right|enter|tab|esc|backspace|<character> [shift] [option] [cmd]
///     type text …             one real key event per character (space included)
///     click x y               mouse click at x/y in points from the popover's top left
///     move x y                mouse moved there (hover)
///     wait 300                milliseconds
///     snap name               one frame
///     frames 30 name          30 frames ~16 ms apart without an action (caret blink, animations)
///     dump name               frames of all text fields and time fields (points, from the top left)
///     appearance light|dark
///     notifications on|off    pretend zeyt may (not) post notifications (hides the banner)
///     quit
///
/// Key and mouse events go straight to the popover window (`sendEvent`), without activating zeyt:
/// the user can keep working meanwhile, and their keystrokes don't end up in the test. Only
/// `NSApp.currentEvent` is not set this way (Shift+Enter is checked through it).
@MainActor
final class UITestScript {
    private let view: NSView
    private let open: () -> Void
    private let close: () -> Void
    private let settings: (String) -> NSView?
    private let labels: () -> NSView?
    private let notifications: (Bool) -> Void
    private let out: URL
    private var lines: [String]
    private var burst = 0
    private var frame = 0
    private var log: [String] = []

    static func startIfRequested(view: @escaping () -> NSView?, open: @escaping () -> Void, close: @escaping () -> Void,
                                 settings: @escaping (String) -> NSView?, labels: @escaping () -> NSView?,
                                 notifications: @escaping (Bool) -> Void) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ZEYT_UISCRIPT"], let outPath = env["ZEYT_UIOUT"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // The user's own keystrokes must not land in the test (the script's events bypass monitors).
        blocker = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let v = view() else { exit(2) }
                let run = UITestScript(view: v, open: open, close: close, settings: settings,
                                       labels: labels, notifications: notifications, out: URL(fileURLWithPath: outPath), lines: text)
                current = run
                run.next()
            }
        }
    }

    private static var current: UITestScript?
    private static var blocker: Any?

    private init(view: NSView, open: @escaping () -> Void, close: @escaping () -> Void,
                 settings: @escaping (String) -> NSView?, labels: @escaping () -> NSView?,
                 notifications: @escaping (Bool) -> Void,
                 out: URL, lines: String) {
        self.view = view
        self.open = open
        self.close = close
        self.settings = settings
        self.labels = labels
        self.notifications = notifications
        self.out = out
        self.lines = lines.split(separator: "\n").map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("//") }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    private var window: NSWindow? { view.window }

    private func next() {
        guard !lines.isEmpty else { return finish() }
        let line = lines.removeFirst()
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0], arg = parts.count > 1 ? parts[1] : ""
        let args = arg.split(separator: " ").map(String.init)
        log.append(String(format: "%03d ", frame) + line + "   [" + focusDescription() + "]")
        switch cmd {
        case "open": open(); after(300)
        case "settings":
            captureWindow(settings(arg), "settings-" + arg)
        case "labels": captureWindow(labels(), "labels")
        case "reopen":
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { self.open(); self.after(400) }
        case "burst": burst = Int(arg) ?? 0; next()
        case "wait": DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(arg) ?? 100)) { self.next() }
        case "snap": capture(arg); next()
        case "frames":
            let saved = burst
            burst = Int(args.first ?? "") ?? 30
            settle(args.dropFirst().joined(separator: "_")) { self.burst = saved; self.next() }
        case "dump": dump(arg); next()
        case "appearance":
            let appearance = NSAppearance(named: arg == "light" ? .aqua : .darkAqua)
            NSApp.appearance = appearance
            window?.appearance = appearance
            after(300)
        case "notifications": notifications(arg == "on"); after(300)
        case "key": key(args); settle(line)
        case "type": typeChars(Array(arg), line)
        case "click", "move":
            mouse(cmd, x: CGFloat(Double(args[0]) ?? 0), y: CGFloat(Double(args[1]) ?? 0))
            settle(line)
        case "quit": finish()
        default: log.append("?? unknown: \(line)"); next()
        }
    }

    private func after(_ ms: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { self.next() }
    }

    /// Captures the burst (or waits a bit) after an action, then goes on.
    private func settle(_ name: String, then: (() -> Void)? = nil) {
        let tag = name.replacingOccurrences(of: " ", with: "_").filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let count = burst
        var k = 0
        func step() {
            if k < count {
                capture("\(tag)-\(k)")
                k += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { step() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(count > 0 ? 30 : 150)) {
                    if let then { then() } else { self.next() }
                }
            }
        }
        // First frame right after the event was handled (next run-loop turn).
        DispatchQueue.main.async { step() }
    }

    private func typeChars(_ chars: [Character], _ line: String) {
        guard let c = chars.first else { return next() }
        post(code: c == " " ? 49 : 0, chars: String(c), mods: [])
        settle("type \(c == " " ? "space" : String(c))") { self.typeChars(Array(chars.dropFirst()), line) }
    }

    private static let codes: [String: (UInt16, String)] = [
        "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)), "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "enter": (36, "\r"), "tab": (48, "\t"), "esc": (53, "\u{1b}"), "backspace": (51, "\u{7f}"),
    ]

    private func key(_ args: [String]) {
        guard let name = args.first else { return }
        let (code, chars) = Self.codes[name] ?? (0, name)
        var mods: NSEvent.ModifierFlags = []
        if args.contains("shift") { mods.insert(.shift) }
        if args.contains("option") { mods.insert(.option) }
        if args.contains("cmd") { mods.insert(.command) }
        post(code: code, chars: chars, mods: mods)
    }

    private func post(code: UInt16, chars: String, mods: NSEvent.ModifierFlags) {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: mods,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            // Shortcuts (⌘…) go through the Edit menu and the window's key equivalents, like NSApp does.
            if mods.contains(.command), kind == .keyDown,
               NSApp.mainMenu?.performKeyEquivalent(with: e) == true || window?.performKeyEquivalent(with: e) == true { continue }
            window?.sendEvent(e)
        }
    }

    private func mouse(_ kind: String, x: CGFloat, y: CGFloat) {
        guard let window, let content = window.contentView else { return }
        // Script coordinates: points from the top left of the popover content.
        let inView = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        let p = view.convert(inView, to: nil)
        func event(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
        }
        if kind == "move" {
            if let e = event(.mouseMoved) { window.sendEvent(e) }
            return
        }
        // Straight to the view under the point: in an inactive window the first click would only
        // activate it. The mouse-up is queued first for the view's tracking loop.
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp),
              let hit = content.hitTest(content.convert(p, from: nil)) else { return }
        NSApp.postEvent(up, atStart: false)
        hit.mouseDown(with: down)
    }

    /// Captures a window's content once it has laid out, then goes on.
    private func captureWindow(_ v: NSView?, _ name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800)) {
            if let v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: self.out.appendingPathComponent(String(format: "%03d-%@.png", self.frame, name)))
                self.frame += 1
            }
            self.next()
        }
    }

    private func capture(_ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let file = out.appendingPathComponent(String(format: "%03d-%@.png", frame, name))
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        frame += 1
    }

    private func dump(_ name: String) {
        var lines: [String] = ["== \(name)"]
        func walk(_ v: NSView) {
            if v is NSTextField || v is TimeSegmentView {
                let r = v.convert(v.bounds, to: view)
                let top = view.isFlipped ? r.minY : view.bounds.height - r.maxY
                let text = (v as? NSTextField).map { "'\($0.stringValue)' ph '\($0.placeholderAttributedString?.string ?? "")'" } ?? "time"
                lines.append(String(format: "x %6.1f…%6.1f  y %6.1f h %4.1f  ", r.minX, r.maxX, top, r.height) + text)
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        log.append(contentsOf: lines)
    }

    private func focusDescription() -> String {
        let r = window?.firstResponder
        if let tv = r as? NSTextView, let f = tv.delegate as? NSTextField {
            return "text '\(f.stringValue)' sel \(tv.selectedRange().location)+\(tv.selectedRange().length)"
        }
        if let t = r as? TimeSegmentView {
            return "time \(t.hour.map { String($0) } ?? "-"):\(t.minute.map { String($0) } ?? "-") \(t.selected.map { "\($0)" } ?? "-")"
        }
        return r.map { "\(type(of: $0))" } ?? "none"
    }

    private func finish() {
        log.append("end   [" + focusDescription() + "]")
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }
}
#endif
