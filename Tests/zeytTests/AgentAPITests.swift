import Foundation
import Testing
@testable import zeyt

/// The agent API through its request handler: own data folder and defaults, no server, no environment variables.
@MainActor
@Suite(.serialized) final class AgentAPITests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zeyt-api-\(UUID().uuidString)")
    let suite = "zeyt-api-tests-\(UUID().uuidString)"
    let store: EntryStore
    let api: AgentAPI
    let state = AppState()
    /// AppState writes UserDefaults.standard: what the settings tests change is put back.
    let savedReminder: Reminder
    let savedAway: Int
    let savedTimeline: Bool
    let savedTimelineMinutes: Int

    init() {
        store = EntryStore(directory: dir)
        api = AgentAPI(store: store, defaults: UserDefaults(suiteName: suite)!)
        api.state = state
        savedReminder = state.reminder
        savedAway = state.awayMinutes
        savedTimeline = state.timelineCoversPresence
        savedTimelineMinutes = state.timelineMinutes
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func restore() {
        state.reminder = savedReminder
        state.awayMinutes = savedAway
        state.timelineCoversPresence = savedTimeline
        state.timelineMinutes = savedTimelineMinutes
    }

    /// One request as it comes over the wire; returns status and parsed JSON (or the text).
    @discardableResult
    func call(_ method: String, _ target: String, _ body: Any? = nil, token: String? = nil) -> (Int, Any) {
        let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        head += "Authorization: Bearer \(token ?? api.token)\r\nContent-Length: \(data.count)\r\n\r\n"
        let req = HTTPRequest.parse(Data(head.utf8) + data)!
        let res = api.handle(req)
        let json = (try? JSONSerialization.jsonObject(with: res.body, options: .fragmentsAllowed))
            ?? String(decoding: res.body, as: UTF8.self)
        return (res.status, json)
    }

    func object(_ r: (Int, Any)) -> [String: Any] { r.1 as? [String: Any] ?? [:] }
    func list(_ r: (Int, Any)) -> [[String: Any]] { r.1 as? [[String: Any]] ?? [] }

    func at(_ s: String) -> Date { CalendarTests.date(s) }

    // MARK: Docs and auth

    @Test func docsCarryRulesAndInstructionsOnlyWithToken() {
        api.instructions = "Meetings auf #intern buchen."
        let open = call("GET", "/", token: "wrong").1 as! String
        #expect(open.contains("Regeln für dich als Agent"))
        #expect(open.contains("<token>") && !open.contains(api.token))
        #expect(!open.contains("Meetings auf #intern"))
        let docs = call("GET", "/").1 as! String
        #expect(docs.contains("Bearer \(api.token)"))
        #expect(docs.contains("Hinweise des Nutzers") && docs.contains("Meetings auf #intern buchen."))
        #expect(docs.contains(TimeZone.current.identifier))
        api.instructions = "  \n"
        #expect(!(call("GET", "/").1 as! String).contains("Hinweise des Nutzers"))
        #expect(call("GET", "/api/entries", token: "wrong").0 == 401)
        #expect(call("GET", "/nope").0 == 404)
    }

    // MARK: Entries

    @Test func oneEntryPerMinute() {
        let created = call("POST", "/api/entries", ["date": "2026-11-09", "time": "08:00", "text": "#api Tests"])
        #expect(created.0 == 201)
        #expect(object(created)["id"] as? String == "2026-11-09T08:00")
        // The same minute again, also with another activity: 409 with the existing entry.
        let again = call("POST", "/api/entries", ["date": "2026-11-09", "time": "08:00", "label": "webshop"])
        #expect(again.0 == 409)
        #expect((object(again)["existing"] as? [String: Any])?["label"] as? String == "api")
        #expect(store.entries.count == 1)
        #expect(object(created)["newLabel"] as? Bool == true)
        let known = call("POST", "/api/entries", ["date": "2026-11-09", "time": "08:30", "label": "api"])
        #expect(object(known)["newLabel"] == nil)
        call("DELETE", "/api/entries/2026-11-09T08:30")
        // Moving another entry onto it: 409 as well, nothing changed.
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "09:00", "label": "webshop"])
        #expect(call("PATCH", "/api/entries/2026-11-09T09:00", ["time": "08:00"]).0 == 409)
        #expect(store.entries.map(\.text) == ["#api Tests", "#webshop"])
        // PATCH keeps what is not given; text wins over label.
        let patched = object(call("PATCH", "/api/entries/2026-11-09T09:00", ["description": "Checkout"]))
        #expect(patched["text"] as? String == "#webshop Checkout")
        #expect(call("PATCH", "/api/entries/2026-11-09T09:00", ["label": "x", "text": "#y z"]).0 == 200)
        #expect(store.entries.last?.text == "#y z")
        #expect(call("PATCH", "/api/entries/2026-11-09T09:00", ["text": " "]).0 == 400)
        #expect(call("DELETE", "/api/entries/2026-11-09T09:00").0 == 200)
        #expect(call("DELETE", "/api/entries/2026-11-09T09:00").0 == 404)
        #expect(call("GET", "/api/entries/2026-11-09T08:00").0 == 405)
    }

    @Test func entryFieldsAndRanges() {
        call("POST", "/api/entries", ["date": "2026-11-06", "time": "00:00", "label": "urlaub"])
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "08:00", "label": "api"])
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "12:00", "text": "pause"])
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "12:30", "label": "api"])
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "17:00", "text": "feierabend"])
        let week = list(call("GET", "/api/entries?from=2026-11-06&to=2026-11-09"))
        #expect(week.map { $0["kind"] as? String } == ["work", "work", "pause", "work", "feierabend"])
        #expect(week[0]["absence"] as? String == "vacation" && week[0]["open"] as? Bool == true)
        #expect(week[1]["absence"] == nil && week[1]["minutes"] as? Int == 240)
        #expect(call("GET", "/api/entries?from=2026-11-09&to=2026-11-06").0 == 400)
        #expect(call("GET", "/api/entries?from=2025-01-01&to=2026-11-09").0 == 400)
        #expect(call("GET", "/api/report?from=2025-11-09&to=2026-11-09").0 == 200)   // 366 days
        #expect(call("GET", "/api/absences?from=2026-11-01&to=2026-11-30").1 as? [[String: String]]
            == [["date": "2026-11-06", "kind": "vacation"]])
        #expect(call("GET", "/api/entries?from=gestern").0 == 400)
    }

    @Test func monthStatsLikeTheCalendar() {
        for (day, start, end) in [("2026-10-05", "08:00", "16:00"), ("2026-10-06", "09:00", "17:30")] {
            call("POST", "/api/entries", ["date": day, "time": start, "label": "api"])
            call("POST", "/api/entries", ["date": day, "time": "12:00", "text": "pause"])
            call("POST", "/api/entries", ["date": day, "time": "12:30", "label": "api"])
            call("POST", "/api/entries", ["date": day, "time": end, "text": "feierabend"])
        }
        call("POST", "/api/entries", ["date": "2026-10-07", "time": "08:00", "label": "krank"])
        let s = object(call("GET", "/api/stats?month=2026-10"))
        #expect(s["from"] as? String == "2026-10-01" && s["to"] as? String == "2026-10-31")
        #expect(s["workdays"] as? Int == 2)
        #expect(s["workedMinutes"] as? Int == 450 + 480)
        #expect(s["averageStart"] as? String == "08:30" && s["averageEnd"] as? String == "16:45")
        #expect(s["breakMinutes"] as? Int == 60)
        #expect(s["absences"] as? [String: Int] == ["sick": 1])
        #expect((s["labels"] as? [[String: Any]])?.first?["label"] as? String == "api")
        #expect(call("GET", "/api/stats?month=2026-13").0 == 400)
        #expect(call("GET", "/api/stats?month=2026-1").0 == 400)
        #expect(call("GET", "/api/export?month=2026-1").0 == 400)
        #expect(call("GET", "/api/entries?from=2026-1-5").0 == 400)
    }

    // MARK: Labels

    @Test func renameAndDeleteLabels() {
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "08:00", "text": "#internal Mail"])
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "10:00", "text": "#internal Sync"])
        call("PUT", "/api/labels/internal", ["account": "Intern", "project": "Allgemein"])
        let dry = object(call("POST", "/api/labels/internal/rename", ["to": "intern", "dryRun": true]))
        #expect(dry["renamedEntries"] as? Int == 2 && dry["dryRun"] as? Bool == true)
        #expect(store.entries.map(\.label) == ["internal", "internal"])
        let renamed = call("POST", "/api/labels/internal/rename", ["to": "#intern"])
        #expect(renamed.0 == 200)
        #expect(object(renamed)["label"] as? String == "intern" && object(renamed)["renamedEntries"] as? Int == 2)
        #expect(object(renamed)["account"] as? String == "Intern" && object(renamed)["merged"] as? Bool == false)
        #expect(store.entries.map(\.text) == ["#intern Mail", "#intern Sync"])
        let labels = list(call("GET", "/api/labels")).compactMap { $0["label"] as? String }
        #expect(labels.contains("intern") && !labels.contains("internal"))
        #expect(call("POST", "/api/labels/internal/rename", ["to": "x"]).0 == 404)
        #expect(call("POST", "/api/labels/intern/rename", ["to": "intern"]).0 == 400)
        // Only an unused label can go.
        #expect(object(call("DELETE", "/api/labels/intern"))["entries"] as? Int == 2)
        call("PUT", "/api/labels/alt", ["account": "Alt"])
        #expect(call("DELETE", "/api/labels/alt").0 == 200)
        #expect(store.labelInfo["alt"] == nil)
        #expect(call("DELETE", "/api/labels/alt").0 == 404)
        #expect(call("PUT", "/api/labels/intern", ["counts": 1]).0 == 400)
        #expect(call("PUT", "/api/labels/intern", ["kind": "holiday"]).0 == 400)
    }

    @Test func wrongTypesAndHugeRangesAreRejected() {
        for body: [String: Any] in [["date": 20261116, "label": "urlaub"], ["date": NSNull(), "label": "urlaub"],
                                    ["time": 900, "label": "api"], ["label": 5], ["text": ["#api"]]] {
            #expect(call("POST", "/api/entries", body).0 == 400, "\(body)")
        }
        #expect(store.entries.isEmpty)
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "08:00", "label": "api"])
        #expect(call("PATCH", "/api/entries/2026-11-09T08:00", ["time": 900]).0 == 400)
        #expect(call("PUT", "/api/labels/api", ["account": 5]).0 == 400)
        #expect(call("POST", "/api/days/copy", ["from": "2026-11-09", "to": "2026-11-10", "weekends": 1]).0 == 400)
        // Checked before the days are built: no hang.
        #expect(call("POST", "/api/days/copy", ["from": "2026-11-09", "to": "2026-11-10", "until": "9999-12-31"]).0 == 400)
        #expect(call("POST", "/api/days/copy", ["from": "2026-11-09", "to": "2026-11-10", "until": 5]).0 == 400)
        #expect(call("POST", "/api/days/copy", ["from": "2026-11-09", "to": "2026-11-10", "mode": "merge"]).0 == 400)
    }

    @Test func labelsInThePathAreTakenLikeTypedOnes() {
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "08:00", "text": "#intern Mail"])
        #expect(object(call("PUT", "/api/labels/%23Intern", ["account": "Intern"]))["label"] as? String == "intern")
        #expect(store.labelInfo["intern"]?.account == "Intern" && store.labelInfo["#Intern"] == nil)
        #expect(call("DELETE", "/api/labels/%23").0 == 400)
    }

    @Test func applyingAProposalKeepsOneEntryPerMinute() {
        var applied = 0
        state.applyProposal = { _, _ in applied += 1 }
        let task = Entry(date: at("2026-11-09 08:00"), text: "#api")
        call("POST", "/api/entries", ["date": "2026-11-09", "time": "12:40", "label": "webshop"])
        let pause = Proposal.pause(from: at("2026-11-09 12:05"), to: at("2026-11-09 12:40"), resume: task)
        state.proposal = pause
        let r = call("POST", "/api/proposal", ["id": pause.id, "action": "apply"])
        #expect(r.0 == 409 && applied == 0)
        state.proposal = nil
    }

    @Test func pathSegmentsAreDecodedOneByOne() {
        let req = HTTPRequest.parse(Data("PUT /api/labels/a%2Fb%20c HTTP/1.1\r\n\r\n".utf8))!
        #expect(req.segments == ["api", "labels", "a/b c"])
    }

    // MARK: Settings

    @Test func settingsAreCheckedBeforeAnythingChanges() {
        defer { restore() }
        let before = object(call("GET", "/api/settings"))
        #expect((before["reminder"] as? [String: Any])?["minutes"] as? Int == state.reminder.minutes)
        let ok = call("PATCH", "/api/settings", ["reminder": ["minutes": 45, "from": "07:30"], "presence": ["awayMinutes": 5]])
        #expect(ok.0 == 200)
        #expect(state.reminder.minutes == 45 && state.reminder.from == 7 * 60 + 30 && state.awayMinutes == 5)
        // One bad field: nothing at all changes.
        for bad: [String: Any] in [["reminder": ["minutes": 44], "presence": ["awayMinutes": 2]],
                                   ["presence": ["awayMinutes": true]],
                                   ["presence": ["autoBreaks": 1]],
                                   ["reminder": ["from": "18:00", "to": "08:00"]],
                                   ["reminder": ["minutes": 45.5]],
                                   ["presence": ["colour": "red"]],
                                   ["token": "x"]] {
            #expect(call("PATCH", "/api/settings", bad).0 == 400, "\(bad)")
        }
        #expect(state.reminder.minutes == 45 && state.awayMinutes == 5)
        let covers = !state.timelineCoversPresence
        #expect(call("PATCH", "/api/settings", ["timeline": ["coversPresence": covers, "minutes": 15]]).0 == 200)
        #expect(state.timelineCoversPresence == covers && state.timelineMinutes == 15)
        #expect(call("PATCH", "/api/settings", ["timeline": ["minutes": 7]]).0 == 400)
        #expect(call("PATCH", "/api/settings", ["timeline": ["coversPresence": "yes"]]).0 == 400)
        #expect(call("PATCH", "/api/settings", ["presence": ["timeline": true]]).0 == 400)
        #expect(state.timelineMinutes == 15)
    }

    // MARK: Proposals

    @Test func proposalsCanBeAppliedAndDismissed() {
        var applied: [(Proposal, String?)] = []
        var dismissed: [Proposal] = []
        state.applyProposal = { applied.append(($0, $1)) }
        state.dismissProposal = { dismissed.append($0) }
        #expect(call("GET", "/api/proposal").1 is NSNull)
        #expect(call("POST", "/api/proposal", ["id": "x", "action": "apply"]).0 == 404)

        let task = Entry(date: at("2026-11-09 08:00"), text: "#api")
        let pause = Proposal.pause(from: at("2026-11-09 12:05"), to: at("2026-11-09 12:40"), resume: task)
        state.proposal = pause
        let shown = object(call("GET", "/api/proposal"))
        #expect(shown["type"] as? String == "pause" && shown["from"] as? String == "12:05" && shown["to"] as? String == "12:40")
        #expect((shown["entries"] as? [[String: String]])?.map { $0["text"] } == ["pause", "#api"])
        #expect(call("POST", "/api/proposal", ["id": "old", "action": "apply"]).0 == 409)
        #expect(call("POST", "/api/proposal", ["id": pause.id, "action": "apply", "text": "#x"]).0 == 400)
        #expect(call("POST", "/api/proposal", ["id": pause.id, "action": "maybe"]).0 == 400)
        #expect(call("POST", "/api/proposal", ["id": pause.id, "action": "dismiss"]).0 == 200)
        #expect(dismissed == [pause])

        // A start without a label needs the text.
        let start = Proposal.start(at: at("2026-11-09 08:10"), label: nil)
        state.proposal = start
        #expect(call("POST", "/api/proposal", ["id": start.id, "action": "apply"]).0 == 400)
        #expect(call("POST", "/api/proposal", ["id": start.id, "action": "apply", "text": "#api Tests"]).0 == 200)
        #expect(applied.count == 1 && applied[0].0 == start && applied[0].1 == "#api Tests")
        state.proposal = nil
    }

    // MARK: Presence and export

    @Test func activityEndsNow() {
        let now = at("2026-11-10 10:17")
        api.now = { now }
        api.presence = { _ in [DateInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(600)),
                               DateInterval(start: now.addingTimeInterval(60), end: now.addingTimeInterval(900))] }
        let spans = list(call("GET", "/api/activity"))
        #expect(spans.count == 1)
        #expect(spans.first?["to"] as? String == Fmt.time.string(from: now))
        #expect(call("GET", "/api/activity?date=x").0 == 400)
    }

    @Test func exportScriptCanBeRead() {
        let r = object(call("GET", "/api/export/script"))
        #expect((r["script"] as? String)?.contains("function transform") == true)
        #expect(r["custom"] as? Bool == false)
    }
}
