import Foundation

/// Rules of the UI concept ("Zeiterfassung – Menüleisten-App"), free of UI code so they can be tested.
enum Rules {
    static let labelMax = 32
    /// Labels longer than this are shortened in the middle when not being edited.
    static let labelShow = 24
    static let paletteSize = 6

    /// Normalizes typed text to a label name (without "#"): lowercase letters, digits, umlauts;
    /// whitespace and "_" become "-", other characters are dropped.
    static func tag(_ raw: String) -> String {
        var v = raw.lowercased()
        while v.hasPrefix("#") { v.removeFirst() }
        v = v.replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
        v = v.replacingOccurrences(of: "[^\\p{L}\\p{N}-]", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        v = v.replacingOccurrences(of: "^-+", with: "", options: .regularExpression)
        return String(v.prefix(labelMax))
    }

    /// Stops are stored as "pause"/"feierabend"; typed, the word in the app's language works too
    /// (e.g. "break"/"done"). Returns the stored word, or nil if `text` is no stop.
    static func stop(_ text: String) -> String? {
        let w = text.trimmingCharacters(in: .whitespaces).lowercased()
        if w == "pause" || w == L("pause").lowercased() { return "pause" }
        if w == "feierabend" || w == L("feierabend").lowercased() { return "feierabend" }
        return nil
    }

    /// Splits pasted or typed "label comment" at the first whitespace.
    static func splitLabel(_ raw: String) -> (label: String, comment: String)? {
        var v = Substring(raw)
        while v.hasPrefix("#") { v = v.dropFirst() }
        guard let space = v.firstIndex(where: \.isWhitespace) else { return nil }
        let rest = v[v.index(after: space)...]
        return (tag(String(v[..<space])), String(rest.drop(while: \.isWhitespace)))
    }

    /// Shortens in the middle: "kundenportal…se-zwei".
    static func mid(_ text: String, _ n: Int) -> String {
        guard text.count > n else { return text }
        let a = Int((Double(n - 1) * 0.6).rounded(.up))
        let b = n - 1 - a
        return String(text.prefix(a)) + "…" + String(text.suffix(b))
    }

    static func isoWeek(_ date: Date) -> Int {
        Calendar(identifier: .iso8601).component(.weekOfYear, from: date)
    }

    /// Start of a line added below the entry at `after` (Shift+Enter): halfway to the next entry,
    /// on 5 minutes if there is room; after the last entry "now" (rounded) if that is later, else 30 min on.
    /// Stays on the same day.
    static func insertTime(after: Date, next: Date?, now: Date) -> Date {
        let cal = Calendar.current
        let minute: TimeInterval = 60
        if let next {
            let mid = after.addingTimeInterval(next.timeIntervalSince(after) / 2)
            let slot = Date(timeIntervalSinceReferenceDate: (mid.timeIntervalSinceReferenceDate / (5 * minute)).rounded(.down) * 5 * minute)
            if slot > after, slot < next { return slot }
            let exact = Date(timeIntervalSinceReferenceDate: (mid.timeIntervalSinceReferenceDate / minute).rounded(.down) * minute)
            return exact > after ? exact : after
        }
        let rounded = roundedNow(now, on: after)
        if cal.isDate(now, inSameDayAs: after), rounded > after { return rounded }
        let later = after.addingTimeInterval(30 * minute)
        let lastSlot = cal.date(bySettingHour: 23, minute: 55, second: 0, of: after)!
        return cal.isDate(later, inSameDayAs: after) ? min(later, lastSlot) : max(after, lastSlot)
    }

    /// The input time follows "now", rounded to 5 minutes.
    static func roundedNow(_ now: Date, on day: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: now)
        let m = min(Int((Double(c.hour! * 60 + c.minute!) / 5).rounded()) * 5, 1435)
        return cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day)!
    }

    /// A stop at `time` is "Feierabend" if nothing follows it, otherwise "Pause".
    static func stopIsEndOfDay(_ entries: [Entry], at time: Date) -> Bool {
        guard let last = entries.last else { return true }
        return time >= last.date
    }

    /// The activity to continue at `time`, if continuing makes sense there:
    /// not in the future, the last entry before is a stop, no entry at `time` yet,
    /// and the task before that stop has a label.
    static func resume(_ entries: [Entry], at time: Date, now: Date) -> Entry? {
        let cal = Calendar.current
        if cal.startOfDay(for: time) > cal.startOfDay(for: now) { return nil }
        if cal.isDate(time, inSameDayAs: now), time > now.addingTimeInterval(5 * 60) { return nil }
        if entries.contains(where: { $0.date == time }) { return nil }
        let before = entries.filter { $0.date < time }
        guard let stop = before.last, stop.isStop else { return nil }
        guard let task = before.dropLast().last(where: { !$0.isStop }), !task.label.isEmpty else { return nil }
        return task
    }

    // MARK: Labels

    struct LabelStat {
        let label: String
        var count = 0
        var last = Date.distantPast
        var comment = ""
    }

    /// Used labels in order of first use, then labels that only exist in the registry.
    static func labelStats(_ entries: [Entry], registry: [String: LabelInfo]) -> [LabelStat] {
        var order: [String] = []
        var stats: [String: LabelStat] = [:]
        for e in entries where !e.isStop && !e.label.isEmpty {
            if stats[e.label] == nil {
                order.append(e.label)
                stats[e.label] = LabelStat(label: e.label)
            }
            stats[e.label]!.count += 1
            if e.date >= stats[e.label]!.last {
                stats[e.label]!.last = e.date
                stats[e.label]!.comment = e.title
            }
        }
        for l in registry.keys.sorted() where stats[l] == nil {
            order.append(l)
            stats[l] = LabelStat(label: l)
        }
        return order.map { stats[$0]! }
    }

    static func meta(_ info: LabelInfo?, label: String = "") -> String {
        guard let info, !info.account.isEmpty, !info.project.isEmpty else {
            let kind = LabelKind.of(label)
            return kind.isAbsence ? kind.title : L("Account & Projekt fehlen")
        }
        return L("%1$@ › %2$@", info.account, info.project)
    }

    struct Suggestion: Identifiable, Equatable {
        let label: String
        let meta: String
        let isNew: Bool
        var id: String { label }
    }

    /// Label suggestions: all (most recently used first) or filtered by label, account and project.
    static func suggest(_ query: String, stats: [LabelStat], registry: [String: LabelInfo], limit: Int = 6) -> [Suggestion] {
        let q = query.lowercased()
        func haystack(_ s: LabelStat) -> String {
            let i = registry[s.label]
            return "\(s.label) \(i?.account ?? "") \(i?.project ?? "")".lowercased()
        }
        var list = q.isEmpty ? stats : stats.filter { haystack($0).contains(q) }
        list.sort { a, b in
            if !q.isEmpty {
                let ap = a.label.lowercased().hasPrefix(q), bp = b.label.lowercased().hasPrefix(q)
                if ap != bp { return ap }
            }
            if a.last != b.last { return a.last > b.last }
            return a.count > b.count
        }
        var items = list.prefix(limit).map { Suggestion(label: $0.label, meta: meta(registry[$0.label], label: $0.label), isNew: false) }
        if !q.isEmpty, !items.contains(where: { $0.label.lowercased() == q }) {
            items.append(Suggestion(label: query, meta: L("Neu · Account & Projekt noch zuordnen"), isNew: true))
        }
        return items
    }

    enum Field { case account, project }

    struct Option: Identifiable, Equatable {
        let value: String
        let account: String
        let meta: String
        let isNew: Bool
        var id: String { "\(value)|\(account)|\(isNew)" }
    }

    /// Options for the account/project comboboxes of the label editor, with the number of labels per value.
    /// Projects are limited to the current account if there is one.
    static func options(_ field: Field, query: String, account currentAccount: String, excluding label: String,
                        registry: [String: LabelInfo], limit: Int = 6) -> [Option] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var counts: [String: (value: String, account: String, n: Int)] = [:]
        for (l, info) in registry where l != label {
            let value = field == .account ? info.account : info.project
            guard !value.isEmpty else { continue }
            if field == .project, !currentAccount.isEmpty, info.account != currentAccount { continue }
            let key = field == .project ? "\(value)|\(info.account)" : value
            counts[key, default: (value, info.account, 0)].n += 1
        }
        var list = Array(counts.values)
        if !q.isEmpty {
            list = list.filter { "\($0.value) \(field == .project ? $0.account : "")".lowercased().contains(q) }
        }
        list.sort { a, b in
            if !q.isEmpty {
                let ap = a.value.lowercased().hasPrefix(q), bp = b.value.lowercased().hasPrefix(q)
                if ap != bp { return ap }
            }
            return a.n != b.n ? a.n > b.n : a.value < b.value
        }
        var items = list.prefix(limit).map { m in
            let count = m.n == 1 ? L("1 Label") : L("%@ Labels", String(m.n))
            let meta = field == .project && currentAccount.isEmpty ? L("%1$@ · %2$@", m.account, count) : count
            return Option(value: m.value, account: m.account, meta: meta, isNew: false)
        }
        if !q.isEmpty, !list.contains(where: { $0.value.lowercased() == q }) {
            let v = query.trimmingCharacters(in: .whitespaces)
            let meta = field == .account ? L("Neuer Account")
                : currentAccount.isEmpty ? L("Neues Projekt") : L("Neues Projekt für %@", currentAccount)
            items.append(Option(value: v, account: "", meta: meta, isNew: true))
        }
        return items
    }
}

/// A day as text ("08:00 #alpha Sync", one entry per line): copy/paste between days and other apps.
enum DayText {
    struct Item: Equatable {
        let hour: Int
        let minute: Int
        let text: String
    }

    static func make(_ entries: [Entry]) -> String {
        entries.map { "\(Fmt.time.string(from: $0.date)) \($0.text)" }.joined(separator: "\n")
    }

    /// Reads "HH:mm text" lines (also "9.30", tabs); everything else is skipped, e.g. zeyt headers.
    /// With several days (zeyt date lines), only the first one is taken. nil if there is no entry.
    /// `strict`: nil as soon as a line of the day is something else, so that any text
    /// that merely contains a time isn't taken for a day.
    static func parse(_ text: String, strict: Bool = false) -> [Item]? {
        var items: [Item] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                if items.isEmpty { continue } else { break }
            }
            if strict, line.isEmpty || line.hasPrefix("'") { continue }
            guard let m = line.range(of: #"^\d{1,2}[:.]\d{2}(?=\s|$)"#, options: .regularExpression),
                  let t = Fmt.parseTime(String(line[m])) else {
                if strict { return nil }
                continue
            }
            let rest = line[m.upperBound...].trimmingCharacters(in: .whitespaces)
            items.append(Item(hour: t.hour, minute: t.minute, text: rest))
        }
        return items.isEmpty ? nil : items.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    /// Days from `from` to `to`; weekends are skipped unless asked for.
    static func days(from: Date, to: Date, weekends: Bool) -> [Date] {
        let cal = Calendar.current
        var d = cal.startOfDay(for: from)
        let last = cal.startOfDay(for: to)
        var result: [Date] = []
        while d <= last {
            if weekends || !cal.isDateInWeekend(d) { result.append(d) }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return result
    }
}

/// Reminder when no label is assigned to the current time.
struct Reminder: Equatable {
    var enabled = true
    /// Remind after this many minutes without a label, and again every as many minutes.
    var minutes = 30
    /// Only between these times (minutes of the day).
    var from = 8 * 60
    var to = 18 * 60
    var weekdaysOnly = true

    static let intervals = [5, 10, 15, 20, 30, 45, 60, 90]

    enum Status: Equatable {
        case off
        /// Outside the time window or on a weekend.
        case outside
        /// A label runs, or a break, the end of the day or an absence.
        case assigned(Entry?)
        /// Without a label since `since`; the next reminder is due at `due`.
        case due(since: Date, due: Date)
    }

    /// `entries` of today; `last` is when the previous reminder was shown.
    func status(entries: [Entry], now: Date, last: Date?) -> Status {
        guard enabled else { return .off }
        let cal = Calendar.current
        if weekdaysOnly, cal.isDateInWeekend(now) { return .outside }
        let start = cal.startOfDay(for: now).addingTimeInterval(TimeInterval(from * 60))
        let end = cal.startOfDay(for: now).addingTimeInterval(TimeInterval(to * 60))
        guard now >= start, now < end else { return .outside }

        let current = entries.last { $0.date <= now }
        if let current, current.isStop || current.absence != nil || !current.label.isEmpty { return .assigned(current) }
        // Nothing yet today counts from the start of the window; an unlabeled entry from its start.
        let since = max(current?.date ?? start, start)
        let base = max(since, last ?? since)
        let due = base.addingTimeInterval(TimeInterval(minutes * 60))
        return due < end ? .due(since: since, due: due) : .outside
    }
}

/// Arrow keys across the day as if it were lines of text: each line has some of the columns
/// time, label, comment (a stop only the time; the input bar is the last line).
enum LineNav {
    enum Column: Int { case time, label, comment }

    /// Where `cmd` goes from `column` of line `line`; nil if it doesn't leave the field.
    /// ← and → step through the columns of the line; ↑ and ↓ stay in the column, or take the nearest
    /// column before it if the other line doesn't have it. Nothing is remembered: ↑ from a time field
    /// always lands in a time field.
    static func move(_ cmd: FieldCommand, line: Int, column: Column, columns: [[Column]]) -> (line: Int, column: Column)? {
        guard columns.indices.contains(line) else { return nil }
        let here = columns[line]
        switch cmd {
        case .leftAtStart, .rightAtEnd:
            guard let i = here.firstIndex(of: column) else { return nil }
            let j = cmd == .leftAtStart ? i - 1 : i + 1
            return here.indices.contains(j) ? (line, here[j]) : nil
        case .up, .down:
            let j = cmd == .up ? line - 1 : line + 1
            guard columns.indices.contains(j), let first = columns[j].first else { return nil }
            return (j, columns[j].last { $0.rawValue <= column.rawValue } ?? first)
        default:
            return nil
        }
    }
}

/// What a row is. Stops are stored as "pause"/"feierabend", but the kind is derived:
/// the last entry of a day is the end of day, every other stop is a break.
enum Kind { case task, pause, end }

/// An entry together with its derived kind and end.
struct Block: Identifiable {
    let entry: Entry
    let kind: Kind
    let end: Date?
    /// Last task of today that has started: runs until now.
    let running: Bool
    /// Same start time as the next entry.
    let conflict: Bool
    var id: UUID { entry.id }
    var duration: TimeInterval { end.map { $0.timeIntervalSince(entry.date) } ?? 0 }
    /// A last task without a stop that isn't running (past day or not started yet).
    var isOpen: Bool { kind == .task && end == nil }

    static func compute(_ entries: [Entry], now: Date) -> [Block] {
        entries.enumerated().map { i, e in
            let next = i + 1 < entries.count ? entries[i + 1] : nil
            let kind: Kind = !e.isStop ? .task : (next == nil ? .end : .pause)
            var end = next?.date
            var running = false
            if next == nil, kind == .task, Calendar.current.isDate(e.date, inSameDayAs: now), e.date <= now {
                end = now
                running = true
            }
            return Block(entry: e, kind: kind, end: end, running: running, conflict: next?.date == e.date)
        }
    }

    /// Working time: all tasks, including unlabeled ones, except those with an `uncounted` label (setting).
    static func worked(_ blocks: [Block], uncounted: Set<String> = []) -> TimeInterval {
        blocks.filter { $0.kind == .task && !uncounted.contains(Rules.tag($0.entry.label)) }
            .reduce(0) { $0 + max(0, $1.duration) }
    }

    static func paused(_ blocks: [Block]) -> TimeInterval {
        blocks.filter { $0.kind == .pause }.reduce(0) { $0 + max(0, $1.duration) }
    }
}

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    /// "Mittwoch, 14. Oktober"
    static let longDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    /// "Oktober 2026"
    static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        return f
    }()

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate("ddMMyyyy")
        return f
    }()

    /// Brutto-Tage: 1 BT = 8 h, two decimals.
    static func bt(_ seconds: TimeInterval) -> String {
        let number = String(format: "%.2f", seconds / (8 * 3600))
            .replacingOccurrences(of: ".", with: AppLanguage.code == "de" ? "," : AppLanguage.locale.decimalSeparator ?? ".")
        return L("%@ BT", number)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// Parses "9:05", "0905", "905" or "9" to hour and minute.
    static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        var h: Int?, m: Int?
        if let colon = t.firstIndex(where: { $0 == ":" || $0 == "." }) {
            h = Int(t[..<colon]); m = Int(t[t.index(after: colon)...])
        } else if let n = Int(t), t.count <= 4 {
            if t.count <= 2 { h = n; m = 0 } else { h = n / 100; m = n % 100 }
        }
        guard let h, let m, (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
}
