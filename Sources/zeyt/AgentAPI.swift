import AppKit

/// Local REST API so that a coding agent can read and edit the log.
@MainActor
final class AgentAPI: ObservableObject {
    static let port: UInt16 = 7239
    /// Longest range a request may cover.
    static let maxDays = 366

    @Published private(set) var error: String?
    @Published private(set) var token: String
    /// The user's own instructions for agents (settings), part of the docs at GET /.
    @Published var instructions: String {
        didSet { defaults.set(instructions, forKey: "agentInstructions") }
    }

    private let store: EntryStore
    /// Settings and proposals; set by the app delegate.
    weak var state: AppState?
    /// Presence spans of a day (`PresenceTracker`).
    var presence: (Date) -> [DateInterval] = { _ in [] }
    /// The current time (tests set a fixed one).
    var now: () -> Date = Date.init
    private let server = HTTPServer(port: AgentAPI.port)
    private let defaults: UserDefaults

    var baseURL: String { "http://127.0.0.1:\(Self.port)" }

    var enabled: Bool {
        get { defaults.bool(forKey: "agentEnabled") }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "agentEnabled")
            newValue ? server.start() : server.stop()
            if !newValue { error = nil }
        }
    }

    init(store: EntryStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        token = defaults.string(forKey: "agentToken") ?? ""
        instructions = defaults.string(forKey: "agentInstructions") ?? ""
        if token.isEmpty { regenerateToken() }
        server.handler = { [unowned self] in self.handle($0) }
        server.onStateChange = { [unowned self] in self.error = $0 }
        if enabled { server.start() }
    }

    /// Switches the API on, or retries if it failed to start (e.g. busy port).
    func ensureRunning() {
        if !enabled { enabled = true } else if !server.isRunning { error = nil; server.start() }
    }

    func regenerateToken() {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        token = String((0..<32).map { _ in chars.randomElement()! })
        defaults.set(token, forKey: "agentToken")
    }

    /// Everything else is in the docs, so the prompt stays one command.
    var prompt: String {
        """
        Verbinde dich mit zeyt, meiner Zeiterfassungs-App in der Menüleiste dieses Macs. Die Anleitung bekommst du mit:

        curl -s -H "Authorization: Bearer \(token)" \(baseURL)/
        """
    }

    // MARK: Routing

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard !req.malformed else { return .error("malformed request target (URL)", status: 400) }
        let authorized = req.headers["authorization"] == "Bearer \(token)"
        if req.method == "GET" && req.segments.isEmpty { return .text(docs(authorized: authorized)) }
        guard authorized else {
            return .error("missing or wrong token (Authorization: Bearer <token>)", status: 401)
        }
        let parts = req.segments
        guard parts.first == "api" else { return .error("unknown endpoint, see GET /", status: 404) }
        let path = Array(parts.dropFirst())
        // Paths with a parameter: /api/entries/<id>, /api/labels/<label>[/rename]. A label in the path is
        // taken like a typed one ("#Intern" = "intern"), so it matches the entries.
        if path.count >= 2, path[0] == "labels", Rules.tag(path[1]).isEmpty {
            return .error("label must not be empty", status: 400)
        }
        if path.count == 2, path[0] == "entries" {
            switch req.method {
            case "PATCH": return updateEntry(id: path[1], req)
            case "DELETE": return deleteEntry(id: path[1])
            default: return .error("use PATCH or DELETE", status: 405)
            }
        }
        if path.count == 2, path[0] == "labels" {
            switch req.method {
            case "PUT": return putLabel(Rules.tag(path[1]), req)
            case "DELETE": return deleteLabel(Rules.tag(path[1]))
            default: return .error("use PUT or DELETE", status: 405)
            }
        }
        if path.count == 3, path[0] == "labels", path[2] == "rename" {
            return req.method == "POST" ? renameLabel(Rules.tag(path[1]), req) : .error("use POST", status: 405)
        }
        switch (req.method, path.joined(separator: "/")) {
        case ("GET", "entries"): return listEntries(req)
        case ("POST", "entries"): return createEntry(req)
        case ("GET", "summary"): return summary(req)
        case ("GET", "stats"): return stats(req)
        case ("GET", "absences"): return listAbsences(req)
        case ("GET", "activity"): return activity(req)
        case ("GET", "labels"): return .json(store.labels.map(labelJSON))
        case ("GET", "report"): return report(req)
        case ("POST", "days/copy"): return copyDay(req)
        case ("GET", "export"): return export(req)
        case ("GET", "export/script"):
            return .json(["script": ExportScript.current(in: defaults), "custom": ExportScript.isCustom(in: defaults)])
        case ("GET", "proposal"): return .json(state?.proposal.map(proposalJSON) ?? NSNull())
        case ("POST", "proposal"): return answerProposal(req)
        case ("GET", "settings"): return settings()
        case ("PATCH", "settings"): return patchSettings(req)
        case ("POST", "toast"):
            guard let message = req.json?["message"] as? String, !message.isEmpty else {
                return .error("body must be {\"message\": \"...\"}", status: 400)
            }
            Toast.show(message)
            return .json(["ok": true])
        default: return .error("unknown endpoint, see GET /", status: 404)
        }
    }

    // MARK: Entries

    private func listEntries(_ req: HTTPRequest) -> HTTPResponse {
        let (range, failure) = Self.range(req)
        guard let range else { return failure! }
        let byDay = store.entriesByDay(from: range.from, to: range.to)
        let now = Date()
        let result = Self.days(range).flatMap { Block.compute(byDay[$0] ?? [], now: now).map(json) }
        return .json(result)
    }

    private func createEntry(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.json else { return .error("body must be JSON", status: 400) }
        if let bad = Self.nonString(body, ["date", "time", "text", "label", "description"]) { return bad }
        guard let date = Self.date(from: body, base: now()) else {
            return .error("date must be YYYY-MM-DD, time must be HH:mm", status: 400)
        }
        let text = Self.text(from: body, base: nil)
        guard !text.isEmpty else { return .error("label or description required", status: 400) }
        // The id is the start minute: a second entry there could not be told apart (also not in the hour
        // that repeats when the clocks go back).
        if let existing = entry(withID: Self.idFormatter.string(from: date)) {
            return occupied(existing)
        }
        let knownBefore = Set(store.labels)
        guard let entry = store.add(date: date, text: text) else {
            return .json(["ok": true, "note": "same activity is already running, nothing added"])
        }
        var result = json(entry)
        // A typo would silently start a new label: say so.
        if !entry.label.isEmpty, !knownBefore.contains(entry.label) { result["newLabel"] = true }
        return .json(result, status: 201)
    }

    private func updateEntry(id: String, _ req: HTTPRequest) -> HTTPResponse {
        guard let entry = find(id) else { return .error("no entry with id \(id)", status: 404) }
        guard let body = req.json else { return .error("body must be JSON", status: 400) }
        if let bad = Self.nonString(body, ["date", "time", "text", "label", "description"]) { return bad }
        guard let date = Self.date(from: body, base: entry.date) else {
            return .error("date must be YYYY-MM-DD, time must be HH:mm", status: 400)
        }
        if let other = self.entry(withID: Self.idFormatter.string(from: date), except: entry) {
            return occupied(other)
        }
        let text = Self.text(from: body, base: entry)
        guard !text.isEmpty else { return .error("label or description required", status: 400) }
        let updated = Entry(id: entry.id, date: date, text: text)
        store.update(updated)
        return .json(json(updated))
    }

    private func occupied(_ entry: Entry) -> HTTPResponse {
        let id = Self.idFormatter.string(from: entry.date)
        return .json(["error": "an entry already starts at \(id); change it with PATCH /api/entries/\(id) or use another time",
                      "existing": json(entry)], status: 409)
    }

    private func deleteEntry(id: String) -> HTTPResponse {
        guard let entry = find(id) else { return .error("no entry with id \(id)", status: 404) }
        store.delete(entry)
        return .json(["ok": true])
    }

    // MARK: Labels

    private func putLabel(_ label: String, _ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.json else { return .error("body must be JSON", status: 400) }
        if let bad = Self.nonString(body, ["account", "project", "kind"]) { return bad }
        var info = store.labelInfo[label] ?? LabelInfo()
        if let a = body["account"] as? String { info.account = a }
        if let p = body["project"] as? String { info.project = p }
        if let k = body["kind"] as? String {
            guard let kind = LabelKind(rawValue: k) else {
                return .error("kind must be work, vacation, sick, child-sick or absence", status: 400)
            }
            info.kind = kind
            info.counts = nil
        }
        if let c = body["counts"] {
            guard let b = Self.jsonBool(c) else { return .error("counts must be true or false", status: 400) }
            info.counts = b
        }
        store.setInfo(info, for: label)
        return .json(labelJSON(label))
    }

    private func known(_ label: String) -> Bool { store.isUsed(label) > 0 || store.labelInfo[label] != nil }

    private func renameLabel(_ label: String, _ req: HTTPRequest) -> HTTPResponse {
        guard known(label) else { return .error("no label \(label)", status: 404) }
        guard let to = req.json?["to"] as? String else { return .error("body must be {\"to\": \"new-label\"}", status: 400) }
        let target = Rules.tag(to)
        guard !target.isEmpty, target != label else { return .error("to must be a different label", status: 400) }
        let merged = known(target)
        let count = store.isUsed(label)
        if let dry = req.json?["dryRun"], Self.jsonBool(dry) == true {
            return .json(["label": target, "renamedEntries": count, "merged": merged, "dryRun": true])
        }
        let new = store.renameLabel(label, to: to)
        var result = labelJSON(new)
        result["renamedEntries"] = count
        result["merged"] = merged
        return .json(result)
    }

    private func deleteLabel(_ label: String) -> HTTPResponse {
        guard known(label) else { return .error("no label \(label)", status: 404) }
        let used = store.isUsed(label)
        guard used == 0 else {
            return .json(["error": "label is used by \(used) entries; rename it or change the entries first",
                          "entries": used], status: 409)
        }
        store.removeLabelInfo(label)
        return .json(["ok": true])
    }

    private func labelJSON(_ label: String) -> [String: Any] {
        let info = store.labelInfo[label] ?? LabelInfo()
        return ["label": label, "account": info.account, "project": info.project,
                "kind": store.kind(label).rawValue, "counts": store.counts(label)]
    }

    // MARK: Figures

    private func listAbsences(_ req: HTTPRequest) -> HTTPResponse {
        let (range, failure) = Self.range(req)
        guard let range else { return failure! }
        let result: [[String: Any]] = Self.days(range).compactMap { day in
            store.absence(on: day).map { ["date": Self.dayFormatter.string(from: day), "kind": $0.rawValue] }
        }
        return .json(result)
    }

    private func activity(_ req: HTTPRequest) -> HTTPResponse {
        guard let day = req.query["date"].map(Self.parseDay) ?? Calendar.current.startOfDay(for: Date()) else {
            return .error("date must be YYYY-MM-DD", status: 400)
        }
        // The current span ends now, not at the last sample's grace period.
        let now = now()
        let spans = presence(day).compactMap { s -> DateInterval? in
            s.start < now ? DateInterval(start: s.start, end: min(s.end, now)) : nil
        }
        return .json(spans.map { ["from": Fmt.time.string(from: $0.start), "to": Fmt.time.string(from: $0.end),
                                  "minutes": Int($0.duration / 60)] })
    }

    /// Like the calendar's sidebar: workdays, average start and end, breaks, per label, absences.
    private func stats(_ req: HTTPRequest) -> HTTPResponse {
        let range: (from: Date, to: Date)
        if let month = req.query["month"] {
            guard let day = Self.parseMonth(month) else { return .error("month must be YYYY-MM", status: 400) }
            let days = MonthGrid.days(of: day)
            range = (days.first!, days.last!)
        } else {
            let (r, failure) = Self.range(req)
            guard let r else { return failure! }
            range = r
        }
        let uncounted: Set<String> = AppState.uncountedEnabledSetting ? Set(store.uncounted) : []
        let s = PeriodStats.make(days: Self.days(range), entries: store.entriesByDay(from: range.from, to: range.to),
                                 now: Date(), uncounted: uncounted)
        func clock(_ t: TimeInterval?) -> Any { t.map { String(format: "%02d:%02d", Int($0) / 3600, Int($0) % 3600 / 60) } ?? NSNull() }
        return .json([
            "from": Self.dayFormatter.string(from: range.from), "to": Self.dayFormatter.string(from: range.to),
            "workdays": s.workdays, "workedMinutes": Int(s.worked / 60), "workedBT": Self.bt(s.worked),
            "minutesPerWorkday": Int(s.perWorkday / 60), "averageStart": clock(s.start), "averageEnd": clock(s.end),
            "breakMinutes": Int(s.paused / 60),
            "labels": s.labels.map { l -> [String: Any] in
                let info = store.labelInfo[l.label] ?? LabelInfo()
                return ["label": l.label, "account": info.account, "project": info.project, "minutes": Int(l.seconds / 60)]
            },
            "absences": Dictionary(uniqueKeysWithValues: s.absences.map { ($0.key.rawValue, $0.value) }),
        ])
    }

    /// {"from": day, "to": day | [days] | "until"?: day, "weekends"?: bool, "mode"?: "replace"|"append"|"empty"}
    private func copyDay(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.json, let from = (body["from"] as? String).flatMap(Self.parseDay) else {
            return .error("from must be YYYY-MM-DD", status: 400)
        }
        let source = store.entries(on: from)
        guard let items = DayText.parse(DayText.make(source)) else { return .error("from has no entries", status: 400) }
        var days: [Date]
        if let list = body["to"] as? [String] {
            days = list.compactMap(Self.parseDay)
            guard days.count == list.count else { return .error("to must be YYYY-MM-DD", status: 400) }
        } else if let single = (body["to"] as? String).flatMap(Self.parseDay) {
            if let bad = Self.nonString(body, ["until"]) { return bad }
            guard body["until"] == nil || (body["until"] as? String).flatMap(Self.parseDay) != nil else {
                return .error("until must be YYYY-MM-DD", status: 400)
            }
            let until = (body["until"] as? String).flatMap(Self.parseDay) ?? single
            guard until >= single else { return .error("until must not be before to", status: 400) }
            guard Calendar.current.dateComponents([.day], from: single, to: until).day! < Self.maxDays else {
                return .error("at most \(Self.maxDays) days at once", status: 400)
            }
            var weekends = until == single
            if let w = body["weekends"] {
                guard let b = Self.jsonBool(w) else { return .error("weekends must be true or false", status: 400) }
                weekends = b
            }
            days = DayText.days(from: single, to: until, weekends: weekends)
        } else {
            return .error("to must be YYYY-MM-DD or a list of them", status: 400)
        }
        guard days.count <= Self.maxDays else { return .error("at most \(Self.maxDays) days at once", status: 400) }
        let modes: [String: EntryStore.PasteMode] = ["replace": .replace, "append": .append, "empty": .emptyOnly]
        let filled = days.filter { !store.entries(on: $0).isEmpty }.map { Self.dayFormatter.string(from: $0) }
        if let m = body["mode"] as? String, modes[m] == nil {
            return .error("mode must be replace, append or empty", status: 400)
        }
        guard let mode = (body["mode"] as? String).map({ modes[$0]! }) ?? (filled.isEmpty ? .append : nil) else {
            return .json(["error": "target days already have entries; set mode to replace, append or empty",
                          "filled": filled], status: 409)
        }
        let result = store.paste(items, on: days, mode: mode)
        return .json(["ok": true, "added": result.added.count, "removed": result.removed.count,
                      "days": days.map { Self.dayFormatter.string(from: $0) }], status: 201)
    }

    /// Runs the export script of the settings on one month.
    private func export(_ req: HTTPRequest) -> HTTPResponse {
        let month = req.query["month"] ?? String(Self.dayFormatter.string(from: Date()).prefix(7))
        guard let day = Self.parseMonth(month) else { return .error("month must be YYYY-MM", status: 400) }
        switch Export.run(month: day, store: store) {
        case .failure(let f): return .error("export script failed: \(f.message)", status: 500)
        case .success(let o):
            return .json(["month": month, "fileName": (o.fileName as Any?) ?? NSNull(), "fileExtension": o.fileExtension,
                          "warnings": o.warnings, "output": o.text])
        }
    }

    private func report(_ req: HTTPRequest) -> HTTPResponse {
        let (range, failure) = Self.range(req)
        guard let range else { return failure! }
        let worked = store.worked(from: range.from, to: range.to, now: Date())
        let labels = worked.sorted { $0.value > $1.value }.map { label, seconds -> [String: Any] in
            let info = store.labelInfo[label] ?? LabelInfo()
            return ["label": label, "account": info.account, "project": info.project, "minutes": Int(seconds / 60)]
        }
        var accounts: [String: Int] = [:]
        for (label, seconds) in worked { accounts[store.labelInfo[label]?.account ?? "", default: 0] += Int(seconds / 60) }
        return .json(["from": Self.dayFormatter.string(from: range.from), "to": Self.dayFormatter.string(from: range.to),
                      "labels": labels, "accounts": accounts])
    }

    private func summary(_ req: HTTPRequest) -> HTTPResponse {
        guard let day = req.query["date"].map(Self.parseDay) ?? Calendar.current.startOfDay(for: Date()) else {
            return .error("date must be YYYY-MM-DD", status: 400)
        }
        let now = Date()
        let uncounted: Set<String> = AppState.uncountedEnabledSetting ? Set(store.uncounted) : []
        let dayTotal = Block.worked(Block.compute(store.entries(on: day), now: now), uncounted: uncounted)
        let cal = Calendar(identifier: .iso8601)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: day)!.start
        let weekTotal = (0..<7).reduce(0.0) { sum, offset in
            let d = cal.date(byAdding: .day, value: offset, to: weekStart)!
            return sum + Block.worked(Block.compute(store.entries(on: d), now: now), uncounted: uncounted)
        }
        var weekAbsences: [String: Int] = [:]
        for offset in 0..<7 {
            let d = cal.date(byAdding: .day, value: offset, to: weekStart)!
            if let a = store.absence(on: d) { weekAbsences[a.rawValue, default: 0] += 1 }
        }
        return .json([
            "absence": store.absence(on: day)?.rawValue ?? NSNull(),
            "weekAbsences": weekAbsences,
            "date": Self.dayFormatter.string(from: day),
            "dayMinutes": Int(dayTotal / 60),
            "dayBT": Self.bt(dayTotal),
            "week": cal.component(.weekOfYear, from: day),
            "weekMinutes": Int(weekTotal / 60),
            "weekBT": Self.bt(weekTotal),
        ])
    }

    // MARK: Proposals

    private func proposalJSON(_ p: Proposal) -> [String: Any] {
        var d: [String: Any] = [
            "id": p.id,
            "entries": p.entries.map { ["date": Self.dayFormatter.string(from: $0.0), "time": Fmt.time.string(from: $0.0),
                                        "text": $0.1] },
        ]
        switch p {
        case .start(let at, let label):
            d["type"] = "start"
            d["date"] = Self.dayFormatter.string(from: at)
            d["time"] = Fmt.time.string(from: at)
            d["label"] = label ?? NSNull()
        case .pause(let from, let to, let resume):
            d["type"] = "pause"
            d["date"] = Self.dayFormatter.string(from: from)
            d["from"] = Fmt.time.string(from: from)
            d["to"] = Fmt.time.string(from: to)
            d["resume"] = resume.text
        case .endOfDay(let at):
            d["type"] = "endOfDay"
            d["date"] = Self.dayFormatter.string(from: at)
            d["time"] = Fmt.time.string(from: at)
        }
        return d
    }

    /// {"id": "...", "action": "apply" | "dismiss", "text"?: "#label comment"} (text only for a start).
    private func answerProposal(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.json, let id = body["id"] as? String, let action = body["action"] as? String else {
            return .error("body must be {\"id\": \"...\", \"action\": \"apply\" | \"dismiss\"}", status: 400)
        }
        guard let state, let p = state.proposal else { return .error("no proposal right now", status: 404) }
        guard p.id == id else {
            return .json(["error": "the proposal has changed", "proposal": proposalJSON(p)], status: 409)
        }
        let text = (body["text"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        switch action {
        case "apply":
            var isStart = false
            if case .start(_, let label) = p {
                isStart = true
                if label == nil, text == nil {
                    return .error("this start has no label to continue; send \"text\": \"#label comment\"", status: 400)
                }
            }
            if text != nil, !isStart { return .error("text is only for a start proposal", status: 400) }
            for (date, _) in p.entries {
                if let existing = entry(withID: Self.idFormatter.string(from: date)) { return occupied(existing) }
            }
            let day = p.entries[0].0
            state.applyProposal(p, text)
            return .json(["ok": true, "entries": Block.compute(store.entries(on: day), now: Date()).map(json)])
        case "dismiss":
            state.dismissProposal(p)
            return .json(["ok": true])
        default:
            return .error("action must be apply or dismiss", status: 400)
        }
    }

    // MARK: Settings

    private func settings() -> HTTPResponse {
        guard let state else { return .error("settings not available", status: 500) }
        let r = state.reminder
        func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return .json([
            "reminder": ["enabled": r.enabled, "minutes": r.minutes, "from": hm(r.from), "to": hm(r.to),
                         "weekdaysOnly": r.weekdaysOnly],
            "presence": ["enabled": state.presenceEnabled, "awayMinutes": state.awayMinutes,
                         "microphone": state.microphoneCounts, "proposeStart": state.proposeStart,
                         "proposeBreaks": state.proposeBreaks, "breakMinutes": state.breakMinutes,
                         "autoBreaks": state.autoBreaks, "proposeEndOfDay": state.proposeEndOfDay,
                         "roundMinutes": state.roundMinutes, "notifications": state.proposalNotifications,
                         "remindersFollowPresence": state.remindersFollowPresence, "keepDays": state.presenceKeepDays,
                         "timeline": state.timelineCoversPresence],
        ])
    }

    /// Partial update of `settings()`; all fields are checked before anything changes.
    private func patchSettings(_ req: HTTPRequest) -> HTTPResponse {
        guard let state else { return .error("settings not available", status: 500) }
        guard let body = req.json else { return .error("body must be JSON", status: 400) }
        let unknownTop = Set(body.keys).subtracting(["reminder", "presence"])
        guard unknownTop.isEmpty else { return .error("unknown fields: \(unknownTop.sorted()); use reminder, presence", status: 400) }
        var changes: [() -> Void] = []
        var errors: [String] = []

        func bool(_ group: [String: Any], _ key: String, _ apply: @escaping (Bool) -> Void) {
            guard let v = group[key] else { return }
            if let b = Self.jsonBool(v) { changes.append { apply(b) } } else { errors.append("\(key) must be true or false") }
        }
        func choice(_ group: [String: Any], _ key: String, _ allowed: [Int], _ apply: @escaping (Int) -> Void) {
            guard let v = group[key] else { return }
            if let n = Self.jsonInt(v), allowed.contains(n) { changes.append { apply(n) } } else {
                errors.append("\(key) must be one of \(allowed.map(String.init).joined(separator: ", "))")
            }
        }
        func minutes(_ s: Any?) -> Int? {
            guard let s = s as? String else { return nil }
            let p = s.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
            return p[0] * 60 + p[1]
        }

        if let r = body["reminder"] {
            guard let r = r as? [String: Any] else { return .error("reminder must be an object", status: 400) }
            let unknown = Set(r.keys).subtracting(["enabled", "minutes", "from", "to", "weekdaysOnly"])
            if !unknown.isEmpty { errors.append("unknown reminder fields: \(unknown.sorted())") }
            var reminder = state.reminder
            if let v = r["enabled"] { if let b = Self.jsonBool(v) { reminder.enabled = b } else { errors.append("enabled must be true or false") } }
            if let v = r["weekdaysOnly"] { if let b = Self.jsonBool(v) { reminder.weekdaysOnly = b } else { errors.append("weekdaysOnly must be true or false") } }
            if let v = r["minutes"] {
                if let n = Self.jsonInt(v), Reminder.intervals.contains(n) { reminder.minutes = n } else {
                    errors.append("minutes must be one of \(Reminder.intervals.map(String.init).joined(separator: ", "))")
                }
            }
            if r["from"] != nil { if let m = minutes(r["from"]) { reminder.from = m } else { errors.append("from must be HH:mm") } }
            if r["to"] != nil { if let m = minutes(r["to"]) { reminder.to = m } else { errors.append("to must be HH:mm") } }
            if reminder.from >= reminder.to { errors.append("from must be before to") }
            changes.append { state.reminder = reminder }
        }
        if let p = body["presence"] {
            guard let p = p as? [String: Any] else { return .error("presence must be an object", status: 400) }
            let known = ["enabled", "awayMinutes", "microphone", "proposeStart", "proposeBreaks", "breakMinutes", "autoBreaks",
                         "proposeEndOfDay", "roundMinutes", "notifications", "remindersFollowPresence", "keepDays", "timeline"]
            let unknown = Set(p.keys).subtracting(known)
            if !unknown.isEmpty { errors.append("unknown presence fields: \(unknown.sorted())") }
            bool(p, "enabled") { state.presenceEnabled = $0 }
            choice(p, "awayMinutes", Presence.awayChoices) { state.awayMinutes = $0 }
            bool(p, "microphone") { state.microphoneCounts = $0 }
            bool(p, "proposeStart") { state.proposeStart = $0 }
            bool(p, "proposeBreaks") { state.proposeBreaks = $0 }
            choice(p, "breakMinutes", AppState.breakChoices) { state.breakMinutes = $0 }
            bool(p, "autoBreaks") { state.autoBreaks = $0 }
            bool(p, "proposeEndOfDay") { state.proposeEndOfDay = $0 }
            choice(p, "roundMinutes", AppState.roundChoices) { state.roundMinutes = $0 }
            bool(p, "notifications") { state.proposalNotifications = $0 }
            bool(p, "remindersFollowPresence") { state.remindersFollowPresence = $0 }
            choice(p, "keepDays", AppState.keepChoices) { state.presenceKeepDays = $0 }
            bool(p, "timeline") { state.timelineCoversPresence = $0 }
        }
        guard errors.isEmpty else { return .json(["error": errors.joined(separator: "; ")], status: 400) }
        changes.forEach { $0() }
        return settings()
    }

    // MARK: Helpers

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    /// Brutto-Tage (8 h), rounded to 2 decimals without float noise in the JSON.
    private static func bt(_ seconds: TimeInterval) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.2f", seconds / (8 * 3600)))
    }

    /// Exactly YYYY-MM-DD (the formatter alone also takes "2026-1-5").
    private static func parseDay(_ s: String) -> Date? {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? dayFormatter.date(from: s) : nil
    }

    private static func parseMonth(_ s: String) -> Date? {
        s.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil ? parseDay(s + "-01") : nil
    }

    /// JSON true/false only (JSONSerialization also lets 1 pass as true and true as 1).
    private static func jsonBool(_ v: Any) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// JSON whole numbers only, not true/false or 1.5.
    private static func jsonInt(_ v: Any) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded() else { return nil }
        return n.intValue
    }

    /// "from"/"to" of the query (default today, `to` defaults to `from`), at most `maxDays`.
    private static func range(_ req: HTTPRequest) -> ((from: Date, to: Date)?, HTTPResponse?) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let from = req.query["from"].map(parseDay) ?? today, let to = req.query["to"].map(parseDay) ?? from else {
            return (nil, .error("from/to must be YYYY-MM-DD", status: 400))
        }
        guard from <= to else { return (nil, .error("from must not be after to", status: 400)) }
        let days = Calendar.current.dateComponents([.day], from: from, to: to).day! + 1
        guard days <= maxDays else { return (nil, .error("at most \(maxDays) days per request", status: 400)) }
        return ((from, to), nil)
    }

    private static func days(_ range: (from: Date, to: Date)) -> [Date] {
        var result: [Date] = []
        var day = range.from
        while day <= range.to {
            result.append(day)
            day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    /// Combines optional "date" and "time" fields with the defaults taken from `base`.
    private static func date(from body: [String: Any], base: Date) -> Date? {
        let cal = Calendar.current
        var day = cal.startOfDay(for: base)
        if let s = body["date"] as? String {
            guard let d = parseDay(s) else { return nil }
            day = d
        }
        var hm = cal.dateComponents([.hour, .minute], from: base)
        if let s = body["time"] as? String {
            let p = s.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
            hm.hour = p[0]
            hm.minute = p[1]
        }
        return cal.date(bySettingHour: hm.hour!, minute: hm.minute!, second: 0, of: day)
    }

    /// "text" wins; otherwise label/description, falling back to the existing entry's parts.
    private static func text(from body: [String: Any], base: Entry?) -> String {
        if let text = body["text"] as? String { return text.trimmingCharacters(in: .whitespaces) }
        return Entry.compose(label: body["label"] as? String ?? base?.label ?? "",
                             description: body["description"] as? String ?? base?.title ?? "")
    }

    private func find(_ id: String) -> Entry? { entry(withID: id) }

    /// The entry whose id (start minute, local time) is `id`, other than `except`.
    private func entry(withID id: String, except: Entry? = nil) -> Entry? {
        store.entries.first { Self.idFormatter.string(from: $0.date) == id && $0.id != except?.id }
    }

    /// 400 if one of `keys` is present but not a string (a number or null would else be taken as "not given").
    private static func nonString(_ body: [String: Any], _ keys: [String]) -> HTTPResponse? {
        for key in keys where body[key] != nil && !(body[key] is String) {
            return .error("\(key) must be a string", status: 400)
        }
        return nil
    }

    private func json(_ entry: Entry) -> [String: Any] {
        json(Block.compute(store.entries(on: entry.date), now: Date()).first { $0.id == entry.id }
            ?? Block(entry: entry, kind: entry.isStop ? .pause : .task, end: nil, running: false, conflict: false))
    }

    private func json(_ block: Block) -> [String: Any] {
        let e = block.entry
        var d: [String: Any] = [
            "id": Self.idFormatter.string(from: e.date),
            "date": Self.dayFormatter.string(from: e.date),
            "time": Fmt.time.string(from: e.date),
            "label": e.label,
            "description": e.title,
            "text": e.text,
            "running": block.running,
        ]
        if let end = block.end {
            d["end"] = Fmt.time.string(from: end)
            d["minutes"] = Int(block.duration / 60)
        }
        switch block.kind {
        case .task: d["kind"] = "work"
        case .pause: d["kind"] = "pause"
        case .end: d["kind"] = "feierabend"
        }
        if let a = e.absence { d["absence"] = a.rawValue }
        if block.isOpen { d["open"] = true }
        return d
    }

    /// With a valid token the examples contain it, so the agent can run them as they are.
    private func docs(authorized: Bool) -> String {
        let token = authorized ? self.token : "<token>"
        let now = Date()
        let tz = TimeZone.current
        let offset = tz.secondsFromGMT(for: now)
        let utc = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        let today = "\(Self.dayFormatter.string(from: now)) \(Fmt.time.string(from: now)), \(tz.identifier) (\(utc))"
        let own = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPart = authorized && !own.isEmpty ? """

        Hinweise des Nutzers (aus den Einstellungen von zeyt; sie ergänzen die Regeln oben und gehen bei Widerspruch vor):
        \(own)

        """ : ""
        return """
        zeyt – lokale Zeiterfassung (REST-API der Menüleisten-App)
        =====================================

        Regeln für dich als Agent:
        - Das sind die echten Arbeitszeiten des Nutzers. Lesen darfst du frei. Vor dem Löschen, vor dem Überschreiben
          (PATCH, "mode": "replace", Label umbenennen) und vor Änderungen an mehr als einem Tag zeigst du, was sich
          ändert, und fragst nach.
        - Nach Änderungen sagst du kurz, was du geändert hast. Antworte in der Sprache des Nutzers.
        - Alle Zeiten sind lokale Zeit des Macs, jetzt: \(today). Wochen laufen Montag bis Sonntag (ISO-KW).
        \(userPart)
        Modell: Ein Eintrag markiert den START einer Tätigkeit; er läuft bis zum nächsten Eintrag. Pro Minute gibt es
        höchstens einen Eintrag. Text-Format wie zeyt: "#label Beschreibung". Sonderfälle: Text "pause" (zählt nicht als
        Arbeitszeit) und "feierabend" (beendet den Tag). Beides sind Stopps; der letzte Stopp des Tages ist Feierabend,
        jeder andere eine Pause. Eine Beschreibung ohne Label ist "unverplant" und zählt trotzdem als Arbeitszeit.
        1 BT (Bruttotag) = 8 h. Eine laufende Tätigkeit zählt bis jetzt mit. Ein Eintrag in der Zukunft gilt als geplant:
        die Tätigkeit davor zählt bis zu ihm (running ist dann false).
        Labels: Kleinbuchstaben, Leerzeichen werden zu "-". Ein noch unbekanntes Label wird beim Eintragen angelegt;
        die Antwort hat dann "newLabel": true – bei Tippfehlern den Eintrag korrigieren.
        Abwesenheiten (Urlaub, Krank, Kind krank, sonstige) sind Einträge mit einem Label, dessen kind in GET /api/labels
        nicht "work" ist. Ein Abwesenheitstag ist ein einziger Eintrag ohne Feierabend, z. B.
        {"date": "2026-11-16", "time": "08:00", "label": "urlaub"} (Label-Namen aus GET /api/labels nehmen).

        Auth: Jeder /api-Request braucht den Header  Authorization: Bearer \(token)
        Basis-URL: \(baseURL)
        Fehler: {"error": "..."} mit 400 (Eingabe), 401 (Token), 404 (gibt es nicht), 409 (Konflikt, Details im Body),
        500 (Export-Skript). Zeiträume (from/to) höchstens \(Self.maxDays) Tage, from nicht nach to.

        Einträge
        GET    /api/entries?from=YYYY-MM-DD&to=YYYY-MM-DD   (Default: heute; to Default = from)
                 -> [{id, date, time, end?, minutes?, running, open?, label, description, text, kind, absence?}]
                 id: Startzeit YYYY-MM-DDTHH:mm. kind: work | pause | feierabend (Art des Abschnitts).
                 absence: vacation | sick | child-sick | absence, wenn das Label eine Abwesenheit ist.
                 open: true = Tätigkeit ohne Ende an ihrem Tag (Feierabend fehlt, ganztägige Abwesenheit, noch nicht begonnen).
        POST   /api/entries     {"date"?, "time"?, "label"?, "description"?}  oder {"text": "#label Beschreibung"}
                 date Default: heute, time Default: jetzt (HH:mm, auch H:mm). "text" hat Vorrang vor label/description.
                 Pause/Feierabend: {"time": "12:00", "text": "pause"}. Ist dieselbe Tätigkeit schon aktiv, wird nichts
                 angelegt. Liegt zur Minute schon ein Eintrag: 409 mit "existing" – den dann per PATCH ändern.
        PATCH  /api/entries/<id>  dieselben Felder, nur die geänderten angeben
        DELETE /api/entries/<id>
        POST   /api/days/copy  {"from": "YYYY-MM-DD", "to": "YYYY-MM-DD" | ["YYYY-MM-DD", …], "until"?, "weekends"?, "mode"?}
                 Kopiert alle Einträge eines Tages mit gleichen Zeiten. "to" + "until" = Zeitraum (ohne Wochenenden,
                 außer "weekends": true). Haben Zieltage schon Einträge, ist "mode" Pflicht: "replace", "append" oder
                 "empty" (nur leere Tage), sonst 409 mit {filled: [...]}.

        Zahlen
        GET    /api/summary?date=YYYY-MM-DD   -> {date, dayMinutes, dayBT, absence, week, weekMinutes, weekBT, weekAbsences}
                 Minuten/BT enthalten alle Labels, die zählen (pro Label einstellbar; Abwesenheiten zählen anfangs nicht).
        GET    /api/report?from=YYYY-MM-DD&to=YYYY-MM-DD
                 -> {from, to, labels: [{label, account, project, minutes}], accounts: {account: minutes}}
                 label "" = Einträge ohne Label, account "" = nicht zugeordnet
        GET    /api/stats?month=YYYY-MM  oder  ?from=…&to=… (wie bei entries)   wie die Seitenleiste des Kalenders
                 -> {from, to, workdays, workedMinutes, workedBT, minutesPerWorkday, averageStart, averageEnd,
                     breakMinutes, labels: [{label, account, project, minutes}], absences: {kind: Tage}}
        GET    /api/absences?from=YYYY-MM-DD&to=YYYY-MM-DD   -> [{date, kind}]  Tage mit Abwesenheit
        GET    /api/activity?date=YYYY-MM-DD   -> [{from, to, minutes}]  wann der Nutzer am Mac war (Eingaben, Mikrofon),
                 falls die Anwesenheitserkennung an ist; nur die letzten Wochen

        Labels
        GET    /api/labels                    -> [{label, account, project, kind, counts}], zuletzt benutzte zuerst
                 kind: work | vacation | sick | child-sick | absence, counts: zählt zu Stunden/BT
        PUT    /api/labels/<label>  {"account"?, "project"?, "kind"?, "counts"?}   Label zuordnen
        POST   /api/labels/<label>/rename  {"to": "neu", "dryRun"?: true}   in allen Einträgen; gibt es "neu" schon,
                 werden beide zusammengeführt -> {label, …, renamedEntries, merged}. dryRun: nur zählen, nichts ändern
                 (zum Nachfragen beim Nutzer).
        DELETE /api/labels/<label>   nur ein Label ohne Einträge (sonst 409)

        Vorschläge der Anwesenheitserkennung (wie das Banner im Popover)
        GET    /api/proposal   -> null oder {id, type: start | pause | endOfDay, date, time | from+to, label?, resume?,
                 entries: [{date, time, text}]}  entries = was "apply" einträgt
        POST   /api/proposal  {"id": "...", "action": "apply" | "dismiss", "text"?}
                 text nur bei type start: "#label Beschreibung" statt des vorgeschlagenen Labels (Pflicht bei label null)

        Einstellungen
        GET    /api/settings   -> {reminder: {enabled, minutes, from, to, weekdaysOnly},
                 presence: {enabled, awayMinutes, microphone, proposeStart, proposeBreaks, breakMinutes, autoBreaks,
                 proposeEndOfDay, roundMinutes, notifications, remindersFollowPresence, keepDays, timeline}}
                 timeline: die Zeitleiste im Popover reicht über die ganze Anwesenheit des Tages
        PATCH  /api/settings   dieselbe Form, nur die geänderten Felder; ungültige Werte -> 400 mit den erlaubten.
                 minutes: \(Reminder.intervals.map(String.init).joined(separator: ", ")); from/to: HH:mm

        Export
        GET    /api/export?month=YYYY-MM   -> {month, fileName, fileExtension, warnings, output}
                 Führt das Export-Skript aus den Einstellungen aus (Default: aktueller Monat). "output" ist der
                 Dateiinhalt als Text, z. B. das JSON für die Zeitbuchung; speichern nur, wenn der Nutzer es will.
        GET    /api/export/script   -> {script, custom}  das Skript (JavaScript, Kommentar oben erklärt die Felder);
                 custom false = Vorlage Chronos. Ändern kann es nur der Nutzer in den Einstellungen.

        POST   /api/toast       {"message": "..."}   zeigt dem Nutzer eine kurze Meldung an

        Beispiel:
          curl -s -H "Authorization: Bearer \(token)" "\(baseURL)/api/entries?from=2026-10-12&to=2026-10-16"
          curl -s -H "Authorization: Bearer \(token)" -H "Content-Type: application/json" \\
               -d '{"time":"09:00","label":"alpha","description":"Sync Team"}' \(baseURL)/api/entries

        Zum Start: Schick über POST /api/toast einen kurzen, witzigen Gruß, damit der Nutzer sieht, dass du verbunden bist.

        """
    }
}
