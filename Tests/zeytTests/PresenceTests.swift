import Foundation
import Testing
@testable import zeyt

@Suite struct PresenceTests {
    let d = CalendarTests.date

    /// Samples every 20 s from `from` to `to`, always with fresh input.
    func present(_ spans: inout [DateInterval], _ from: String, _ to: String) {
        var t = d(from)
        while t <= d(to) {
            Presence.record(&spans, lastInput: t)
            t.addTimeInterval(20)
        }
    }

    @Test func samplesJoinIntoSpansAndShortAbsencesDontSplit() {
        var spans: [DateInterval] = []
        present(&spans, "2026-11-09 08:10", "2026-11-09 10:00")
        present(&spans, "2026-11-09 10:02", "2026-11-09 12:04")   // 2 min away: same span
        present(&spans, "2026-11-09 12:41", "2026-11-09 13:00")   // lunch: new span
        #expect(spans.count == 2)
        #expect(spans[0].start == d("2026-11-09 08:10"))
        #expect(spans[0].end == d("2026-11-09 12:04"))
        #expect(spans[1].start == d("2026-11-09 12:41"))
        let gaps = Presence.gaps(spans, after: d("2026-11-09 08:00"), minimum: 15 * 60)
        #expect(gaps == [DateInterval(start: d("2026-11-09 12:04"), end: d("2026-11-09 12:41"))])
    }

    @Test func spansFollowTheLastInput() {
        var spans: [DateInterval] = []
        // Samples while idle repeat the same last input: the span ends there.
        for _ in 0..<3 { Presence.record(&spans, lastInput: d("2026-11-09 08:14")) }
        Presence.record(&spans, lastInput: d("2026-11-09 08:16"))
        #expect(spans == [DateInterval(start: d("2026-11-09 08:14"), end: d("2026-11-09 08:16"))])
        #expect(Presence.isPresent(spans, now: d("2026-11-09 08:18")))
        #expect(!Presence.isPresent(spans, now: d("2026-11-09 08:20")))
        // A longer setting keeps the user present and joins longer absences.
        #expect(Presence.isPresent(spans, now: d("2026-11-09 08:20"), awayAfter: 5 * 60))
        Presence.record(&spans, lastInput: d("2026-11-09 08:20"), awayAfter: 5 * 60)
        #expect(spans.count == 1)
    }

    @Test func olderInputNeverShrinksOrReordersSpans() {
        var spans: [DateInterval] = []
        Presence.record(&spans, lastInput: d("2026-11-09 08:00"))
        Presence.record(&spans, lastInput: d("2026-11-09 08:02"))
        // An input time before the span (clock set back) changes nothing.
        Presence.record(&spans, lastInput: d("2026-11-09 07:30"))
        Presence.record(&spans, lastInput: d("2026-11-09 08:01"))
        #expect(spans == [DateInterval(start: d("2026-11-09 08:00"), end: d("2026-11-09 08:02"))])
        #expect(Presence.gaps(spans, after: d("2026-11-09 00:00"), minimum: 60).isEmpty)
    }

    @Test func spansOnTheDaylightSavingDay() {
        // 2026-10-25 has 25 hours in Central Europe; the span is cut at the next midnight, not 24 h later.
        let spans = [DateInterval(start: d("2026-10-25 22:00"), end: d("2026-10-26 01:00"))]
        let day = Presence.spans(spans, on: d("2026-10-25"))
        #expect(day == [DateInterval(start: d("2026-10-25 22:00"), end: d("2026-10-26 00:00"))])
    }

    @Test func rounding() {
        #expect(Presence.round(d("2026-11-09 12:04")) == d("2026-11-09 12:05"))
        #expect(Presence.round(d("2026-11-09 12:04"), minutes: 1) == d("2026-11-09 12:04"))
        #expect(Presence.round(d("2026-11-09 12:04"), minutes: 15) == d("2026-11-09 12:00"))
    }

    @Test func proposalsCanBeSwitchedOff() {
        var spans: [DateInterval] = []
        present(&spans, "2026-11-09 08:00", "2026-11-09 12:04")
        present(&spans, "2026-11-09 12:41", "2026-11-09 12:45")
        let task = Entry(date: d("2026-11-09 08:00"), text: "#api")
        var s = settings
        s.breaks = false
        #expect(Proposal.derive(entries: [task], spans: spans, now: d("2026-11-09 12:45"), settings: s) == nil)
        s = settings
        s.start = false
        #expect(Proposal.derive(entries: [], spans: spans, now: d("2026-11-09 12:45"), settings: s) == nil)
        s = settings
        s.roundMinutes = 1
        #expect(Proposal.derive(entries: [task], spans: spans, now: d("2026-11-09 12:45"), settings: s)
            == .pause(from: d("2026-11-09 12:04"), to: d("2026-11-09 12:41"), resume: task))
    }

    @Test func spansAreCutToTheDay() {
        let spans = [DateInterval(start: d("2026-11-08 23:00"), end: d("2026-11-09 01:00"))]
        #expect(Presence.spans(spans, on: d("2026-11-09")) == [DateInterval(start: d("2026-11-09 00:00"), end: d("2026-11-09 01:00"))])
    }

    // MARK: Proposals

    var settings: Proposal.Settings { Proposal.Settings() }

    @Test func startWhenPresentAndNothingRecorded() {
        var spans: [DateInterval] = []
        present(&spans, "2026-11-09 08:12", "2026-11-09 08:40")
        let entries = [Entry(date: d("2026-11-06 09:00"), text: "#api Tests"), Entry(date: d("2026-11-06 17:00"), text: "feierabend")]
        let p = Proposal.derive(entries: entries, spans: spans, now: d("2026-11-09 08:40"), settings: settings)
        #expect(p == .start(at: d("2026-11-09 08:10"), label: "api"))
        // Not again once dismissed, and not while away.
        #expect(Proposal.derive(entries: entries, spans: spans, now: d("2026-11-09 08:40"), settings: settings,
                                dismissed: [p!.id]) == nil)
        #expect(Proposal.derive(entries: entries, spans: spans, now: d("2026-11-09 09:30"), settings: settings) == nil)
        // Not on a weekend (Sunday), with weekdays only.
        var sunday: [DateInterval] = []
        present(&sunday, "2026-11-08 10:00", "2026-11-08 10:30")
        #expect(Proposal.derive(entries: [], spans: sunday, now: d("2026-11-08 10:30"), settings: settings) == nil)
    }

    @Test func breakWhileATaskRan() {
        var spans: [DateInterval] = []
        present(&spans, "2026-11-09 08:00", "2026-11-09 12:04")
        present(&spans, "2026-11-09 12:41", "2026-11-09 12:45")
        let task = Entry(date: d("2026-11-09 08:00"), text: "#api Tests")
        let p = Proposal.derive(entries: [task], spans: spans, now: d("2026-11-09 12:45"), settings: settings)
        #expect(p == .pause(from: d("2026-11-09 12:05"), to: d("2026-11-09 12:40"), resume: task))
        #expect(p!.entries.map(\.1) == ["pause", "#api Tests"])
        // A stop recorded meanwhile, or a short absence: nothing.
        let stopped = [task, Entry(date: d("2026-11-09 12:00"), text: "pause"), Entry(date: d("2026-11-09 12:40"), text: "#api")]
        #expect(Proposal.derive(entries: stopped, spans: spans, now: d("2026-11-09 12:45"), settings: settings) == nil)
        var short = settings
        short.minBreak = 45 * 60
        #expect(Proposal.derive(entries: [task], spans: spans, now: d("2026-11-09 12:45"), settings: short) == nil)
    }

    @Test func endOfDayForAnOpenTaskTheDayBefore() {
        var spans: [DateInterval] = []
        present(&spans, "2026-11-06 08:00", "2026-11-06 17:32")
        present(&spans, "2026-11-09 08:00", "2026-11-09 08:05")
        let entries = [Entry(date: d("2026-11-06 08:00"), text: "#api")]
        let p = Proposal.derive(entries: entries, spans: spans, now: d("2026-11-09 08:05"), settings: settings)
        #expect(p == .endOfDay(at: d("2026-11-06 17:30")))
        // With an end of day recorded: on to today's start.
        let ended = entries + [Entry(date: d("2026-11-06 17:30"), text: "feierabend")]
        #expect(Proposal.derive(entries: ended, spans: spans, now: d("2026-11-09 08:05"), settings: settings)
            == .start(at: d("2026-11-09 08:00"), label: "api"))
    }

    @Test func endOfDayStaysOnItsDayAndSkipsAbsences() {
        var spans: [DateInterval] = []
        present(&spans, "2026-11-06 20:00", "2026-11-06 23:58")
        present(&spans, "2026-11-09 08:00", "2026-11-09 08:05")
        let late = [Entry(date: d("2026-11-06 20:00"), text: "#api")]
        // 23:58 would round to 00:00 of the next day.
        #expect(Proposal.derive(entries: late, spans: spans, now: d("2026-11-09 08:05"), settings: settings)
            == .endOfDay(at: d("2026-11-06 23:59")))
        // Checking mail on a vacation day is no open task.
        let vacation = [Entry(date: d("2026-11-06 00:00"), text: "#urlaub")]
        #expect(Proposal.derive(entries: vacation, spans: spans, now: d("2026-11-09 08:05"), settings: settings)
            == .start(at: d("2026-11-09 08:00"), label: nil))
    }

    @Test func nightPresenceIsNoStart() {
        var spans: [DateInterval] = []
        present(&spans, "2026-11-08 23:30", "2026-11-09 00:40")   // past midnight
        present(&spans, "2026-11-09 03:00", "2026-11-09 03:02")   // a short check
        present(&spans, "2026-11-09 08:12", "2026-11-09 08:40")
        #expect(Proposal.derive(entries: [], spans: spans, now: d("2026-11-09 08:40"), settings: settings)
            == .start(at: d("2026-11-09 08:10"), label: nil))
        // Present since early morning: the start is cut to the window (2 h before the reminder's 8:00).
        var early: [DateInterval] = []
        present(&early, "2026-11-09 05:30", "2026-11-09 06:30")
        #expect(Proposal.derive(entries: [], spans: early, now: d("2026-11-09 06:30"), settings: settings)
            == .start(at: d("2026-11-09 06:00"), label: nil))
    }

    @Test func pauseIdSurvivesReloadAndResumeIsNotInTheFuture() {
        var spans: [DateInterval] = []
        present(&spans, "2026-11-09 08:00", "2026-11-09 12:04")
        present(&spans, "2026-11-09 12:38", "2026-11-09 12:39")
        // Reloading the log gives the same entry a new id; the proposal stays the same.
        let a = Proposal.derive(entries: [Entry(date: d("2026-11-09 08:00"), text: "#api")], spans: spans,
                                now: d("2026-11-09 12:39"), settings: settings)
        let b = Proposal.derive(entries: [Entry(date: d("2026-11-09 08:00"), text: "#api")], spans: spans,
                                now: d("2026-11-09 12:39"), settings: settings)
        #expect(a != nil && a?.id == b?.id)
        // Back at 12:38, 12:39 now: 12:40 would be in the future.
        guard case .pause(_, let to, _) = a else { Issue.record("no pause"); return }
        #expect(to == d("2026-11-09 12:39"))
    }

    @Test func staleProposalIds() {
        let now = d("2026-11-09 08:00")
        let pause = Proposal.pause(from: d("2026-11-09 12:05"), to: d("2026-11-09 12:40"),
                                   resume: Entry(date: d("2026-11-09 08:00"), text: "#api"))
        #expect(!Proposal.isStale(id: pause.id, now: now))
        #expect(!Proposal.isStale(id: Proposal.endOfDay(at: d("2026-11-02 17:00")).id, now: now))
        #expect(Proposal.isStale(id: Proposal.start(at: d("2026-10-20 08:00"), label: nil).id, now: now))
        #expect(Proposal.isStale(id: "garbage", now: now))
    }

    // MARK: Reminder

    @Test func noReminderWhileAwayAndIntervalAfterReturn() {
        let r = Reminder()
        let now = d("2026-11-09 10:00")
        #expect(r.status(entries: [], now: now, last: nil, presence: (nil, d("2026-11-09 08:30"))) == .away)
        // Back at 9:50 after a break: the next reminder 30 min after that, not at once.
        let back = DateInterval(start: d("2026-11-09 09:50"), end: now)
        #expect(r.status(entries: [], now: now, last: nil, presence: (back, d("2026-11-09 08:30")))
            == .due(since: d("2026-11-09 08:30"), due: d("2026-11-09 10:20")))
        // Without presence detection as before: since the start of the window.
        #expect(r.status(entries: [], now: now, last: nil) == .due(since: d("2026-11-09 08:00"), due: d("2026-11-09 08:30")))
    }
}
