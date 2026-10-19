import Foundation
import JavaScriptCore

/// Generic export: a user script (Settings) turns one month of entries into a file.
///
/// The script defines `function transform(input)` and decides everything about the file: what goes
/// in (e.g. whether absences are exported) and the format, through the helpers `json()`, `csv()`,
/// `tsv()`, `text()` and `file()`. A plain object is written as JSON and a plain string as text
/// (extension from a global `fileExtension`). `warn("…")` reports hints shown after the export.
enum ExportScript {
    struct Output {
        var text: String
        var fileExtension: String
        var warnings: [String]
        /// File name the script suggests (without extension).
        var fileName: String?
    }

    /// Helpers available to every script. They return a tagged object the app turns into the file.
    static let prelude = """
    function file(content, options) {
      options = options || {};
      return { __zeytFile: true, content: String(content), extension: options.extension || "txt", name: options.name };
    }
    function text(content, options) { return file(content, Object.assign({ extension: "txt" }, options)); }
    function json(value, options) {
      options = options || {};
      const indent = options.indent === undefined ? 2 : options.indent;
      return file(JSON.stringify(value, null, indent), Object.assign({ extension: "json" }, options));
    }
    function csv(rows, options) {
      options = options || {};
      const sep = options.separator || ",";
      const always = options.quote === "always";
      const field = v => {
        const s = v === undefined || v === null ? "" : String(v);
        return always || s.includes(sep) || /["\\r\\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
      };
      const body = rows.map(r => r.map(field).join(sep)).join("\\n") + "\\n";
      return file(body, Object.assign({ extension: "csv" }, options));
    }
    function tsv(rows, options) {
      const field = v => (v === undefined || v === null ? "" : String(v)).replace(/[\\t\\r\\n]+/g, " ");
      const body = rows.map(r => r.map(field).join("\\t")).join("\\n") + "\\n";
      return file(body, Object.assign({ extension: "tsv" }, options));
    }
    """

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let key = "exportScript"

    /// The script from the settings, or the Chronos template.
    static var current: String {
        let s = UserDefaults.standard.string(forKey: key) ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Template.chronos.script : s
    }

    /// Runs `script` on `input`. Thread-safe: every call gets its own context.
    static func run(_ script: String, input: [String: Any]) -> Result<Output, Failure> {
        guard let context = JSContext() else { return .failure(Failure(message: L("JavaScript nicht verfügbar"))) }
        limitExecutionTime(of: context)
        var warnings: [String] = []
        var exception: String?
        context.exceptionHandler = { _, value in
            guard exception == nil, let value else { return }
            let line = value.objectForKeyedSubscript("line").flatMap { $0.isUndefined ? nil : $0.toString() }
            let text = value.toString() ?? L("Fehler")
            exception = line.map { L("%1$@ (Zeile %2$@)", text, $0) } ?? text
        }
        let warn: @convention(block) (JSValue) -> Void = { warnings.append($0.toString() ?? "") }
        context.setObject(warn, forKeyedSubscript: "warn" as NSString)
        let console = JSValue(newObjectIn: context)
        console?.setObject(warn, forKeyedSubscript: "log")
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        context.evaluateScript(prelude)
        context.evaluateScript(script)
        if let exception { return .failure(Failure(message: exception)) }
        guard let transform = context.objectForKeyedSubscript("transform"), transform.isObject else {
            return .failure(Failure(message: L("Das Skript muss eine Funktion transform(input) definieren.")))
        }
        let result = transform.call(withArguments: [input])
        if let exception {
            let stopped = exception.contains("JavaScript execution terminated") || exception.contains("Terminated")
            return .failure(Failure(message: stopped ? L("Skript nach %@ s abgebrochen – Endlosschleife?", String(Int(timeLimit))) : exception))
        }
        guard let result, !result.isUndefined, !result.isNull else {
            return .failure(Failure(message: L("transform(input) hat nichts zurückgegeben.")))
        }

        func clean(_ ext: String) -> String {
            String(ext.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(10))
        }
        // file(), json(), csv(), tsv(), text(): the script said exactly what the file is.
        if result.isObject, result.objectForKeyedSubscript("__zeytFile")?.toBool() == true {
            let name = result.objectForKeyedSubscript("name").flatMap { $0.isString ? $0.toString() : nil }
            return .success(Output(text: result.objectForKeyedSubscript("content")?.toString() ?? "",
                                   fileExtension: clean(result.objectForKeyedSubscript("extension")?.toString() ?? "txt"),
                                   warnings: warnings,
                                   fileName: name.map { $0.replacingOccurrences(of: "/", with: "-") }))
        }

        let text: String
        var ext: String
        if result.isString {
            text = result.toString()
            ext = "txt"
        } else {
            let stringify = context.evaluateScript("(v) => JSON.stringify(v, null, 2)")
            guard let json = stringify?.call(withArguments: [result]), json.isString else {
                return .failure(Failure(message: exception ?? L("Ergebnis lässt sich nicht als JSON schreiben.")))
            }
            text = json.toString()
            ext = "json"
        }
        if let custom = context.objectForKeyedSubscript("fileExtension"), custom.isString {
            ext = clean(custom.toString())
        }
        return .success(Output(text: text, fileExtension: ext, warnings: warnings))
    }

    static let timeLimit: Double = 5

    /// A script stuck in a loop would freeze the app: JavaScriptCore stops it after `timeLimit`.
    /// The function is exported by JavaScriptCore but only declared in a private header.
    private static func limitExecutionTime(of context: JSContext) {
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return }
        let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), timeLimit, nil, nil)
    }

    // MARK: Input

    /// The month as plain values for the script.
    static func input(month start: Date, entries: (Date) -> [Entry], labels: [String: LabelInfo], now: Date) -> [String: Any] {
        let cal = Calendar.current
        var days: [[String: Any]] = []
        var d = start
        while cal.isDate(d, equalTo: start, toGranularity: .month) {
            let blocks = Block.compute(entries(d), now: now)
            let end = blocks.last.flatMap { $0.kind == .end ? $0.entry.date : nil }
            var absences: [String] = []
            for a in blocks.compactMap(\.entry.absence?.rawValue) where !absences.contains(a) { absences.append(a) }
            var day: [String: Any] = [
                "date": dayFormat.string(from: d),
                "day": cal.component(.day, from: d),
                "weekday": weekdayFormat.string(from: d),
                "weekend": cal.isDateInWeekend(d),
                "closed": end != nil,
                "absences": absences,
                "entries": blocks.map { entry($0, labels: labels) },
            ]
            if let first = blocks.first { day["start"] = Fmt.time.string(from: first.entry.date) }
            if let end { day["end"] = Fmt.time.string(from: end) }
            days.append(day)
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        var labelList: [String: Any] = [:]
        for (label, info) in labels {
            let kind = LabelKind.of(label)
            labelList[label] = ["account": info.account, "project": info.project, "kind": kind.rawValue,
                                "counts": info.counts ?? !kind.isAbsence]
        }
        return ["month": monthFormat.string(from: start), "days": days, "labels": labelList]
    }

    private static func entry(_ b: Block, labels: [String: LabelInfo]) -> [String: Any] {
        let e = b.entry
        let info = labels[e.label] ?? LabelInfo()
        var d: [String: Any] = [
            "start": Fmt.time.string(from: e.date),
            "minutes": Int((max(0, b.duration) / 60).rounded()),
            "kind": b.kind == .task ? "work" : b.kind == .pause ? "pause" : "feierabend",
            "label": b.kind == .task ? e.label : "",
            "description": b.kind == .task ? e.title : "",
            "account": b.kind == .task ? info.account : "",
            "project": b.kind == .task ? info.project : "",
            "absence": e.absence?.rawValue ?? NSNull(),
            "running": b.running,
        ]
        if let end = b.end { d["end"] = Fmt.time.string(from: end) }
        return d
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let weekdayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EE"
        return f
    }()

    // MARK: Templates

    enum Template: CaseIterable, Identifiable {
        case chronos, csv
        var id: Self { self }

        var title: String {
            switch self {
            case .chronos: return "Chronos"
            case .csv: return L("Tabelle (CSV)")
            }
        }

        var script: String {
            switch self {
            case .chronos: return chronosScript
            case .csv: return csvScript
            }
        }
    }

    static let inputDoc = """
    // input = {
    //   month: "2026-10",
    //   days: [{                 // jeder Tag des Monats, auch ohne Einträge
    //     date: "2026-10-01", day: 1, weekday: "Do", weekend: false,
    //     closed: true,          // endet mit Feierabend
    //     start: "08:00", end: "16:30",   // nur wenn es Einträge gibt
    //     absences: ["sick"],    // Abwesenheiten des Tages (Art, siehe absence)
    //     entries: [{
    //       start: "08:00", end: "09:00", minutes: 60,
    //       kind: "work" | "pause" | "feierabend",
    //       label, description, account, project,
    //       absence: "vacation" | "sick" | "child-sick" | "absence" | null,   // Art des Labels
    //       running,             // läuft gerade (heute)
    //     }],
    //   }],
    //   labels: { "<label>": { account, project, kind, counts } },   // kind: "work" oder wie absence
    // }
    //
    // Das Skript entscheidet, was in die Datei kommt (z. B. ob Abwesenheiten)
    // und in welchem Format. Rückgabe:
    //   json(wert)                        JSON (.json)
    //   csv(zeilen, { separator: ";" })   CSV (.csv), zeilen = [[...], ...]
    //   tsv(zeilen)                       Tabulator getrennt (.tsv)
    //   text("...", { extension: "md" })  beliebiger Text
    // Alle nehmen optional { name: "dateiname", extension: "..." }.
    // Ein einfaches Objekt wird JSON, eine Zeichenkette Text.
    // warn("…") zeigt nach dem Export einen Hinweis.
    """

    private static let chronosScript = """
    // Export für Chronos (Zeitbuchung) als JSON.
    //
    // - Abwesenheit (Urlaub, Krank, Kind krank) wird nicht exportiert:
    //   Tage nur mit Abwesenheit fallen weg, sonst zählt die Anwesenheit
    //   nur vom ersten bis zum Ende des letzten Arbeitseintrags.
    // - Tage ohne Feierabend werden nicht exportiert.
    // - bookings: Arbeitszeit je Account und Projekt, die Kommentare
    //   mit "; " verbunden. Achtung, über Kreuz: der Account ist
    //   "project_name", das Projekt "account_name".
    // - working_hours: "breaks" ist die Zeit dazwischen ohne Arbeit
    //   (Pausen). Damit gilt je Tag
    //   Anwesenheit - breaks = Summe der Buchungen,
    //   sobald alle Labels einem Account zugeordnet sind.
    //
    \(inputDoc)

    function transform(input) {
      const out = { bookings: [], working_hours: [] };
      const unbooked = {};

      for (const day of input.days) {
        const work = day.entries.filter(e => e.kind === "work" && !e.absence);
        if (work.length === 0) continue;   // leer oder nur Abwesenheit
        if (!day.closed) {
          if (!day.entries.some(e => e.running)) warn(`${day.date}: kein Feierabend, Tag nicht exportiert`);
          continue;
        }
        const rows = [];
        let net = 0;
        for (const e of day.entries) {
          if (e.kind !== "work" || e.absence) continue;
          net += e.minutes;
          if (!e.account) {
            const key = e.label ? "#" + e.label : "ohne Label";
            unbooked[key] = (unbooked[key] || 0) + e.minutes;
            continue;
          }
          let row = rows.find(r => r.project_name === e.account && r.account_name === e.project);
          if (!row) {
            row = { project_name: e.account, account_name: e.project, minutes: 0, comments: [] };
            rows.push(row);
          }
          row.minutes += e.minutes;
          if (e.description) row.comments.push(e.description);
        }
        for (const r of rows) {
          out.bookings.push({
            project_name: r.project_name,
            account_name: r.account_name,
            working_day: day.day,
            duration: clock(r.minutes),
            comment: r.comments.join("; "),
          });
        }
        const start = work[0].start;
        const end = work[work.length - 1].end;
        const attendance = minutes(end) - minutes(start);
        out.working_hours.push({
          working_day: day.day,
          start: start,
          end: end,
          breaks: clock(Math.max(0, attendance - net)),
        });
      }

      for (const [label, m] of Object.entries(unbooked)) {
        if (m > 0) warn(`${label}: ${clock(m)} h ohne Account, nicht gebucht`);
      }
      return json(out, { name: "chronos-" + input.month });
    }

    function clock(m) {
      return String(Math.floor(m / 60)).padStart(2, "0") + ":" + String(m % 60).padStart(2, "0");
    }

    function minutes(hhmm) {
      const [h, m] = hhmm.split(":").map(Number);
      return h * 60 + m;
    }

    """

    private static let csvScript = """
    // Ein Eintrag pro Zeile mit Start, Ende und Dauer,
    // z. B. für eine Tabellenkalkulation.
    //
    \(inputDoc)

    function transform(input) {
      const kinds = { work: "Tätigkeit", pause: "Pause", feierabend: "Feierabend" };
      const rows = [["Datum", "Start", "Ende", "Dauer (h)", "Art", "Label", "Account", "Projekt", "Kommentar"]];
      for (const day of input.days) {
        for (const e of day.entries) {
          const hours = e.end ? (e.minutes / 60).toFixed(2).replace(".", ",") : "";
          rows.push([day.date, e.start, e.end, hours, kinds[e.kind], e.label, e.account, e.project, e.description]);
        }
      }
      // Semikolon und Anführungszeichen, wie es Excel mit deutscher Einstellung erwartet.
      // Tabulatoren statt dessen: return tsv(rows);
      return csv(rows, { separator: ";", quote: "always", name: "zeyt-" + input.month });
    }

    """
}
