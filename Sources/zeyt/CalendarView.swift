import SwiftUI

/// Calendar window: a month in calendar weeks with hours per day and week, the month's figures on the right.
/// Pointing at a label or account there highlights the days with time on it (a click keeps it);
/// a click on a day shows it in the popover.
struct CalendarView: View {
    @ObservedObject var store: EntryStore
    @ObservedObject var state: AppState
    /// Under the pointer in the sidebar …
    @State private var hovered: Highlight?
    /// … or kept by a click.
    @State private var pinned: Highlight?

    static let weekWidth: CGFloat = 76
    static let sidebarWidth: CGFloat = 290

    private var date: Date { state.calendarDate }
    private var highlight: Highlight? { hovered ?? pinned }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let uncounted: Set<String> = state.uncountedEnabled ? Set(store.uncounted) : []
            let weeks = MonthGrid.weeks(of: date)
            let byDay = store.entriesByDay(from: weeks.first!.first!, to: weeks.last!.last!)
            let colors = Look.labelColors(store.labelStats)
            let summaries = weeks.map { $0.map { DaySummary.make($0, entries: byDay[$0] ?? [], now: now, uncounted: uncounted) } }
            let stats = PeriodStats.make(days: MonthGrid.days(of: date), entries: byDay, now: now, uncounted: uncounted)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(now)
                    Divider()
                    grid(summaries)
                }
                .frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    StatsSection(title: Fmt.monthTitle.string(from: date), stats: stats, store: store, colors: colors,
                                 active: highlight, pinned: pinned,
                                 hover: { h, inside in
                                     // Leaving one row must not clear the next one already entered.
                                     guard inside || hovered?.id == h.id else { return }
                                     withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? h : nil }
                                 },
                                 pin: { h in withAnimation(.easeOut(duration: 0.12)) { pinned = pinned == h ? nil : h } })
                        .padding(16)
                }
                .frame(width: Self.sidebarWidth)
                .background(Color.primary.opacity(0.025))
            }
        }
        .frame(minWidth: 940, minHeight: 540)
        .background(shortcuts)
    }

    // MARK: Header

    private func header(_ now: Date) -> some View {
        HStack(spacing: 6) {
            IconButton(systemImage: "chevron.left", help: L("Vormonat (←)")) { shift(-1) }
            IconButton(systemImage: "chevron.right", help: L("Folgemonat (→)")) { shift(1) }
            Text(Fmt.monthTitle.string(from: date))
                .font(.system(size: 15, weight: .semibold))
                .padding(.leading, 4)
            if !MonthGrid.contains(date, now) {
                Button { goToday() } label: {
                    Text(L("Heute"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L("Zu heute springen (⌘T)"))
                .padding(.leading, 6)
            }
            Spacer()
            if let h = highlight {
                // What is highlighted, with a way out when it was kept by a click.
                HStack(spacing: 6) {
                    Circle().fill(h.color).frame(width: 8, height: 8)
                    Text(h.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if pinned != nil, hovered == nil {
                        Button { withAnimation(.easeOut(duration: 0.12)) { pinned = nil } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Hervorhebung aufheben (Esc)"))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(h.color.opacity(0.15)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    // MARK: Grid

    private func grid(_ weeks: [[DaySummary]]) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(L("KW")).frame(width: Self.weekWidth)
                ForEach(weeks[0]) { d in Text(DayNames.shortWeekday(d.date)).frame(maxWidth: .infinity) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            ForEach(weeks, id: \.first!.date) { week in
                HStack(spacing: 6) {
                    WeekCell(week: week, highlight: highlight)
                    ForEach(week) { d in
                        CalendarDayCell(day: d, inMonth: MonthGrid.contains(date, d.date), highlight: highlight) {
                            state.showDay(d.date)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
    }

    // MARK: Navigation

    private func shift(_ n: Int) {
        // From the first of the month, so a short month doesn't skip one.
        state.calendarDate = Calendar.current.date(byAdding: .month, value: n, to: MonthGrid.start(of: date))!
    }

    private func goToday() {
        state.calendarDate = Calendar.current.startOfDay(for: Date())
    }

    private var shortcuts: some View {
        Group {
            Button("") { shift(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { shift(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { shift(-1) }.keyboardShortcut("[")
            Button("") { shift(1) }.keyboardShortcut("]")
            Button("") { goToday() }.keyboardShortcut("t")
            Button("") { withAnimation(.easeOut(duration: 0.12)) { pinned = nil } }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

/// Labels whose days the grid highlights: one label, the labels of an account, or the smallest labels.
struct Highlight: Equatable {
    let id: String
    let name: String
    let labels: Set<String>
    let color: Color
}

// MARK: - Grid

/// Calendar week: number and hours, or the hours on the highlighted labels.
struct WeekCell: View {
    let week: [DaySummary]
    let highlight: Highlight?

    var body: some View {
        let total = highlight.map { h in week.reduce(0) { $0 + $1.time(on: h.labels) } } ?? week.reduce(0) { $0 + $1.worked }
        let tint = highlight?.color ?? .accentColor
        VStack(spacing: 3) {
            Text(L("KW %@", "\(Rules.isoWeek(week[0].date))"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(total > 0 ? Fmt.duration(total) : "–")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(total > 0 ? AnyShapeStyle(highlight == nil ? Color.primary : tint) : AnyShapeStyle(.tertiary))
            if total > 0 {
                Text(Fmt.bt(total)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(width: CalendarView.weekWidth)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(highlight == nil ? 0.08 : 0.14)))
    }
}

/// One day of the month: day number, hours with a bar against 8 h, absence icon. While labels are
/// highlighted: their time that day in their color, other days faded.
struct CalendarDayCell: View {
    let day: DaySummary
    let inMonth: Bool
    let highlight: Highlight?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let cal = Calendar.current
        let today = cal.isDateInToday(day.date)
        let weekend = cal.isDateInWeekend(day.date)
        let part = highlight.map { day.time(on: $0.labels) } ?? 0
        let lit = highlight != nil && part > 0
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(verbatim: "\(cal.component(.day, from: day.date))")
                        .font(.system(size: 12, weight: today ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(today ? Color.white : .secondary)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(today ? Color.accentColor : .clear))
                    Spacer(minLength: 0)
                    if let a = day.absence {
                        Image(systemName: a.icon).font(.system(size: 11)).foregroundStyle(a.color)
                    }
                }
                Spacer(minLength: 0)
                if let h = highlight, lit {
                    Text(Fmt.duration(part))
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(h.color)
                    Text(L("von %@", Fmt.duration(day.worked)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .opacity(day.worked > part ? 1 : 0)
                    HoursBar(worked: part, color: h.color)
                } else {
                    if let a = day.absence, day.onlyAbsence {
                        Text(a.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(a.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    // Also an absence day, when it counts (setting off, or the label counts).
                    if day.worked > 0 {
                        Text(Fmt.duration(day.worked))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    }
                    HoursBar(worked: day.worked, color: .accentColor)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(lit ? highlight!.color.opacity(0.16)
                          : Color.primary.opacity(hovering ? 0.1 : weekend ? 0.025 : 0.055)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(lit ? highlight!.color.opacity(0.8) : today ? Color.accentColor.opacity(0.6) : .clear,
                                  lineWidth: lit ? 1.5 : 1))
            .opacity(highlight != nil && !lit ? 0.35 : inMonth ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(Fmt.longDay.string(from: day.date))\(day.absence.map { " · \($0.title)" } ?? "")")
    }
}

/// Hours against a full day (8 h), capped there.
struct HoursBar: View {
    let worked: TimeInterval
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if worked > 0 {
                    Capsule().fill(color.opacity(0.75))
                        .frame(width: max(3, geo.size.width * min(1, worked / (8 * 3600))))
                }
            }
        }
        .frame(height: 3)
        .opacity(worked > 0 ? 1 : 0)
    }
}

// MARK: - Figures

/// Figures of the month: total, tiles, hours per label and account (pointing highlights their days), absences.
struct StatsSection: View {
    let title: String
    let stats: PeriodStats
    let store: EntryStore
    let colors: [String: Color]
    let active: Highlight?
    let pinned: Highlight?
    let hover: (Highlight, Bool) -> Void
    let pin: (Highlight) -> Void

    static let maxLabels = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    (Text(Fmt.duration(stats.worked)).font(.system(size: 26, weight: .semibold))
                        + Text(verbatim: " h").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary))
                    Text(Fmt.bt(stats.worked)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                Tile(caption: L("Arbeitstage"), value: "\(stats.workdays)")
                Tile(caption: L("Ø pro Arbeitstag"), value: stats.workdays > 0 ? Fmt.duration(stats.perWorkday) : "–")
                Tile(caption: L("Ø Beginn"), value: stats.start.map(Fmt.clock) ?? "–")
                Tile(caption: L("Ø Ende"), value: stats.end.map(Fmt.clock) ?? "–")
                Tile(caption: L("Pausen"), value: stats.paused > 0 ? Fmt.duration(stats.paused) : "–")
                Tile(caption: L("Ø Pause"), value: stats.workdays > 0 && stats.paused > 0
                     ? Fmt.duration(stats.paused / Double(stats.workdays)) : "–")
            }
            if !stats.labels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle(L("Labels"))
                    ForEach(labelRows, id: \.id) { row($0) }
                }
            }
            let accounts = accountRows
            if accounts.count > 1 || accounts.first?.id != "account:" {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle(L("Accounts"))
                    ForEach(accounts, id: \.id) { row($0) }
                }
            }
            if !stats.absences.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    SectionTitle(L("Abwesenheiten"))
                    ForEach(Absence.allCases.filter { stats.absences[$0] != nil }) { a in
                        HStack(spacing: 8) {
                            Image(systemName: a.icon).foregroundStyle(a.color).frame(width: 16)
                            Text(a.title)
                            Spacer()
                            Text(stats.absences[a] == 1 ? L("1 Tag") : L("%@ Tage", "\(stats.absences[a]!)"))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }

    struct Row {
        let highlight: Highlight
        let seconds: TimeInterval
        let dot: Bool
        var id: String { highlight.id }
    }

    private func row(_ r: Row) -> some View {
        ShareRow(row: r, total: stats.worked, active: active?.id == r.id, kept: pinned?.id == r.id,
                 dimmed: active != nil && active?.id != r.id, hover: hover, pin: pin)
    }

    private func labelName(_ label: String) -> String { label.isEmpty ? L("unverplant") : "#" + label }

    /// The biggest labels, the rest summed up as "n more".
    private var labelRows: [Row] {
        func make(_ l: PeriodStats.LabelTime) -> Row {
            Row(highlight: Highlight(id: "label:" + l.label, name: labelName(l.label), labels: [l.label],
                                     color: Look.labelColor(l.label, colors)), seconds: l.seconds, dot: true)
        }
        guard stats.labels.count > Self.maxLabels else { return stats.labels.map(make) }
        let rest = stats.labels.dropFirst(Self.maxLabels - 1)
        let others = Row(highlight: Highlight(id: "others", name: L("%@ weitere", "\(rest.count)"),
                                              labels: Set(rest.map(\.label)), color: Color(nsColor: .systemGray)),
                         seconds: rest.reduce(0) { $0 + $1.seconds }, dot: true)
        return stats.labels.prefix(Self.maxLabels - 1).map(make) + [others]
    }

    private var accountRows: [Row] {
        var seconds: [String: TimeInterval] = [:], labels: [String: Set<String>] = [:]
        for l in stats.labels {
            let a = store.labelInfo[l.label]?.account ?? ""
            seconds[a, default: 0] += l.seconds
            labels[a, default: []].insert(l.label)
        }
        return seconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { a, s in
            Row(highlight: Highlight(id: "account:" + a, name: a.isEmpty ? L("Ohne Account") : a, labels: labels[a]!,
                                     color: .accentColor), seconds: s, dot: false)
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

struct Tile: View {
    let caption: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Name, hours and share of the total with a bar. Pointing at it highlights its days, a click keeps that.
struct ShareRow: View {
    let row: StatsSection.Row
    let total: TimeInterval
    let active: Bool
    let kept: Bool
    let dimmed: Bool
    let hover: (Highlight, Bool) -> Void
    let pin: (Highlight) -> Void

    var body: some View {
        let share = total > 0 ? row.seconds / total : 0
        let color = row.highlight.color
        Button { pin(row.highlight) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if row.dot { Circle().fill(color).frame(width: 8, height: 8) }
                    Text(row.highlight.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if kept { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    Text(Fmt.duration(row.seconds)).font(.system(size: 12).monospacedDigit())
                    Text(verbatim: "\(Int((share * 100).rounded())) %")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule().fill(color.opacity(0.75)).frame(width: max(2, geo.size.width * min(1, share)))
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(active ? 0.14 : 0)))
            .opacity(dimmed ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hover(row.highlight, $0) }
        .help(L("Tage hervorheben – Klick hält fest"))
    }
}
