import AppKit

/// Local REST API so that a coding agent can read and edit the log.
@MainActor
final class AgentAPI: ObservableObject {
    static let port: UInt16 = 7239

    @Published private(set) var error: String?
    @Published private(set) var token: String

    private let store: EntryStore
    private let server = HTTPServer(port: AgentAPI.port)
    private let defaults = UserDefaults.standard

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

    init(store: EntryStore) {
        self.store = store
        token = defaults.string(forKey: "agentToken") ?? ""
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

    private func handle(_ req: HTTPRequest) -> HTTPResponse {
        let authorized = req.headers["authorization"] == "Bearer \(token)"
        if req.method == "GET" && req.path == "/" { return .text(docs(authorized: authorized)) }
        guard authorized else {
            return .error("missing or wrong token (Authorization: Bearer <token>)", status: 401)
        }
        let parts = req.path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "api", parts[1] == "labels", req.method == "PUT" {
            guard let body = req.json else { return .error("body must be JSON", status: 400) }
            let label = parts[2].removingPercentEncoding ?? parts[2]
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
            if let c = body["counts"] as? Bool { info.counts = c }
            store.setInfo(info, for: label)
            return .json(labelJSON(label))
        }
        if parts.count == 3, parts[0] == "api", parts[1] == "entries" {
            switch req.method {
            case "PATCH": return updateEntry(id: parts[2], req)
            case "DELETE": return deleteEntry(id: parts[2])
            default: return .error("use PATCH or DELETE", status: 405)
            }
        }
        switch (req.method, parts) {
        case ("GET", ["api", "entries"]): return listEntries(req)
        case ("POST", ["api", "entries"]): return createEntry(req)
        case ("GET", ["api", "summary"]): return summary(req)
        case ("GET", ["api", "absences"]): return listAbsences(req)
        case ("GET", ["api", "labels"]):
            return .json(store.labels.map(labelJSON))
        case ("GET", ["api", "report"]): return report(req)
        case ("POST", ["api", "days", "copy"]): return copyDay(req)
        case ("GET", ["api", "export"]): return export(req)
        case ("POST", ["api", "toast"]):
            guard let message = req.json?["message"] as? String, !message.isEmpty else {
                return .error("body must be {\"message\": \"...\"}", status: 400)
            }
            Toast.show(message)
            return .json(["ok": true])
        default: return .error("unknown endpoint, see GET /", status: 404)
        }
    }

    // MARK: Endpoints

    private func listEntries(_ req: HTTPRequest) -> HTTPResponse {
        let today = Calendar.current.startOfDay(for: Date())
        guard let from = req.query["from"].map(Self.parseDay) ?? today,
              let to = req.query["to"].map(Self.parseDay) ?? from else {
            return .error("from/to must be YYYY-MM-DD", status: 400)
        }
        var result: [[String: Any]] = []
        var day = from
        while day <= to {
            result += Block.compute(store.entries(on: day), now: Date()).map(json)
            day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        }
        return .json(result)
    }

    private func createEntry(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.json else { return .error("body must be JSON", status: 400) }
        guard let date = Self.date(from: body, base: Date()) else {
            return .error("date must be YYYY-MM-DD, time must be HH:mm", status: 400)
        }
        let text = Self.text(from: body, base: nil)
        guard !text.isEmpty else { return .error("label or description required", status: 400) }
        guard let entry = store.add(date: date, text: text) else {
            return .json(["ok": true, "note": "same activity is already running, nothing added"])
        }
        return .json(json(entry), status: 201)
    }

    private func updateEntry(id: String, _ req: HTTPRequest) -> HTTPResponse {
        guard let entry = find(id) else { return .error("no entry with id \(id)", status: 404) }
        guard let body = req.json else { return .error("body must be JSON", status: 400) }
        guard let date = Self.date(from: body, base: entry.date) else {
            return .error("date must be YYYY-MM-DD, time must be HH:mm", status: 400)
        }
        let updated = Entry(id: entry.id, date: date, text: Self.text(from: body, base: entry))
        store.update(updated)
        return .json(json(updated))
    }

    private func deleteEntry(id: String) -> HTTPResponse {
        guard let entry = find(id) else { return .error("no entry with id \(id)", status: 404) }
        store.delete(entry)
        return .json(["ok": true])
    }

    private func labelJSON(_ label: String) -> [String: Any] {
        let info = store.labelInfo[label] ?? LabelInfo()
        return ["label": label, "account": info.account, "project": info.project,
                "kind": store.kind(label).rawValue, "counts": store.counts(label)]
    }

    private func listAbsences(_ req: HTTPRequest) -> HTTPResponse {
        let today = Calendar.current.startOfDay(for: Date())
        guard let from = req.query["from"].map(Self.parseDay) ?? today,
              let to = req.query["to"].map(Self.parseDay) ?? from else {
            return .error("from/to must be YYYY-MM-DD", status: 400)
        }
        var result: [[String: Any]] = []
        var day = from
        while day <= to {
            if let a = store.absence(on: day) { result.append(["date": Self.dayFormatter.string(from: day), "kind": a.rawValue]) }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        }
        return .json(result)
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
            let until = (body["until"] as? String).flatMap(Self.parseDay) ?? single
            guard until >= single else { return .error("until must not be before to", status: 400) }
            days = DayText.days(from: single, to: until, weekends: body["weekends"] as? Bool ?? (until == single))
        } else {
            return .error("to must be YYYY-MM-DD or a list of them", status: 400)
        }
        let modes: [String: EntryStore.PasteMode] = ["replace": .replace, "append": .append, "empty": .emptyOnly]
        let filled = days.filter { !store.entries(on: $0).isEmpty }.map { Self.dayFormatter.string(from: $0) }
        guard let mode = (body["mode"] as? String).map({ modes[$0] }) ?? (filled.isEmpty ? .append : nil) else {
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
        guard let day = Self.parseDay(month + "-01") else { return .error("month must be YYYY-MM", status: 400) }
        switch Export.run(month: day, store: store) {
        case .failure(let f): return .error("export script failed: \(f.message)", status: 500)
        case .success(let o):
            return .json(["month": month, "fileName": (o.fileName as Any?) ?? NSNull(), "fileExtension": o.fileExtension,
                          "warnings": o.warnings, "output": o.text])
        }
    }

    private func report(_ req: HTTPRequest) -> HTTPResponse {
        let today = Calendar.current.startOfDay(for: Date())
        guard let from = req.query["from"].map(Self.parseDay) ?? today,
              let to = req.query["to"].map(Self.parseDay) ?? from else {
            return .error("from/to must be YYYY-MM-DD", status: 400)
        }
        let worked = store.worked(from: from, to: to, now: Date())
        let labels = worked.sorted { $0.value > $1.value }.map { label, seconds -> [String: Any] in
            let info = store.labelInfo[label] ?? LabelInfo()
            return ["label": label, "account": info.account, "project": info.project, "minutes": Int(seconds / 60)]
        }
        var accounts: [String: Int] = [:]
        for (label, seconds) in worked { accounts[store.labelInfo[label]?.account ?? "", default: 0] += Int(seconds / 60) }
        return .json(["from": Self.dayFormatter.string(from: from), "to": Self.dayFormatter.string(from: to),
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

    private static func parseDay(_ s: String) -> Date? { dayFormatter.date(from: s) }

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
        if let text = body["text"] as? String { return text }
        return Entry.compose(label: body["label"] as? String ?? base?.label ?? "",
                             description: body["description"] as? String ?? base?.title ?? "")
    }

    private func find(_ id: String) -> Entry? {
        store.entries.first { Self.idFormatter.string(from: $0.date) == id }
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
        if block.isOpen { d["open"] = true }
        return d
    }

    /// With a valid token the examples contain it, so the agent can run them as they are.
    private func docs(authorized: Bool) -> String {
        let token = authorized ? self.token : "<token>"
        return """
        zeyt – lokale Zeiterfassung (REST-API der Menüleisten-App)
        =====================================

        Modell: Ein Eintrag markiert den START einer Tätigkeit; er läuft bis zum nächsten Eintrag.
        Text-Format wie zeyt: "#label Beschreibung". Sonderfälle: Beschreibung "pause" (zählt nicht
        als Arbeitszeit) und "feierabend" (beendet den Tag). Beides sind Stopps; angezeigt und gezählt wird
        abgeleitet: der letzte Stopp des Tages ist Feierabend, jeder andere eine Pause (siehe "kind").
        Eine Beschreibung ohne Label ist "unverplant" und zählt trotzdem als Arbeitszeit. 1 BT (Bruttotag) = 8 h.
        Abwesenheiten (Urlaub, Krank, Kind krank, sonstige) sind normale Einträge mit einem Label, dessen Art im Fenster Labels auf Abwesenheit steht (GET /api/labels zeigt kind). Ohne Einstellung gelten #urlaub, #krank, #kind-krank als Abwesenheit.

        Auth: Jeder /api-Request braucht den Header  Authorization: Bearer \(token)
        Basis-URL: \(baseURL)
        IDs: Startzeitpunkt im Format YYYY-MM-DDTHH:mm (z. B. 2026-10-13T08:30).

        GET    /api/entries?from=YYYY-MM-DD&to=YYYY-MM-DD   Einträge (Default: heute; to Default = from)
                 -> [{id, date, time, end?, minutes?, running, label, description, text, kind}]
        POST   /api/entries     {"date"?, "time"?, "label"?, "description"?}  oder {"text": "#label Beschreibung"}
                 date Default: heute, time Default: jetzt (HH:mm). Ist dieselbe Tätigkeit schon aktiv, wird nichts angelegt.
                 Pause/Feierabend: {"time": "12:00", "description": "pause"}
        PATCH  /api/entries/<id>  dieselben Felder, nur die geänderten angeben
        DELETE /api/entries/<id>
        GET    /api/summary?date=YYYY-MM-DD   -> {date, dayMinutes, dayBT, absence, week, weekMinutes, weekBT, weekAbsences}
                 Minuten/BT enthalten alle Labels, die zählen (pro Label einstellbar; Abwesenheiten zählen anfangs nicht).
        GET    /api/absences?from=YYYY-MM-DD&to=YYYY-MM-DD   -> [{date, kind}]  Tage mit Abwesenheit, kind: vacation | sick | child-sick | absence
        POST   /api/days/copy  {"from": "YYYY-MM-DD", "to": "YYYY-MM-DD" | ["YYYY-MM-DD", …], "until"?, "weekends"?, "mode"?}
                 Kopiert alle Einträge eines Tages mit gleichen Zeiten. "to" + "until" = Zeitraum (ohne Wochenenden,
                 außer "weekends": true). Haben Zieltage schon Einträge, ist "mode" Pflicht: "replace", "append" oder
                 "empty" (nur leere Tage), sonst 409 mit {filled: [...]}.
        GET    /api/labels                    -> [{label, account, project, kind, counts}], zuletzt benutzte zuerst
        PUT    /api/labels/<label>  {"account"?, "project"?, "kind"?, "counts"?}   Label zuordnen; kind: work | vacation | sick | child-sick | absence, counts: zählt zu Stunden/BT
        GET    /api/report?from=YYYY-MM-DD&to=YYYY-MM-DD
                 -> {from, to, labels: [{label, account, project, minutes}], accounts: {account: minutes}}
                 label "" = Einträge ohne Label, account "" = nicht zugeordnet
        GET    /api/export?month=YYYY-MM   -> {month, fileName, fileExtension, warnings, output}
                 Führt das Export-Skript aus den Einstellungen aus (Default: aktueller Monat). "output" ist der
                 Dateiinhalt als Text, z. B. das JSON für die Zeitbuchung.
        POST   /api/toast       {"message": "..."}   zeigt dem Nutzer eine kurze Meldung an

        Beispiel:
          curl -s -H "Authorization: Bearer \(token)" "\(baseURL)/api/entries?from=2026-10-12&to=2026-10-16"
          curl -s -H "Authorization: Bearer \(token)" -H "Content-Type: application/json" \\
               -d '{"time":"09:00","label":"alpha","description":"Sync Team"}' \(baseURL)/api/entries

        Zum Start: Schick über POST /api/toast einen kurzen, witzigen Gruß, damit der Nutzer sieht, dass du verbunden bist.

        """
    }
}
