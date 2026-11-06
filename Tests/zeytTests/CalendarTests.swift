import Foundation
import Testing
@testable import zeyt

@Suite struct CalendarTests {
    static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s.count == 10 ? s + " 00:00" : s)!
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    @Test func weeksStartOnMondayAndCoverTheMonth() {
        // November 2026: Sunday the 1st, Monday the 30th.
        let weeks = MonthGrid.weeks(of: Self.date("2026-11-17"))
        #expect(weeks.count == 6)
        #expect(weeks.allSatisfy { $0.count == 7 })
        #expect(Self.day(weeks[0][0]) == "2026-10-26")
        #expect(Self.day(weeks[0][6]) == "2026-11-01")
        #expect(Self.day(weeks[5][0]) == "2026-11-30")
        #expect(Rules.isoWeek(weeks[0][0]) == 44)
        #expect(Rules.isoWeek(weeks[5][0]) == 49)
    }

    @Test func monthStartingOnMondayHasNoLeadingDays() {
        // February 2027 starts on a Monday and has exactly four weeks.
        let weeks = MonthGrid.weeks(of: Self.date("2027-02-10"))
        #expect(weeks.count == 4)
        #expect(Self.day(weeks[0][0]) == "2027-02-01")
        #expect(Self.day(weeks[3][6]) == "2027-02-28")
        #expect(MonthGrid.contains(Self.date("2027-02-01"), weeks[3][6]))
        #expect(!MonthGrid.contains(Self.date("2027-02-01"), Self.date("2027-03-01")))
    }

    @Test func yearBoundaryHasWeek53() {
        // 2026 has 53 ISO weeks: 28 Dec 2026 to 3 Jan 2027 is week 53, shown in January 2027.
        let weeks = MonthGrid.weeks(of: Self.date("2027-01-15"))
        #expect(Self.day(weeks[0][0]) == "2026-12-28")
        #expect(Rules.isoWeek(weeks[0][0]) == 53)
        #expect(Rules.isoWeek(weeks[1][0]) == 1)
    }

    @Test func daysStayAtMidnightAcrossDaylightSaving() {
        // Clocks change on 29 March and 25 October 2026 (Europe).
        for month in ["2026-03-10", "2026-10-10"] {
            let days = MonthGrid.weeks(of: Self.date(month)).joined()
            #expect(days.allSatisfy { Calendar.current.startOfDay(for: $0) == $0 })
            #expect(Set(days.map(Self.day)).count == days.count)
        }
    }

    @Test func daySummaryCountsWorkAndAbsence() {
        let now = Self.date("2026-11-20 12:00")
        let work = [Entry(date: Self.date("2026-11-02 08:00"), text: "#api"),
                    Entry(date: Self.date("2026-11-02 12:00"), text: "pause"),
                    Entry(date: Self.date("2026-11-02 12:30"), text: "#api"),
                    Entry(date: Self.date("2026-11-02 16:30"), text: "feierabend")]
        let s = DaySummary.make(Self.date("2026-11-02"), entries: work, now: now)
        #expect(s.worked == 8 * 3600)
        #expect(s.isWorkday)
        #expect(s.absence == nil)

        let sick = [Entry(date: Self.date("2026-11-03 08:00"), text: "#krank"),
                    Entry(date: Self.date("2026-11-03 16:00"), text: "feierabend")]
        let a = DaySummary.make(Self.date("2026-11-03"), entries: sick, now: now, uncounted: ["krank"])
        #expect(a.worked == 0)
        #expect(a.absence == .sick)
        #expect(a.onlyAbsence)
        #expect(!a.isWorkday)
    }
}

@Suite struct PeriodStatsTests {
    let d = CalendarTests.date

    func byDay(_ entries: [Entry]) -> [Date: [Entry]] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
    }

    @Test func weekFigures() {
        let entries = [
            Entry(date: d("2026-10-12 08:00"), text: "#api"), Entry(date: d("2026-10-12 12:00"), text: "pause"),
            Entry(date: d("2026-10-12 12:30"), text: "#web"), Entry(date: d("2026-10-12 16:30"), text: "feierabend"),
            Entry(date: d("2026-10-13 09:00"), text: "#api"), Entry(date: d("2026-10-13 15:00"), text: "feierabend"),
            Entry(date: d("2026-10-14 09:00"), text: "#urlaub"), Entry(date: d("2026-10-14 17:00"), text: "feierabend"),
        ]
        let s = PeriodStats.make(days: MonthGrid.week(of: d("2026-10-14")), entries: byDay(entries),
                                 now: d("2026-11-01 12:00"), uncounted: ["urlaub"])
        let worked: TimeInterval = 14 * 3600
        #expect(s.worked == worked)
        #expect(s.workdays == 2)
        #expect(s.perWorkday == worked / 2)
        #expect(s.paused == TimeInterval(30 * 60))
        let start: TimeInterval = 8.5 * 3600, end: TimeInterval = 15.75 * 3600
        #expect(s.start == start)      // 8:00 and 9:00
        #expect(s.end == end)          // 16:30 and 15:00
        let labels: [PeriodStats.LabelTime] = [.init(label: "api", seconds: 36000), .init(label: "web", seconds: 14400)]
        #expect(s.labels == labels)
        let sum = s.labels.map(\.seconds).reduce(0, +)
        #expect(sum == s.worked)
        #expect(s.absences == [.vacation: 1])
    }

    @Test func countedAbsenceIsALabelButNoWorkday() {
        let entries = [Entry(date: d("2026-10-14 09:00"), text: "#urlaub"), Entry(date: d("2026-10-14 17:00"), text: "feierabend")]
        let s = PeriodStats.make(days: [d("2026-10-14")], entries: byDay(entries), now: d("2026-11-01 12:00"))
        #expect(s.worked == 8 * 3600)
        #expect(s.workdays == 0)
        #expect(s.labels.map(\.label) == ["urlaub"])
        #expect(s.start == nil)
    }

    @Test func runningDayEndsNow() {
        let entries = [Entry(date: d("2026-11-06 08:00"), text: "#api")]
        let now = d("2026-11-06 11:30")
        // The last task of the day `now` runs until now.
        let s = PeriodStats.make(days: [d("2026-11-06")], entries: byDay(entries), now: now)
        let end: TimeInterval = 11.5 * 3600
        #expect(s.end == end)
        #expect(s.workdays == 1)
    }

    @Test func timePerLabelOnADay() {
        let entries = [Entry(date: d("2026-10-12 08:00"), text: "#api"), Entry(date: d("2026-10-12 10:00"), text: "#web"),
                       Entry(date: d("2026-10-12 11:00"), text: "pause"), Entry(date: d("2026-10-12 11:30"), text: "#api x"),
                       Entry(date: d("2026-10-12 12:00"), text: "feierabend")]
        let s = DaySummary.make(d("2026-10-12"), entries: entries, now: d("2026-11-01 12:00"))
        let api: TimeInterval = 2.5 * 3600, both: TimeInterval = 3.5 * 3600
        #expect(s.time(on: ["api"]) == api)
        #expect(s.time(on: ["api", "web"]) == both)
        #expect(s.time(on: ["other"]) == 0)
        #expect(s.labels["pause"] == nil)
    }

    @Test func weekAndMonthDays() {
        let week = MonthGrid.week(of: d("2026-11-01"))
        #expect(CalendarTests.day(week[0]) == "2026-10-26")
        #expect(week.count == 7)
        #expect(MonthGrid.days(of: d("2026-02-10")).count == 28)
        #expect(MonthGrid.days(of: d("2026-10-10")).count == 31)
    }
}
