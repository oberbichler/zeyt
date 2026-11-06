import SwiftUI

/// Month calendar: hours per day, per calendar week and for the month. A click on a day shows it in the popover.
struct CalendarView: View {
    @ObservedObject var store: EntryStore
    @ObservedObject var state: AppState
    private var month: Date {
        get { state.calendarMonth }
        nonmutating set { state.calendarMonth = newValue }
    }

    static let weekWidth: CGFloat = 76

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let weeks = MonthGrid.weeks(of: month)
            let uncounted: Set<String> = state.uncountedEnabled ? Set(store.uncounted) : []
            let byDay = store.entriesByDay(from: weeks.first!.first!, to: weeks.last!.last!)
            let summaries = weeks.map { $0.map { DaySummary.make($0, entries: byDay[$0] ?? [], now: now, uncounted: uncounted) } }
            let inMonth = summaries.joined().filter { MonthGrid.contains(month, $0.date) }
            VStack(spacing: 0) {
                header(total: inMonth.reduce(0) { $0 + $1.worked }, now: now)
                Divider()
                VStack(spacing: 6) {
                    weekdayHeader(weeks[0])
                    ForEach(summaries, id: \.first!.date) { week in weekRow(week) }
                }
                .padding(12)
                .frame(maxHeight: .infinity)
                Divider()
                footer(inMonth)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .background(shortcuts)
    }

    // MARK: Header

    private func header(total: TimeInterval, now: Date) -> some View {
        HStack(spacing: 6) {
            IconButton(systemImage: "chevron.left", help: L("Vormonat (←)")) { shift(-1) }
            Text(Fmt.monthTitle.string(from: month))
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 140)
            IconButton(systemImage: "chevron.right", help: L("Folgemonat (→)")) { shift(1) }
            if !MonthGrid.contains(month, now) {
                Button { month = MonthGrid.start(of: Date()) } label: {
                    Text(L("Heute"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L("Zum aktuellen Monat springen"))
            }
            Spacer()
            (Text(Fmt.duration(total)).font(.system(size: 17, weight: .semibold))
                + Text(verbatim: " h").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary))
                .monospacedDigit()
            Text(Fmt.bt(total))
                .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Grid

    private func weekdayHeader(_ week: [Date]) -> some View {
        HStack(spacing: 6) {
            Text(L("KW")).frame(width: Self.weekWidth)
            ForEach(week, id: \.self) { d in
                Text(DayNames.shortWeekday(d)).frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func weekRow(_ week: [DaySummary]) -> some View {
        let total = week.reduce(0) { $0 + $1.worked }
        return HStack(spacing: 6) {
            VStack(spacing: 3) {
                Text(L("KW %@", "\(Rules.isoWeek(week[0].date))"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(total > 0 ? Fmt.duration(total) : "–")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(total > 0 ? .primary : .tertiary)
                if total > 0 {
                    Text(Fmt.bt(total)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.weekWidth)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.08)))
            ForEach(week) { d in
                CalendarDayCell(day: d, inMonth: MonthGrid.contains(month, d.date)) { state.showDay(d.date) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Footer

    private func footer(_ days: [DaySummary]) -> some View {
        let workdays = days.filter(\.isWorkday)
        let worked = workdays.reduce(0) { $0 + $1.worked }
        var absences: [Absence: Int] = [:]
        for d in days { if let a = d.absence { absences[a, default: 0] += 1 } }
        let parts = Absence.allCases.compactMap { a in absences[a].map { L("%1$@× %2$@", "\($0)", a.title) } }
        return HStack(spacing: 14) {
            Text(workdays.count == 1 ? L("1 Arbeitstag") : L("%@ Arbeitstage", "\(workdays.count)"))
            if !workdays.isEmpty {
                Text(L("Ø %@ h pro Arbeitstag", Fmt.duration(worked / Double(workdays.count))))
            }
            if !parts.isEmpty { Text(parts.joined(separator: " · ")) }
            Spacer()
            Text(L("Tag anklicken, um ihn zu öffnen")).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func shift(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month)!
    }

    private var shortcuts: some View {
        Group {
            Button("") { shift(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { shift(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { shift(-1) }.keyboardShortcut("[")
            Button("") { shift(1) }.keyboardShortcut("]")
            Button("") { month = MonthGrid.start(of: Date()) }.keyboardShortcut("t")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

/// One day of the calendar: day number, hours with a bar against 8 h, absence icon.
struct CalendarDayCell: View {
    let day: DaySummary
    let inMonth: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let cal = Calendar.current
        let today = cal.isDateInToday(day.date)
        let weekend = cal.isDateInWeekend(day.date)
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
                bar
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.1 : weekend ? 0.025 : 0.055)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(today ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
            .opacity(inMonth ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(Fmt.longDay.string(from: day.date))\(day.absence.map { " · \($0.title)" } ?? "")")
    }

    /// Hours against a full day (8 h), capped there.
    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if day.worked > 0 {
                    Capsule().fill(Color.accentColor.opacity(0.7))
                        .frame(width: max(3, geo.size.width * min(1, day.worked / (8 * 3600))))
                }
            }
        }
        .frame(height: 3)
        .opacity(day.worked > 0 ? 1 : 0)
    }
}
