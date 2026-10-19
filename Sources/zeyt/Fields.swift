import AppKit
import SwiftUI

/// Keys a field reports to its owner before handling them itself.
/// `newLineBelow`: Shift+Enter.
enum FieldCommand { case up, down, enter, newLineBelow, escape, tab, leftAtStart, rightAtEnd, deleteAtStart }

/// A request to focus a field; a new `id` triggers it once.
struct FocusRequest: Equatable {
    enum Caret { case start, end, all }
    var id: Int
    var caret: Caret = .end
}

final class FocusTextField: NSTextField {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onBlur?()
    }
}

/// Borderless NSTextField with key handling (↑ ↓ Enter Esc Tab → Backspace) and focus callbacks.
struct KeyTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var font: NSFont = .systemFont(ofSize: 13)
    var placeholderFont: NSFont?
    var textColor: NSColor = .labelColor
    var placeholderColor: NSColor = .placeholderTextColor
    var alignment: NSTextAlignment = .left
    /// Where a text that doesn't fit is cut while the field is not being edited.
    var truncation: NSLineBreakMode = .byTruncatingTail
    /// Shown instead of `text` while the field is not being edited.
    var idleText: String?
    var focus: FocusRequest?
    var onFocusChange: (Bool) -> Void = { _ in }
    var onCommand: (FieldCommand) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Always exactly the offered width: the text's own width would make SwiftUI move the field
    /// while typing past its end. The height stays the field's own (one line), so that the frame
    /// around it centres the text on the row's baseline.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeNSView(context: Context) -> FocusTextField {
        let f = FocusTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let c = context.coordinator
        f.onFocus = { [weak c, weak f] in
            guard let c, let f else { return }
            if c.parent.idleText != nil { f.stringValue = c.parent.text }
            c.parent.onFocusChange(true)
        }
        f.onBlur = { [weak c, weak f] in
            guard let c, let f else { return }
            c.parent.onFocusChange(false)
            f.stringValue = c.parent.idleText ?? c.parent.text
        }
        return f
    }

    func updateNSView(_ f: FocusTextField, context: Context) {
        let c = context.coordinator
        c.parent = self
        f.font = font
        f.textColor = textColor
        f.alignment = alignment
        f.lineBreakMode = truncation
        let ph = NSAttributedString(string: placeholder, attributes: [.font: placeholderFont ?? font, .foregroundColor: placeholderColor])
        if f.placeholderAttributedString != ph {
            f.placeholderAttributedString = ph
            // The field editor keeps the placeholder it started with; hand it the new one.
            if let editor = f.currentEditor() as? NSTextView,
               editor.responds(to: NSSelectorFromString("setPlaceholderAttributedString:")) {
                editor.perform(NSSelectorFromString("setPlaceholderAttributedString:"), with: ph)
                editor.needsDisplay = true
            }
        }
        let editing = f.currentEditor() != nil
        let shown = editing ? text : (idleText ?? text)
        // While typing, the stored value may be trimmed ("Daily " → "Daily"); keep what is typed.
        let trimmedOnly = editing && f.stringValue.trimmingCharacters(in: .whitespaces) == shown
        if f.stringValue != shown, !trimmedOnly { f.stringValue = shown }

        if let focus, focus.id != c.lastFocus {
            c.lastFocus = focus.id
            DispatchQueue.main.async {
                guard let window = f.window else { return }
                window.makeFirstResponder(f)
                guard let editor = f.currentEditor() else { return }
                let length = (f.stringValue as NSString).length
                switch focus.caret {
                case .start: editor.selectedRange = NSRange(location: 0, length: 0)
                case .end: editor.selectedRange = NSRange(location: length, length: 0)
                case .all: editor.selectAll(nil)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyTextField
        var lastFocus = 0

        init(_ parent: KeyTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let range = textView.selectedRange()
            let length = (textView.string as NSString).length
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onCommand(.down)
            case #selector(NSResponder.insertNewline(_:)):
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                return parent.onCommand(shift ? .newLineBelow : .enter)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onCommand(.escape)
            case #selector(NSResponder.insertTab(_:)): return parent.onCommand(.tab)
            case #selector(NSResponder.moveLeft(_:)):
                return range.length == 0 && range.location == 0 ? parent.onCommand(.leftAtStart) : false
            case #selector(NSResponder.moveRight(_:)):
                return range.length == 0 && range.location == length ? parent.onCommand(.rightAtEnd) : false
            case #selector(NSResponder.deleteBackward(_:)):
                return range.location == 0 && range.length == 0 ? parent.onCommand(.deleteAtStart) : false
            default: return false
            }
        }
    }
}

enum Look {
    static let semibold13 = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let regular13 = NSFont.systemFont(ofSize: 13)
    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil(exactWidth(text, font))
    }

    static func exactWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Label colors (system colors, so they follow dark mode).
    static let palette: [Color] = [
        Color(nsColor: .systemBlue), Color(nsColor: .systemPurple), Color(nsColor: .systemOrange),
        Color(nsColor: .systemTeal), Color(nsColor: .systemPink), Color(nsColor: .systemGray),
    ]
    /// Opaque panel background (#F4F4F4 like the template; dark grey in dark mode).
    static let panelNS = NSColor(name: "panel") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.165, alpha: 1) : NSColor(white: 0.957, alpha: 1)
    }
    static let panel = Color(nsColor: panelNS)
    static let warning = Color(nsColor: .systemOrange)
    static let warningText = Color(red: 0.79, green: 0.20, blue: 0.0)
}

/// Segmented time input like an HTML `type="time"` field: click selects hour or minute,
/// digits fill the segment and move on, ⌥↑/⌥↓ change it (minutes in steps of 5), ←/→ and Tab switch,
/// Backspace clears, Enter commits, Esc reverts. Commits when focus leaves.
/// ↑/↓, ← on the hour and → on the minute leave the field like in a line of text (`onNavigate`).
final class TimeSegmentView: NSView {
    enum Segment { case hour, minute }

    var hour: Int?
    var minute: Int?
    var centered = false
    var onCommit: ((Int, Int) -> Void)?
    var onEnter: (() -> Void)?
    /// Tab on the minute segment, or the minutes were typed completely: move on to the next field.
    /// Return false to just leave the field (Tab) or stay (typing).
    var onTab: (() -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    /// .up, .down, .leftAtStart, .rightAtEnd; returns whether another field took over.
    var onNavigate: ((FieldCommand) -> Bool)?

    private(set) var selected: Segment?
    private var buffer = ""
    private var original: (Int?, Int?) = (nil, nil)
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    var isFocused: Bool { window?.firstResponder === self }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Look.width("00:00", font) + 8, height: 20) }

    override func becomeFirstResponder() -> Bool {
        original = (hour, minute)
        if selected == nil { selected = .hour }
        buffer = ""
        needsDisplay = true
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        commit()
        selected = nil
        needsDisplay = true
        onFocusChange?(false)
        return true
    }

    /// ⌘V: a time like "9:30", "09.30" or "0930" from the clipboard; ⌘C copies the time.
    @objc func paste(_ sender: Any?) {
        if !paste(NSPasteboard.general.string(forType: .string) ?? "") { NSSound.beep() }
    }

    /// Takes a pasted time; false if the text is none.
    func paste(_ text: String) -> Bool {
        guard let t = Fmt.parseTime(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        hour = t.hour
        minute = t.minute
        buffer = ""
        needsDisplay = true
        return true
    }

    @objc func copy(_ sender: Any?) {
        guard let h = hour, let m = minute else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(format: "%02d:%02d", h, m), forType: .string)
    }

    func focus(_ segment: Segment = .hour) {
        selected = segment
        buffer = ""
        if !isFocused { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        focus(p.x < metrics().colon ? .hour : .minute)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126, 125:
            let up = event.keyCode == 126
            if event.modifierFlags.contains(.option) { step(up ? 1 : -1) } else { _ = onNavigate?(up ? .up : .down) }
        case 123:
            if selected == .hour { _ = onNavigate?(.leftAtStart) } else { select(.hour) }
        case 124:
            if selected == .minute { _ = onNavigate?(.rightAtEnd) } else { select(.minute) }
        case 48:
            if event.modifierFlags.contains(.shift) { select(.hour) }
            else if selected == .hour { select(.minute) }
            else if onTab?() != true { window?.makeFirstResponder(nil) }
        case 51, 117:
            if selected == .hour { hour = nil } else { minute = nil }
            buffer = ""
        case 36, 76:
            commit()
            if event.modifierFlags.contains(.shift), onNavigate?(.newLineBelow) == true { break }
            if let onEnter { onEnter() } else { window?.makeFirstResponder(nil) }
        case 53:
            (hour, minute) = original
            window?.makeFirstResponder(nil)
        default:
            guard let c = event.characters?.first else { return }
            if let d = c.wholeNumberValue, c.isASCII { type(d) }
            else if ":. ".contains(c) { select(.minute) }
            else { NSSound.beep() }
        }
        needsDisplay = true
    }

    private func select(_ s: Segment) {
        selected = s
        buffer = ""
    }

    private func type(_ d: Int) {
        guard let seg = selected else { return }
        let maxFirst = seg == .hour ? 2 : 5
        if buffer.isEmpty {
            buffer = "\(d)"
            set(seg, d)
            if d > maxFirst { advance() }
        } else {
            let v = Int(buffer)! * 10 + d
            set(seg, v <= (seg == .hour ? 23 : 59) ? v : d)
            advance()
        }
    }

    /// Segment typed completely: hour → minute → next field.
    private func advance() {
        buffer = ""
        if selected == .hour { selected = .minute } else { _ = onTab?() }
    }

    private func set(_ seg: Segment, _ v: Int) {
        if seg == .hour { hour = v } else { minute = v }
    }

    private func step(_ delta: Int) {
        buffer = ""
        switch selected ?? .hour {
        case .hour:
            hour = ((hour ?? 0) + delta + 24) % 24
        case .minute:
            let m = minute ?? 0
            let next = delta > 0 ? (m / 5 + 1) * 5 : ((m + 4) / 5 - 1) * 5
            minute = (next + 60) % 60
        }
    }

    private func commit() {
        buffer = ""
        guard let h = hour, let m = minute else {
            (hour, minute) = original
            return
        }
        if original.0 != h || original.1 != m {
            original = (h, m)
            onCommit?(h, m)
        }
    }

    private func metrics() -> (x: CGFloat, seg: CGFloat, colonW: CGFloat, colon: CGFloat) {
        let seg = Look.width("00", font)
        let colonW = Look.width(":", font)
        let total = seg * 2 + colonW
        let x = centered ? (bounds.width - total) / 2 : 4
        return (x, seg, colonW, x + seg + colonW / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let l = metrics()
        let lineHeight = font.ascender - font.descender
        // Half a point up: on the baseline the text fields beside it use (measured in the popover).
        let y = (bounds.height - lineHeight) / 2 - 0.5
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        func text(_ v: Int?) -> String { v.map { String(format: "%02d", $0) } ?? "--" }
        let parts: [(Segment?, String, CGFloat, CGFloat)] = [
            (.hour, text(hour), l.x, l.seg),
            (nil, ":", l.x + l.seg, l.colonW),
            (.minute, text(minute), l.x + l.seg + l.colonW, l.seg),
        ]
        for (seg, str, x, w) in parts {
            if let seg, seg == selected, isFocused {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 1, y: y - 1, width: w + 2, height: lineHeight + 2), xRadius: 3, yRadius: 3).fill()
            }
            let a = (seg != nil && (seg == .hour ? hour : minute) == nil)
                ? attrs.merging([.foregroundColor: NSColor.tertiaryLabelColor]) { $1 } : attrs
            (str as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: a)
        }
    }
}

struct TimeSegments: NSViewRepresentable {
    let date: Date
    var centered = false
    var focus: FocusRequest?
    var onCommit: (Date) -> Void
    var onEnter: (() -> Void)?
    var onTab: (() -> Bool)?
    var onNavigate: ((FieldCommand) -> Bool)?
    var onFocusChange: (Bool) -> Void = { _ in }

    final class Coordinator { var lastFocus = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TimeSegmentView {
        let v = TimeSegmentView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateNSView(_ v: TimeSegmentView, context: Context) {
        v.centered = centered
        v.onEnter = onEnter
        v.onTab = onTab
        v.onNavigate = onNavigate
        v.onFocusChange = onFocusChange
        v.onCommit = { h, m in
            onCommit(Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: date)!)
        }
        if !v.isFocused {
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            if v.hour != c.hour || v.minute != c.minute {
                v.hour = c.hour
                v.minute = c.minute
                v.needsDisplay = true
            }
        }
        if let focus, focus.id != context.coordinator.lastFocus {
            context.coordinator.lastFocus = focus.id
            // Caret .end = minute segment (coming from the right), otherwise the hour.
            DispatchQueue.main.async { v.focus(focus.caret == .end ? .minute : .hour) }
        }
    }
}

/// Time cell: transparent in rows (border on hover, accent ring while editing).
/// `bare` draws no chrome at all – the input bar frames it together with the label field.
struct TimeField: View {
    let date: Date
    var bare = false
    var onFocusChange: (Bool) -> Void = { _ in }
    var focus: FocusRequest?
    var onCommit: (Date) -> Void
    var onEnter: (() -> Void)?
    var onTab: (() -> Bool)?
    var onNavigate: ((FieldCommand) -> Bool)?
    @State private var focused = false
    @State private var hovering = false

    init(date: Date, bare: Bool = false, focus: FocusRequest? = nil, onCommit: @escaping (Date) -> Void,
         onEnter: (() -> Void)? = nil, onTab: (() -> Bool)? = nil, onNavigate: ((FieldCommand) -> Bool)? = nil,
         onFocusChange: @escaping (Bool) -> Void = { _ in }) {
        self.date = date
        self.bare = bare
        self.onFocusChange = onFocusChange
        self.focus = focus
        self.onCommit = onCommit
        self.onEnter = onEnter
        self.onTab = onTab
        self.onNavigate = onNavigate
    }

    var body: some View {
        let r = RoundedRectangle(cornerRadius: 5)
        let chrome = !bare && (focused || hovering)
        TimeSegments(date: date, centered: bare, focus: focus, onCommit: onCommit, onEnter: onEnter, onTab: onTab,
                     onNavigate: onNavigate, onFocusChange: { focused = $0; onFocusChange($0) })
            .frame(height: bare ? 28 : 24)
            .background(r.fill(chrome ? Color(nsColor: .controlBackgroundColor) : .clear))
            .overlay {
                if bare {
                    EmptyView()
                } else if focused {
                    r.strokeBorder(Color.accentColor, lineWidth: 1)
                        .background(r.stroke(Color.accentColor.opacity(0.35), lineWidth: 3))
                } else if hovering {
                    r.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                }
            }
            .onHover { hovering = $0 }
            .help(L("Klick wählt Stunde oder Minute · Ziffern tippen · ⌥↑↓ ändern (Minuten in 5er-Schritten) · Pfeiltasten wechseln das Feld"))
    }
}

/// Label + comment in one field: "# label▸ghost comment".
struct TagField: View {
    /// `input`: no chrome of its own, framed by the input bar. `cell`: transparent row cell.
    enum Style { case input, cell }

    let style: Style
    @Binding var label: String
    @Binding var comment: String
    var labelPlaceholder = "label"
    var commentPlaceholder = L("Kommentar")
    var showsComment = true
    var commentDimmed = false
    var ghost = ""
    /// Empty label shown as plain grey text without "#" (a stop row: "pause", "feierabend").
    var plainWhenEmpty = false
    var labelFocus: FocusRequest?
    var commentFocus: FocusRequest?
    var onLabelFocus: (Bool) -> Void = { _ in }
    var onCommentFocus: (Bool) -> Void = { _ in }
    var onLabelCommand: (FieldCommand) -> Bool = { _ in false }
    var onCommentCommand: (FieldCommand) -> Bool = { _ in false }
    var onBackgroundTap: () -> Void = {}

    @State private var labelFocused = false
    @State private var commentFocused = false
    @State private var hovering = false

    private var focused: Bool { labelFocused || commentFocused }

    private var plain: Bool { plainWhenEmpty && label.isEmpty }

    private var labelWidth: CGFloat {
        // Width of a shortened label at most; the field itself cuts it in the middle.
        let shown = labelFocused ? label : Rules.mid(label, Rules.labelShow)
        let w = Look.width(shown.isEmpty ? labelPlaceholder : shown, plain ? Look.regular13 : Look.semibold13) + 4
        return min(max(w, 14), style == .input ? 190 : 170)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                // Keeps the caret of an empty field off the "#".
                .padding(.trailing, 2)
                // Hidden, but keeping its place: turning a stop into a task (and back) moves nothing.
                .opacity(plain ? 0 : 1)
            KeyTextField(
                text: $label, placeholder: labelPlaceholder, font: Look.semibold13,
                placeholderFont: plain ? Look.regular13 : nil,
                placeholderColor: plain ? .secondaryLabelColor : .tertiaryLabelColor,
                truncation: .byTruncatingMiddle, focus: labelFocus,
                onFocusChange: { labelFocused = $0; onLabelFocus($0) },
                onCommand: onLabelCommand)
                .frame(width: labelWidth, height: 20)
                // AppKit draws the field 2 pt beyond its SwiftUI frame (alignment insets): text scrolled
                // while typing would show up there, right against the "#".
                .clipShape(FieldClip())
            if !ghost.isEmpty {
                // Right at the end of the typed text (the field draws it 2 pt in), not at the end of
                // the field, which has a minimum width.
                Text(ghost)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .fixedSize()
                    .offset(x: 2 + Look.exactWidth(label, Look.semibold13) - labelWidth)
                    .allowsHitTesting(false)
            }
            if showsComment {
                KeyTextField(
                    text: $comment, placeholder: commentPlaceholder, font: Look.regular13,
                    textColor: .secondaryLabelColor,
                    placeholderColor: commentDimmed ? .quaternaryLabelColor : .tertiaryLabelColor,
                    focus: commentFocus,
                    onFocusChange: { commentFocused = $0; onCommentFocus($0) },
                    onCommand: onCommentCommand)
                    .frame(height: 20)
                    // As for the label: text scrolled at the end mustn't creep up to the label.
                    .clipShape(FieldClip())
                    .padding(.leading, 2)
                    .padding(.trailing, 4)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: style == .input ? 28 : 24)
        .background(background)
        .overlay(border)
        .contentShape(Rectangle())
        .onTapGesture(perform: onBackgroundTap)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var background: some View {
        let r = RoundedRectangle(cornerRadius: 5)
        switch style {
        case .input: Color.clear
        case .cell: r.fill(focused || hovering ? Color(nsColor: .controlBackgroundColor) : .clear)
        }
    }

    @ViewBuilder private var border: some View {
        let r = RoundedRectangle(cornerRadius: 5)
        if style == .input {
            EmptyView()
        } else if focused {
            r.strokeBorder(Color.accentColor, lineWidth: 1)
                .background(r.stroke(Color.accentColor.opacity(0.35), lineWidth: 3))
        } else if hovering {
            r.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        }
    }
}

/// The frame of a text field plus room for the caret (about 2 pt wide) at either end.
struct FieldClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -1.5, dy: -4))
    }
}

/// Floating list of suggestions ("Zuletzt verwendet" / "Passende Labels").
struct SuggestionList: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let meta: String
        var color: Color?
        var isNew = false
        /// SF Symbol instead of the color square (absences).
        var icon: String?
    }

    let heading: String
    let items: [Item]
    let selected: Int
    var onPick: (Int) -> Void
    var footer: (title: String, action: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(heading)
                Spacer()
                Text(L("↑↓ · Enter"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Button { onPick(i) } label: {
                    HStack(spacing: 8) {
                        if let icon = item.icon {
                            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(item.color ?? .secondary)
                                .frame(width: 8, height: 8)
                        } else {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(item.color ?? .clear)
                                .overlay(item.isNew ? RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [2]))
                                    .foregroundStyle(.tertiary) : nil)
                                .frame(width: 8, height: 8)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.meta).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(i == selected ? Color.accentColor.opacity(0.14) : .clear))
                }
                .buttonStyle(.plain)
            }
            if let footer {
                Divider().padding(.top, 2)
                Button(action: footer.action) {
                    Label(footer.title, systemImage: "tag")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

/// Where the active autocomplete field is, so the list can float above everything.
struct AnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
