import Foundation
import Testing
@testable import zeyt

/// Ported from tests/logic.test.js of the UI concept. Clock fixed to Tue 2026-10-13 18:00.
private let cal = Calendar.current
private func at(_ time: String, day: String = "2026-10-13") -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: "\(day) \(time)")!
}
private let now = at("18:00")

/// The sample day of the concept.
private func sample() -> [Entry] {
    [("08:30", "#kundenprojekt Login-Flow umbauen"), ("09:45", "#meeting Daily"),
     ("10:00", "#kundenprojekt Login-Flow umbauen"), ("12:15", "pause"), ("12:50", "#code-review MR Backend-API"),
     ("13:40", "#kundenprojekt Bugfixes Ticketliste"), ("16:00", "#orga Mails, Planung"), ("16:30", "pause"),
     ("16:40", "#kundenprojekt Release vorbereiten")].map { Entry(date: at($0.0), text: $0.1) }
}

private func add(_ entries: [Entry], _ time: String, _ text: String) -> [Entry] {
    (entries + [Entry(date: at(time), text: text)]).sorted { $0.date < $1.date }
}

struct TagTests {
    @Test(arguments: [("Kundenprojekt", "kundenprojekt"), ("code review", "code-review"), ("##A__b  c", "a-b-c"),
                      ("-x", "x"), ("Ü-Bahn!", "ü-bahn"), ("", "")])
    func normalizes(input: String, expected: String) {
        #expect(Rules.tag(input) == expected)
    }

    @Test func maxLength() {
        #expect(Rules.tag(String(repeating: "a", count: 40)).count == 32)
    }

    @Test func splitsLabelAndComment() {
        let s = Rules.splitLabel("#Orga Mails beantworten")
        #expect(s?.label == "orga")
        #expect(s?.comment == "Mails beantworten")
        #expect(Rules.splitLabel("orga") == nil)
    }

    @Test func shortensInTheMiddle() {
        let long = "kundenportal-relaunch-phase-zwei"
        let m = Rules.mid(long, 24)
        #expect(m.count == 24)
        #expect(m.hasPrefix("kundenportal"))
        #expect(m.hasSuffix("se-zwei"))
        #expect(Rules.mid("kurz", 24) == "kurz")
    }

    @Test func isoWeek() {
        #expect(Rules.isoWeek(at("12:00")) == 42)
        #expect(Rules.isoWeek(at("12:00", day: "2027-01-01")) == 53)
        #expect(Rules.isoWeek(at("12:00", day: "2026-01-01")) == 1)
        #expect(Rules.isoWeek(at("12:00", day: "2025-12-29")) == 1)
    }
}

struct DayTests {
    @Test func sampleDay() {
        let blocks = Block.compute(sample(), now: now)
        #expect(blocks.map(\.kind) == [.task, .task, .task, .pause, .task, .task, .task, .pause, .task])
        #expect(blocks.last!.running)
        #expect(Fmt.duration(blocks.last!.duration) == "1:20")
        #expect(Fmt.duration(Block.worked(blocks)) == "8:45")
        #expect(Fmt.bt(Block.worked(blocks)) == "1,09 BT")
    }

    @Test func futureTaskIsOpenAndClosesThePrevious() {
        let blocks = Block.compute(add(sample(), "19:00", "#x"), now: now)
        #expect(blocks.last!.isOpen)
        #expect(Fmt.duration(blocks[blocks.count - 2].duration) == "2:20")
    }

    @Test func lastTaskOfPastDayIsOpen() {
        let blocks = Block.compute([Entry(date: at("09:00", day: "2026-10-12"), text: "#a")], now: now)
        #expect(blocks[0].isOpen)
        #expect(Block.worked(blocks) == 0)
    }

    @Test func stopKindIsDerived() {
        #expect(Rules.stopIsEndOfDay(sample(), at: now))
        #expect(!Rules.stopIsEndOfDay(sample(), at: at("12:00")))
        let blocks = Block.compute(add(sample(), "18:00", "pause"), now: now)
        #expect(blocks.last!.kind == .end)
        #expect(Fmt.duration(blocks[8].duration) == "1:20")
        // Working after "Feierabend" turns it into a break.
        let later = Block.compute(add(add(sample(), "18:00", "feierabend"), "18:30", "#orga"), now: at("19:00"))
        #expect(later[9].kind == .pause)
    }

    @Test func sameStartTimeIsAConflict() {
        let blocks = Block.compute(add(sample(), "08:30", "#meeting"), now: now)
        #expect(blocks.contains { $0.conflict })
    }
}

struct ResumeTests {
    @Test func notWhileATaskRuns() {
        #expect(Rules.resume(sample(), at: now, now: now) == nil)
        #expect(Rules.resume(sample(), at: at("10:00"), now: now) == nil)
    }

    @Test func insideAPastPause() {
        #expect(Rules.resume(sample(), at: at("12:30"), now: now)?.label == "kundenprojekt")
        #expect(Rules.resume(sample(), at: at("16:35"), now: now)?.label == "orga")
    }

    @Test func notAtAnExistingEntry() {
        #expect(Rules.resume(sample(), at: at("12:15"), now: now) == nil)
    }

    @Test func afterFeierabendButNotInTheFuture() {
        let day = add(sample(), "18:00", "feierabend")
        let r = Rules.resume(day, at: at("18:05"), now: now)
        #expect(r?.label == "kundenprojekt")
        #expect(r?.title == "Release vorbereiten")
        #expect(Rules.resume(day, at: at("18:30"), now: now) == nil)
    }

    @Test func notOnAFutureDay() {
        let day = [("09:00", "#a"), ("10:00", "pause"), ("11:00", "#b")].map { Entry(date: at($0.0, day: "2026-10-14"), text: $0.1) }
        #expect(Rules.resume(day, at: at("10:30", day: "2026-10-14"), now: now) == nil)
    }

    @Test func notWhenTheTaskBeforeHasNoLabel() {
        let day = [Entry(date: at("09:00"), text: "frei"), Entry(date: at("10:00"), text: "pause")]
        #expect(Rules.resume(day, at: at("10:30"), now: now) == nil)
    }
}

struct SuggestionTests {
    private let registry: [String: LabelInfo] = [
        "kundenprojekt": LabelInfo(account: "Kunde A", project: "Login-Plattform"),
        "code-review": LabelInfo(account: "Kunde A", project: "Login-Plattform"),
        "meeting": LabelInfo(account: "Intern", project: "Team-Meetings"),
        "orga": LabelInfo(account: "Intern", project: "Organisation"),
        "weiterbildung": LabelInfo(account: "Intern", project: "Weiterbildung"),
    ]

    @Test func recentFirstWithoutQuery() {
        let s = Rules.suggest("", stats: Rules.labelStats(sample(), registry: registry), registry: registry)
        #expect(s.first?.label == "kundenprojekt")
        #expect(s.first?.meta == "Kunde A › Login-Plattform")
        #expect(s.count == 5)
    }

    @Test func prefixMatchesFirstAndNewLabelOffered() {
        let stats = Rules.labelStats(sample(), registry: registry)
        #expect(Rules.suggest("kun", stats: stats, registry: registry).first?.label == "kundenprojekt")
        // Filter also matches account and project.
        #expect(Rules.suggest("intern", stats: stats, registry: registry).map(\.label).contains("meeting"))
        let new = Rules.suggest("neu", stats: stats, registry: registry)
        #expect(new.last?.isNew == true)
        #expect(new.last?.meta == "Neu · Account & Projekt noch zuordnen")
        #expect(Rules.suggest("orga", stats: stats, registry: registry).contains { $0.isNew } == false)
    }

    @Test func missingAssignmentIsShown() {
        #expect(Rules.meta(nil) == "Account & Projekt fehlen")
        #expect(Rules.meta(LabelInfo(account: "A", project: "")) == "Account & Projekt fehlen")
    }

    @Test func accountOptionsCountLabels() {
        let o = Rules.options(.account, query: "", account: "", excluding: "x", registry: registry)
        #expect(o.first?.value == "Intern")
        #expect(o.first?.meta == "3 Labels")
    }

    @Test func projectOptionsAreFilteredByAccount() {
        let o = Rules.options(.project, query: "", account: "Kunde A", excluding: "x", registry: registry)
        #expect(o.map(\.value) == ["Login-Plattform"])
        let all = Rules.options(.project, query: "", account: "", excluding: "x", registry: registry)
        #expect(all.first?.meta.hasPrefix("Kunde A · ") == true)
        let new = Rules.options(.project, query: "Neu", account: "Kunde A", excluding: "x", registry: registry)
        #expect(new.last?.meta == "Neues Projekt für Kunde A")
    }
}

struct TimeParsingTests {
    @Test(arguments: [("9:05", 9, 5), ("0905", 9, 5), ("905", 9, 5), ("9", 9, 0), ("23.59", 23, 59)])
    func parses(text: String, hour: Int, minute: Int) {
        let t = Fmt.parseTime(text)
        #expect(t?.hour == hour)
        #expect(t?.minute == minute)
    }

    @Test func rejectsInvalid() {
        #expect(Fmt.parseTime("25:00") == nil)
        #expect(Fmt.parseTime("abc") == nil)
    }
}

struct NotificationReplyTests {
    @Test(arguments: [("#alpha Sync Team", "#alpha Sync Team"), ("alpha Sync Team", "#alpha Sync Team"), ("ALPHA", "#alpha"),
                      ("Pause", "pause"), ("feierabend", "feierabend"), ("Urlaub", "#urlaub")])
    @MainActor func parsesReply(reply: String, stored: String) {
        #expect(Notifier.parse(reply) == stored)
    }
}

struct AbsenceLabelTests {
    @Test func absenceComesFromTheLabel() {
        let d = Date()
        #expect(Entry(date: d, text: "#krank Krank").absence == .sick)
        #expect(Entry(date: d, text: "#kind-krank").absence == .childSick)
        #expect(Entry(date: d, text: "#urlaub").absence == .vacation)
        #expect(Entry(date: d, text: "urlaub").absence == nil)
        #expect(Entry(date: d, text: "#alpha Urlaubsübergabe").absence == nil)
        #expect(Entry(date: d, text: "feierabend").absence == nil)
    }

    @Test func absenceEntriesCountAsWorkedTime() {
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        let blocks = Block.compute([Entry(date: at(8, 0), text: "#urlaub Urlaub"), Entry(date: at(14, 24), text: "feierabend")],
                                   now: at(20, 0))
        #expect(Block.worked(blocks) == 6 * 3600 + 24 * 60)
    }
}

struct DayTextTests {
    @Test func strictOnlyAcceptsADay() {
        let zeyt = "' KW 36  35.75h\n\n2026-09-01 ' Di 9h\n07:30 #les Analyse\n  \n12:00 pause\n17:30 feierabend\n\n2026-09-02 ' Mi\n08:00 #x\n"
        #expect(DayText.parse(zeyt, strict: true)?.count == 3)
        let mail = "Hallo,\n12.50 € für das Essen\nGruß"
        #expect(DayText.parse(mail) != nil)
        #expect(DayText.parse(mail, strict: true) == nil)
        #expect(DayText.parse("Treffen um 9:30", strict: true) == nil)
    }

    @Test func roundTrip() {
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        let text = DayText.make([Entry(date: at(8, 0), text: "#alpha Sync Team"), Entry(date: at(12, 0), text: "pause"),
                                 Entry(date: at(16, 5), text: "feierabend")])
        #expect(text == "08:00 #alpha Sync Team\n12:00 pause\n16:05 feierabend")
        #expect(DayText.parse(text) == [.init(hour: 8, minute: 0, text: "#alpha Sync Team"),
                                        .init(hour: 12, minute: 0, text: "pause"),
                                        .init(hour: 16, minute: 5, text: "feierabend")])
    }

    @Test func readsZeytBlockAndStopsAtNextDay() {
        let zeyt = """
        ' KW 32  34.58h  4.3bt

        2026-08-04 ' Di 8.58h
        08:30 #alpha Sync Design Review
        9.30\t#alpha Sync Backend
        12:00 pause

        2026-08-05 ' Mi
        08:00 #svt
        """
        #expect(DayText.parse(zeyt) == [.init(hour: 8, minute: 30, text: "#alpha Sync Design Review"),
                                        .init(hour: 9, minute: 30, text: "#alpha Sync Backend"),
                                        .init(hour: 12, minute: 0, text: "pause")])
    }

    @Test func rejectsTextWithoutTimes() {
        #expect(DayText.parse("Hallo Welt") == nil)
        #expect(DayText.parse("") == nil)
        #expect(DayText.parse("25:00 #x") == nil)
    }

    @Test func rangeSkipsWeekends() {
        let cal = Calendar.current
        let fri = cal.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        let tue = cal.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        #expect(DayText.days(from: fri, to: tue, weekends: false).map { cal.component(.day, from: $0) } == [16, 19, 20])
        #expect(DayText.days(from: fri, to: tue, weekends: true).count == 5)
    }
}

@MainActor
struct PasteTests {
    @Test func pasteReplaceAppendEmptyAndUndo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zeyt-test-\(UUID().uuidString)")
        setenv("ZEYT_DATA_DIR", dir.path, 1)
        defer { unsetenv("ZEYT_DATA_DIR"); try? FileManager.default.removeItem(at: dir) }
        let store = EntryStore()
        let cal = Calendar.current
        let mon = cal.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let tue = cal.date(byAdding: .day, value: 1, to: mon)!
        let wed = cal.date(byAdding: .day, value: 2, to: mon)!
        store.add(date: cal.date(bySettingHour: 9, minute: 0, second: 0, of: tue)!, text: "#alt", dedupe: false)
        let items = DayText.parse("08:00 #urlaub\n14:24 feierabend")!

        let empty = store.paste(items, on: [tue, wed], mode: .emptyOnly)
        #expect(store.entries(on: tue).map(\.text) == ["#alt"])
        #expect(store.entries(on: wed).map(\.text) == ["#urlaub", "feierabend"])
        store.undo(empty)
        #expect(store.entries(on: wed).isEmpty)

        let replaced = store.paste(items, on: [tue], mode: .replace)
        #expect(store.entries(on: tue).map(\.text) == ["#urlaub", "feierabend"])
        store.undo(replaced)
        #expect(store.entries(on: tue).map(\.text) == ["#alt"])

        store.paste(items, on: [tue], mode: .append)
        #expect(store.entries(on: tue).map(\.text) == ["#urlaub", "#alt", "feierabend"])
        #expect(store.lastWorkDay(before: wed).map { cal.isDate($0, inSameDayAs: tue) } == true)
        #expect(store.entries(on: mon).isEmpty)
    }
}

struct MigrationTests {
    @Test func copiesLegacySettingsOnce() {
        let name = "zeyt-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!, legacy = UserDefaults(suiteName: name + "-legacy")!
        defer { defaults.removePersistentDomain(forName: name); legacy.removePersistentDomain(forName: name + "-legacy") }
        legacy.set("tok", forKey: "agentToken")
        legacy.set(true, forKey: "agentEnabled")
        defaults.set(false, forKey: "agentEnabled")   // already set in the new app: kept
        Migration.run(defaults: defaults, legacy: legacy)
        #expect(defaults.string(forKey: "agentToken") == "tok")
        #expect(defaults.bool(forKey: "agentEnabled") == false)
        legacy.set("new", forKey: "agentToken")
        defaults.removeObject(forKey: "agentToken")
        Migration.run(defaults: defaults, legacy: legacy)
        #expect(defaults.string(forKey: "agentToken") == nil)
    }
}

struct LineNavTests {
    // task with comment, pause (time only), task without comment, input bar
    let lines: [[LineNav.Column]] = [[.time, .label, .comment], [.time], [.time, .label], [.time, .label, .comment]]

    @Test func leftAndRightStayInTheLine() {
        #expect(LineNav.move(.leftAtStart, line: 0, column: .comment, columns: lines)! == (0, .label))
        #expect(LineNav.move(.leftAtStart, line: 0, column: .label, columns: lines)! == (0, .time))
        #expect(LineNav.move(.leftAtStart, line: 0, column: .time, columns: lines) == nil)
        #expect(LineNav.move(.rightAtEnd, line: 0, column: .time, columns: lines)! == (0, .label))
        #expect(LineNav.move(.rightAtEnd, line: 0, column: .comment, columns: lines) == nil)
        #expect(LineNav.move(.rightAtEnd, line: 1, column: .time, columns: lines) == nil)
    }

    @Test func upAndDownKeepTheColumn() {
        // comment → pause has only the time; the row without comment gets the label
        #expect(LineNav.move(.down, line: 0, column: .comment, columns: lines)! == (1, .time))
        #expect(LineNav.move(.up, line: 3, column: .comment, columns: lines)! == (2, .label))
        // from a time field ↑/↓ always land in a time field, also after passing a pause
        #expect(LineNav.move(.down, line: 1, column: .time, columns: lines)! == (2, .time))
        #expect(LineNav.move(.up, line: 1, column: .time, columns: lines)! == (0, .time))
        #expect(LineNav.move(.up, line: 2, column: .label, columns: lines)! == (1, .time))
        #expect(LineNav.move(.up, line: 0, column: .label, columns: lines) == nil)
        #expect(LineNav.move(.down, line: 3, column: .time, columns: lines) == nil)
        #expect(LineNav.move(.up, line: 3, column: .time, columns: lines)! == (2, .time))
        #expect(LineNav.move(.enter, line: 0, column: .label, columns: lines) == nil)
    }
}

struct InsertTimeTests {
    private func t(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "2026-10-16 " + s)!
    }

    @Test func halfwayToTheNextEntryOnFiveMinutes() {
        #expect(Rules.insertTime(after: t("08:30"), next: t("12:00"), now: t("18:00")) == t("10:15"))
        #expect(Rules.insertTime(after: t("09:00"), next: t("09:20"), now: t("18:00")) == t("09:10"))
        // too little room for a 5-minute slot: the exact minute halfway
        #expect(Rules.insertTime(after: t("09:00"), next: t("09:04"), now: t("18:00")) == t("09:02"))
        #expect(Rules.insertTime(after: t("09:00"), next: t("09:01"), now: t("18:00")) == t("09:00"))
    }

    @Test func afterTheLastEntry() {
        // today: now, rounded
        #expect(Rules.insertTime(after: t("14:00"), next: nil, now: t("16:43")) == t("16:45"))
        // now is not later (or another day): half an hour on
        #expect(Rules.insertTime(after: t("14:00"), next: nil, now: t("13:00")) == t("14:30"))
        #expect(Rules.insertTime(after: t("23:50"), next: nil, now: t("08:00")) == t("23:55"))
    }
}

struct ReminderTests {
    // Friday 2026-10-16
    private func t(_ s: String, day: String = "2026-10-16") -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) \(s)")!
    }
    private func e(_ s: String, _ text: String) -> Entry { Entry(date: t(s), text: text) }
    private let r = Reminder(minutes: 30)

    @Test func noEntryYetCountsFromTheStartOfTheWindow() {
        #expect(r.status(entries: [], now: t("08:10"), last: nil) == .due(since: t("08:00"), due: t("08:30")))
        #expect(r.status(entries: [], now: t("07:50"), last: nil) == .outside)
        #expect(r.status(entries: [], now: t("18:00"), last: nil) == .outside)
    }

    @Test func unlabeledEntryCountsFromItsStartAndRepeats() {
        let entries = [e("09:00", "#alpha"), e("10:15", "Notizen ohne Label")]
        #expect(r.status(entries: entries, now: t("10:20"), last: nil) == .due(since: t("10:15"), due: t("10:45")))
        // after a reminder at 10:45 the next one is half an hour later
        #expect(r.status(entries: entries, now: t("10:50"), last: t("10:45")) == .due(since: t("10:15"), due: t("11:15")))
    }

    @Test func labelBreakEndAndAbsenceNeedNoReminder() {
        for text in ["#alpha", "pause", "feierabend", "#urlaub"] {
            let s = r.status(entries: [e("09:00", text)], now: t("10:00"), last: nil)
            guard case .assigned = s else { Issue.record("\(text): \(s)"); continue }
        }
        // a reminder before the label was set doesn't count once a new unlabeled entry starts
        let entries = [e("09:00", "#alpha"), e("11:00", "")]
        #expect(r.status(entries: entries, now: t("11:05"), last: t("08:30")) == .due(since: t("11:00"), due: t("11:30")))
    }

    @Test func weekendsOffAndNotAfterTheWindow() {
        #expect(r.status(entries: [], now: t("10:00", day: "2026-10-17"), last: nil) == .outside)
        var weekend = r
        weekend.weekdaysOnly = false
        #expect(weekend.status(entries: [], now: t("10:00", day: "2026-10-17"), last: nil)
                == .due(since: t("08:00", day: "2026-10-17"), due: t("08:30", day: "2026-10-17")))
        // due after the end of the window
        #expect(r.status(entries: [e("17:45", "")], now: t("17:50"), last: nil) == .outside)
        var off = r
        off.enabled = false
        #expect(off.status(entries: [], now: t("10:00"), last: nil) == .off)
    }
}

struct UncountedLabelsTests {
    @Test func uncountedLabelsAreLeftOut() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let at = { f.date(from: "2026-10-06 " + $0)! }
        let blocks = Block.compute([Entry(date: at("08:00"), text: "#alpha"), Entry(date: at("12:00"), text: "#krank"),
                                    Entry(date: at("14:24"), text: "feierabend")], now: at("20:00"))
        #expect(Block.worked(blocks) == 6.4 * 3600)
        #expect(Block.worked(blocks, uncounted: ["krank"]) == 4 * 3600)
        #expect(Block.worked(blocks, uncounted: ["alpha", "krank"]) == 0)
        #expect(Block.worked(blocks, uncounted: ["urlaub"]) == 6.4 * 3600)
    }
}
