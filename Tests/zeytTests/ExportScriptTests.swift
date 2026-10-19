import Foundation
import Testing
@testable import zeyt

/// The Chronos template, checked against known cases.
@Suite struct ExportScriptTests {
    private static func at(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    /// "2026-07-07 08:00 #alpha Sync" per line.
    private func export(_ lines: [String], labels: [String: LabelInfo] = [:], script: String = ExportScript.Template.chronos.script)
        -> ExportScript.Output {
        let entries = lines.map { l -> Entry in
            let p = l.split(separator: " ", maxSplits: 2).map(String.init)
            return Entry(date: Self.at(p[0] + " " + p[1]), text: p.count > 2 ? p[2] : "")
        }
        let input = ExportScript.input(
            month: Self.at("2026-07-01 00:00"),
            entries: { d in entries.filter { Calendar.current.isDate($0.date, inSameDayAs: d) } },
            labels: labels, now: Self.at("2026-08-15 12:00"))
        return try! ExportScript.run(script, input: input).get()
    }

    private func json(_ o: ExportScript.Output) -> [String: [[String: AnyHashable]]] {
        try! JSONSerialization.jsonObject(with: Data(o.text.utf8)) as! [String: [[String: AnyHashable]]]
    }

    private let acme: [String: LabelInfo] = [
        "alpha": LabelInfo(account: "ACME-PROJECT", project: "TICKET-100"),
        "team": LabelInfo(account: "ACME-PROJECT", project: "MEETING-100"),
        "meeting": LabelInfo(account: "ACME-PROJECT", project: "MEETING-200"),
    ]

    @Test func aggregatesADayByTicket() {
        let o = export(["2026-07-07 08:00 #alpha Sync", "2026-07-07 09:15 #alpha Sync Review", "2026-07-07 09:45 #team Daily",
                        "2026-07-07 12:00 pause", "2026-07-07 13:00 #meeting Workshop", "2026-07-07 14:00 #alpha",
                        "2026-07-07 16:00 feierabend"], labels: acme)
        let j = json(o)
        #expect(j["bookings"] == [
            ["project_name": "ACME-PROJECT", "account_name": "TICKET-100", "working_day": 7, "duration": "03:45", "comment": "Sync; Sync Review"],
            ["project_name": "ACME-PROJECT", "account_name": "MEETING-100", "working_day": 7, "duration": "02:15", "comment": "Daily"],
            ["project_name": "ACME-PROJECT", "account_name": "MEETING-200", "working_day": 7, "duration": "01:00", "comment": "Workshop"],
        ])
        #expect(j["working_hours"] == [["working_day": 7, "start": "08:00", "end": "16:00", "breaks": "01:00"]])
        #expect(o.fileExtension == "json")
        #expect(o.warnings.isEmpty)
        // Same key order as zeyt.
        #expect(o.text.contains("\"project_name\": \"ACME-PROJECT\",\n      \"account_name\""))
    }

    @Test func skipsDaysWithoutFeierabendAndWarns() {
        let o = export(["2026-07-07 08:00 #alpha"], labels: acme)
        #expect(json(o)["bookings"] == [])
        #expect(json(o)["working_hours"] == [])
        #expect(o.warnings == ["2026-07-07: kein Feierabend, Tag nicht exportiert"])
    }

    @Test func absenceIsNotExported() {
        // a day of only absence (or only a break) is left out
        for label in ["#urlaub", "#krank", "#kind-krank", "pause"] {
            let o = export(["2026-07-24 08:00 \(label)", "2026-07-24 14:24 feierabend"])
            #expect(json(o)["bookings"] == [])
            #expect(json(o)["working_hours"] == [])
            #expect(o.warnings.isEmpty)
        }
        // sick in the afternoon: attendance ends with the work
        let labels = ["alpha": LabelInfo(account: "ACME", project: "TICKET-1")]
        let j = json(export(["2026-07-06 08:00 #alpha", "2026-07-06 12:00 #krank", "2026-07-06 14:24 feierabend"], labels: labels))
        #expect(j["working_hours"] == [["working_day": 6, "start": "08:00", "end": "12:00", "breaks": "00:00"]])
        #expect(j["bookings"]?.map { $0["duration"] as? String } == ["04:00"])
    }

    @Test func attendanceMinusBreaksEqualsBookings() {
        let labels = ["beta": LabelInfo(account: "ACME", project: "TICKET-1"), "alpha": LabelInfo(account: "ACME", project: "TICKET-100")]
        let j = json(export(["2026-07-06 08:00 #beta Nightly", "2026-07-06 09:00 #urlaub", "2026-07-06 10:00 #alpha Analyse",
                             "2026-07-06 12:00 pause", "2026-07-06 13:00 #alpha Analyse", "2026-07-06 16:30 feierabend"], labels: labels))
        #expect(j["working_hours"]?.first?["breaks"] as? String == "02:00")
        #expect(j["bookings"]?.map { $0["duration"] as? String } == ["01:00", "05:30"])
    }

    @Test func mergesLabelsOfOneTicketAndWarnsAboutUnbooked() {
        let labels = ["a": LabelInfo(account: "ACME", project: "TICKET-100"), "b": LabelInfo(account: "ACME", project: "TICKET-100")]
        let o = export(["2026-07-07 07:00 Besprechungen", "2026-07-07 08:00 #a One", "2026-07-07 09:00 #b Two",
                        "2026-07-07 10:00 #gamma", "2026-07-07 11:00 feierabend"], labels: labels)
        let j = json(o)
        #expect(j["bookings"] == [["project_name": "ACME", "account_name": "TICKET-100", "working_day": 7, "duration": "02:00", "comment": "One; Two"]])
        #expect(j["working_hours"]?.first?["breaks"] as? String == "00:00")
        #expect(o.warnings == ["ohne Label: 01:00 h ohne Account, nicht gebucht", "#gamma: 01:00 h ohne Account, nicht gebucht"])
    }

    @Test func scriptChoosesTheFormat() {
        let rows = "[[\"a\", \"b;c\", 'say \"hi\"'], [1, null, \"x\\ty\"]]"
        let tsv = export([], script: "function transform(i) { return tsv(\(rows)) }")
        #expect(tsv.fileExtension == "tsv")
        #expect(tsv.text == "a\tb;c\tsay \"hi\"\n1\t\tx y\n")
        let csv = export([], script: "function transform(i) { return csv(\(rows), { separator: ';', name: 'liste' }) }")
        #expect(csv.fileExtension == "csv" && csv.fileName == "liste")
        #expect(csv.text == "a;\"b;c\";\"say \"\"hi\"\"\"\n1;;x\ty\n")
        let md = export([], script: "function transform(i) { return text('# Juli', { extension: 'md' }) }")
        #expect(md.fileExtension == "md" && md.text == "# Juli")
        let j = export([], script: "function transform(i) { return json({ n: i.days.length }, { indent: 0 }) }")
        #expect(j.fileExtension == "json" && j.text == "{\"n\":31}")   // every day of July, also empty ones
        // the old way still works
        let old = export([], script: "var fileExtension = 'tsv'; function transform(i) { return 'x' }")
        #expect(old.fileExtension == "tsv" && old.text == "x" && old.fileName == nil)
    }

    @Test func csvTemplateAndErrors() {
        let o = export(["2026-07-07 08:00 #alpha Sync", "2026-07-07 09:30 feierabend"], labels: acme, script: ExportScript.Template.csv.script)
        #expect(o.fileExtension == "csv")
        #expect(o.text.contains("\"2026-07-07\";\"08:00\";\"09:30\";\"1,50\";\"Tätigkeit\";\"alpha\";\"ACME-PROJECT\";\"TICKET-100\";\"Sync\""))

        let input = ExportScript.input(month: Self.at("2026-07-01 00:00"), entries: { _ in [] }, labels: [:], now: Date())
        guard case .failure(let f) = ExportScript.run("function transform(input) { return input.nope.x }", input: input) else {
            Issue.record("expected failure"); return
        }
        #expect(f.message.contains("TypeError"))
        guard case .failure = ExportScript.run("var x = 1", input: input) else { Issue.record("expected failure"); return }
    }
}

@Suite struct ExportScriptLimitTests {
    @Test func endlessLoopIsStopped() {
        let start = Date()
        guard case .failure(let f) = ExportScript.run("function transform(i) { while (true) {} }", input: [:]) else {
            Issue.record("expected failure"); return
        }
        #expect(Date().timeIntervalSince(start) < ExportScript.timeLimit + 3)
        #expect(f.message.contains("abgebrochen"), "\(f.message)")
    }

    @Test func fileExtensionIsSanitized() {
        let o = try! ExportScript.run("var fileExtension = '../x.y'; function transform(i) { return 'a' }", input: [:]).get()
        #expect(o.fileExtension == "xy")
    }
}
