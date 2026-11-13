import Foundation
import Testing
@testable import zeyt

@Suite struct TimelineTests {
    let d = CalendarTests.date
    let later = CalendarTests.date("2026-11-10 12:00")

    func blocks(_ items: [(String, String)], now: Date? = nil) -> [Block] {
        Block.compute(items.map { Entry(date: d("2026-11-09 " + $0.0), text: $0.1) }, now: now ?? later)
    }

    @Test func entriesAloneReachFromFirstEntryToEndOfDay() throws {
        let b = blocks([("08:00", "#a"), ("12:00", "pause"), ("12:30", "#b"), ("17:00", "feierabend")])
        let tl = try #require(Timeline.make(b))
        #expect(tl.start == d("2026-11-09 08:00") && tl.end == d("2026-11-09 17:00"))
        #expect(tl.entriesEnd == tl.end)
        #expect(tl.fraction(d("2026-11-09 12:30")) == 0.5)
    }

    @Test func presenceWidensTheBarOnBothSides() throws {
        let b = blocks([("08:30", "#a"), ("16:00", "feierabend")])
        let presence = [DateInterval(start: d("2026-11-09 07:52"), end: d("2026-11-09 12:00")),
                        DateInterval(start: d("2026-11-09 12:40"), end: d("2026-11-09 17:15"))]
        let tl = try #require(Timeline.make(b, presence: presence))
        #expect(tl.start == d("2026-11-09 07:52") && tl.end == d("2026-11-09 17:15"))
        #expect(tl.entriesEnd == d("2026-11-09 16:00"))
        // Presence inside the entries changes nothing.
        let inner = [DateInterval(start: d("2026-11-09 09:00"), end: d("2026-11-09 10:00"))]
        #expect(Timeline.make(b, presence: inner)?.start == d("2026-11-09 08:30"))
        // Working past midnight the evening before doesn't start this day at 00:00.
        let night = [DateInterval(start: d("2026-11-09 00:00"), end: d("2026-11-09 00:18"))] + presence
        #expect(Timeline.make(b, presence: night)?.start == d("2026-11-09 07:52"))
    }

    @Test func presenceAloneMakesABarWithoutEntries() throws {
        let tl = try #require(Timeline.make([], presence: [DateInterval(start: d("2026-11-09 08:00"), end: d("2026-11-09 09:00"))]))
        #expect(tl.entriesEnd == nil)
        #expect(Timeline.make([]) == nil)
        #expect(Timeline.make(blocks([("08:00", "#a")])) == nil)   // open task, no duration
    }

    @Test func hoverSnapsToTenMinutes() throws {
        let tl = try #require(Timeline.make(blocks([("08:03", "#a"), ("10:03", "feierabend")])))
        #expect(tl.snapped(at: 0) == d("2026-11-09 08:00"))
        #expect(tl.snapped(at: 0.5) == d("2026-11-09 09:00"))   // 09:03
        #expect(tl.snapped(at: 0.53) == d("2026-11-09 09:10"))  // 09:06:36
        #expect(tl.snapped(at: 2) == d("2026-11-09 10:00"))     // clamped to the end
        // Other resolutions (setting).
        let fine = try #require(Timeline.make(blocks([("08:03", "#a"), ("10:03", "feierabend")]), step: 1))
        #expect(fine.snapped(at: 0) == d("2026-11-09 08:03"))
        let coarse = try #require(Timeline.make(blocks([("08:03", "#a"), ("10:03", "feierabend")]), step: 30))
        #expect(coarse.snapped(at: 0.53) == d("2026-11-09 09:00"))
    }

    @Test func clickNearAStartGoesToTheEntryElseCreatesOne() throws {
        let entries = [Entry(date: d("2026-11-09 08:00"), text: "#a"), Entry(date: d("2026-11-09 10:10"), text: "#b"),
                       Entry(date: d("2026-11-09 12:00"), text: "feierabend")]
        let tl = try #require(Timeline.make(Block.compute(entries, now: later)))   // 4 h
        let tol = 0.02   // ~5 min
        #expect(tl.target(at: 0, tolerance: tol, in: entries) == .entry(entries[0]))
        #expect(tl.target(at: tl.fraction(d("2026-11-09 10:13")), tolerance: tol, in: entries) == .entry(entries[1]))
        #expect(tl.target(at: 1, tolerance: tol, in: entries) == .entry(entries[2]))
        #expect(tl.target(at: tl.fraction(d("2026-11-09 09:12")), tolerance: tol, in: entries) == .new(d("2026-11-09 09:10")))
        // Snapped onto a start outside the tolerance: still that entry, no second one at the same minute.
        #expect(tl.target(at: tl.fraction(d("2026-11-09 10:14")), tolerance: 0.001, in: entries) == .entry(entries[1]))
    }
}
