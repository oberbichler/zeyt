import AppKit
import SwiftUI

// Building blocks of the popover (DayView): header, day bar, rows, buttons.

/// NSMenuItem with a closure.
final class MenuItem: NSObject {
    private let action: () -> Void
    private init(_ action: @escaping () -> Void) { self.action = action }
    @objc private func run() { action() }

    /// `symbol` shows only from macOS 26 on, where system menus carry symbols; before, menus have none.
    static func make(_ title: String, key: String = "", symbol: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let handler = MenuItem(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: key)
        if #available(macOS 26, *), let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        item.target = handler
        item.representedObject = handler
        return item
    }
}

struct IconButton: View {
    let systemImage: String
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(hovering ? .primary : .secondary)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Round icon button inside the input capsule (radius concentric with the capsule).
struct CircleButton: View {
    let systemImage: String
    let size: CGFloat
    let tint: Color
    let fill: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(fill))
                .overlay(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One day in the week strip: weekday, hours (or absence icon); today in accent, selection highlighted.
struct WeekDayCell: View {
    let day: DayView.WeekDay
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let cal = Calendar.current
        let today = cal.isDateInToday(day.date)
        let weekend = cal.isDateInWeekend(day.date)
        Button(action: action) {
            VStack(spacing: 4) {
                Text(verbatim: "\(DayNames.shortWeekday(day.date)) \(cal.component(.day, from: day.date))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(today ? Color.accentColor : .secondary)
                    // Long day names (Polish "niedz") shrink instead of wrapping.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Group {
                    if let a = day.absence, day.onlyAbsence {
                        Image(systemName: a.icon).font(.system(size: 13)).foregroundStyle(a.color)
                    } else if let a = day.absence {
                        // Part of the day absent: small icon before the hours.
                        HStack(spacing: 2) {
                            Image(systemName: a.icon).font(.system(size: 8)).foregroundStyle(a.color)
                            Text(Fmt.duration(day.worked))
                        }
                    } else if day.worked > 0 {
                        Text(Fmt.duration(day.worked))
                    } else {
                        Text("–").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 12, weight: selected ? .semibold : .regular).monospacedDigit())
                .frame(height: 15)
            }
            .opacity(weekend && day.worked == 0 && day.absence == nil && !selected ? 0.6 : 1)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(Fmt.longDay.string(from: day.date))\(day.absence.map { " · \($0.title)" } ?? "")")
    }
}

/// Caption over hours and BT, centered in its half of the header.
struct StatView: View {
    let caption: String
    let value: TimeInterval

    var body: some View {
        VStack(spacing: 2) {
            Text(caption.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (Text(Fmt.duration(value)).font(.system(size: 17, weight: .semibold))
                    + Text(verbatim: " h").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary))
                Text(Fmt.bt(value)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

struct GearButton: View {
    let unassigned: Int
    let action: () -> Void

    var body: some View {
        IconButton(systemImage: "gearshape",
                   help: unassigned == 0 ? L("Optionen")
                       : unassigned == 1 ? L("Optionen – 1 Label ohne Zuordnung")
                       : L("Optionen – %@ Labels ohne Zuordnung", "\(unassigned)"),
                   action: action)
            // Badge on the glyph's corner, without a ring: a panel-colored ring shows up on the hover circle.
            .overlay(alignment: .topTrailing) {
                if unassigned > 0 {
                    Circle().fill(Look.warning).frame(width: 6, height: 6)
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Label colour of a task; a stop (pause, feierabend) is an empty ring. Switching happens in the
/// label field ("#" makes a task, deleting the "#" a stop).
struct KindDot: View {
    let isTask: Bool
    let color: Color

    var body: some View {
        Group {
            if isTask {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
            }
        }
        .frame(width: 9, height: 9)
        .frame(width: RowMetrics.dotWidth, height: RowMetrics.height)
    }
}

/// Sizes of an entry row, shared by its parts.
enum RowMetrics {
    static let height: CGFloat = 28
    static let timeWidth: CGFloat = 56
    static let dotWidth: CGFloat = 18
    static let durationWidth: CGFloat = 40
}

/// 28 pt row with hover background and a hover bar for actions.
struct HoverRow<Content: View, Actions: View>: View {
    let conflict: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        content()
            .frame(height: RowMetrics.height)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(
                conflict ? Look.warning.opacity(0.13) : hovering ? Color.primary.opacity(0.05) : .clear))
            .overlay(alignment: .trailing) {
                if hovering {
                    HStack(spacing: 2) { actions() }
                        .padding(.leading, 20)
                        .background(LinearGradient(
                            colors: [Look.panel.opacity(0), Look.panel],
                            startPoint: .leading, endPoint: UnitPoint(x: 0.35, y: 0.5)))
                        .padding(.trailing, 48)
                }
            }
            .onHover { hovering = $0 }
    }
}

struct RowAction: View {
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .foregroundStyle(tint)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? tint.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The day as one bar of its tasks and breaks on a linear time axis, with start and end below.
/// Hovering shows what a click does: near the start of an entry it goes to that row, in between it
/// creates an entry at that time (to 10 minutes).
struct DayBar: View {
    let timeline: Timeline
    let blocks: [Block]
    let entries: [Entry]
    /// When the user was at the Mac that day: a thin line under the bar.
    var presence: [DateInterval] = []
    /// The user is at the Mac right now (today): a bar that ends with the presence ends "now".
    var presentNow = false
    /// Colour of a label.
    let color: (String) -> Color
    var onClick: (Timeline.Target) -> Void = { _ in }

    @State private var hover: Double?
    @State private var labelWidth: CGFloat = 0

    private static let barHeight: CGFloat = 6
    /// Extra room above and below that still counts as the bar for the mouse.
    private static let slop: CGFloat = 4
    /// This close (points) to the start of an entry, a click goes to it.
    private static let snapDistance: CGFloat = 6
    @State private var width: CGFloat = 1

    private func target(_ f: Double) -> Timeline.Target {
        timeline.target(at: f, tolerance: Double(Self.snapDistance / max(1, width)), in: entries)
    }

    private func targetDate(_ t: Timeline.Target) -> Date {
        switch t {
        case .entry(let e): e.date
        case .new(let d): d
        }
    }

    var body: some View {
        let tl = timeline
        let segments = blocks.filter { $0.duration > 0 && $0.kind != .end }
        let height = Self.barHeight + (presence.isEmpty ? 0 : 6)
        return VStack(spacing: 0) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.08))
                        ForEach(segments) { b in
                            let x0 = tl.fraction(b.entry.date) * w
                            let x1 = tl.fraction(b.end ?? b.entry.date) * w
                            Group {
                                if b.kind == .pause { Hatch() } else { Rectangle().fill(color(b.entry.label)) }
                            }
                            // 1 pt gap between neighbours, but never thinner than 1 pt.
                            .frame(width: max(1, x1 - x0 - (x1 < w - 0.5 ? 1 : 0)))
                            .offset(x: x0)
                        }
                    }
                    .frame(width: w, height: Self.barHeight)
                    .clipShape(Capsule())
                    if !presence.isEmpty {
                        PresenceLine(spans: presence, from: tl.start, to: tl.end)
                            .offset(y: Self.barHeight + 4)
                    }
                    if let hover {
                        Capsule().fill(Color.primary)
                            .frame(width: 2, height: Self.barHeight + 4)
                            .offset(x: min(max(0, tl.fraction(targetDate(target(hover))) * w - 1), w - 2), y: -2)
                    }
                }
                .padding(.vertical, Self.slop)
                .frame(width: w, height: height + 2 * Self.slop, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    width = w
                    switch phase {
                    case .active(let p): hover = w > 0 ? min(1, max(0, p.x / w)) : nil
                    case .ended: hover = nil
                    }
                }
                .onTapGesture { p in
                    guard w > 0 else { return }
                    width = w
                    onClick(target(min(1, max(0, p.x / w))))
                }
            }
            .frame(height: height + 2 * Self.slop)
            .padding(.vertical, -Self.slop)
            .padding(.bottom, 4)
            GeometryReader { geo in
                if let hover {
                    let x = tl.fraction(targetDate(target(hover))) * geo.size.width
                    Text(hoverText(hover))
                        .fixedSize()
                        .background(GeometryReader { g in Color.clear.preference(key: WidthKey.self, value: g.size.width) })
                        .offset(x: min(max(0, x - labelWidth / 2), max(0, geo.size.width - labelWidth)))
                        .foregroundStyle(.primary)
                } else {
                    HStack {
                        Text(Fmt.time.string(from: tl.start))
                        Spacer()
                        Text(endText)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 14)
            .font(.system(size: 11).monospacedDigit())
            .onPreferenceChange(WidthKey.self) { labelWidth = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var endText: String {
        // The presence reaches further than the entries.
        if tl.entriesEnd.map({ tl.end.timeIntervalSince($0) >= 60 }) ?? true {
            return presentNow ? L("jetzt") : Fmt.time.string(from: tl.end)
        }
        guard let last = blocks.last else { return Fmt.time.string(from: tl.end) }
        return last.kind == .end ? Fmt.time.string(from: last.entry.date) : (last.running ? L("jetzt") : L("offen"))
    }

    private var tl: Timeline { timeline }

    private func hoverText(_ f: Double) -> String {
        switch target(f) {
        case .entry(let e):
            let what = e.isStop ? (blocks.last?.id == e.id ? L("Feierabend") : L("Pause"))
                : e.label.isEmpty ? L("unverplant") : "#" + e.label
            return "\(Fmt.time.string(from: e.date)) · \(what)"
        case .new(let d):
            return L("%@ · neuer Eintrag", Fmt.time.string(from: d))
        }
    }

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

/// Presence under the day bar, on the same time scale: where the user was at the Mac.
struct PresenceLine: View {
    let spans: [DateInterval]
    let from: Date
    let to: Date

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / max(1, to.timeIntervalSince(from))
            ForEach(Array(spans.enumerated()), id: \.offset) { _, s in
                let a = max(s.start, from), b = min(s.end, to)
                if a < b {
                    Capsule().fill(Color.primary.opacity(0.28))
                        .frame(width: max(2, b.timeIntervalSince(a) * scale), height: 2)
                        .offset(x: a.timeIntervalSince(from) * scale)
                        .help(L("Am Mac: %1$@–%2$@", Fmt.time.string(from: s.start), Fmt.time.string(from: s.end)))
                }
            }
        }
        .frame(height: 2)
        .help(L("Wann du am Mac warst"))
    }
}

/// Hatched fill for breaks in the day bar.
struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.12)))
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(p, with: .color(.primary.opacity(0.22)), lineWidth: 1.5)
                x += 4
            }
        }
    }
}

/// Day names in the app's language.
enum DayNames {
    private static let symbols: [String] = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        // Compact: "Mo" rather than "Mo.".
        return (f.shortWeekdaySymbols ?? []).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    }()

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate("dM")
        return f
    }()

    /// Short weekday, e.g. "Mo".
    static func shortWeekday(_ d: Date) -> String {
        let i = Calendar.current.component(.weekday, from: d) - 1
        return symbols.indices.contains(i) ? symbols[i] : ""
    }

    /// Weekday and date, e.g. "Mo 19.10.".
    static func short(_ d: Date) -> String {
        "\(shortWeekday(d)) \(dayMonth.string(from: d))"
    }
}
