import AppKit

/// Absence labels (#urlaub, #krank, #kind-krank). Entries with them are normal entries with times;
/// the label only adds an icon and color in the overview and stops the prompts while it runs.
enum Absence: String, CaseIterable, Identifiable {
    case urlaub
    case krank
    case kindKrank = "kind-krank"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .urlaub: return L("Urlaub")
        case .krank: return L("Krank")
        case .kindKrank: return L("Kind krank")
        }
    }

    var icon: String {
        switch self {
        case .urlaub: return "beach.umbrella"
        case .krank: return "thermometer.medium"
        case .kindKrank: return "figure.and.child.holdinghands"
        }
    }
}

/// One log line: from `date` on you worked on `text` (until the next entry).
struct Entry: Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String

    /// First `#tag` in the text, if any.
    var tag: String? {
        text.split(separator: " ").first { $0.hasPrefix("#") && $0.count > 1 }.map(String.init)
    }

    /// Tag without the leading "#", or "" if there is none.
    var label: String { tag.map { String($0.dropFirst()) } ?? "" }

    /// Builds the stored text from label and comment.
    static func compose(label: String, description: String) -> String {
        let l = Rules.tag(label)
        let d = description.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? d : "#\(l) \(d)".trimmingCharacters(in: .whitespaces)
    }

    /// Text without the tag.
    var title: String {
        guard let tag else { return text }
        return text.replacingOccurrences(of: tag, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Stored as "pause" (intended break) …
    var isPause: Bool { text.lowercased() == "pause" }
    /// … or "feierabend". Whether a stop counts as break or end of day is derived (see `Block`).
    var isEndOfDay: Bool { text.lowercased() == "feierabend" }
    var isStop: Bool { isPause || isEndOfDay }
    var absence: Absence? { isStop ? nil : Absence(rawValue: label) }
}

/// Booking target of a label, like the label lines at the end of a zeyt file.
struct LabelInfo: Codable, Equatable {
    var account = ""
    var project = ""

    var isEmpty: Bool { account.isEmpty && project.isEmpty }
}

/// Entries kept in ~/Library/Application Support/zeyt/log.csv, label assignments in labels.json.
@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var labelInfo: [String: LabelInfo] = [:]
    let url: URL
    private let labelsURL: URL

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// ~/Library/Application Support/zeyt, or ZEYT_DATA_DIR (tests).
    nonisolated static var directory: URL {
        ProcessInfo.processInfo.environment["ZEYT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("zeyt", isDirectory: true)
    }

    private nonisolated static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The app was called TMR before: its folder moves over once.
    private static func migrate(to dir: URL) {
        let old = support.appendingPathComponent("TMR", isDirectory: true)
        let fm = FileManager.default
        guard ProcessInfo.processInfo.environment["ZEYT_DATA_DIR"] == nil,
              !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.moveItem(at: old, to: dir)
    }

    init() {
        let dir = Self.directory
        Self.migrate(to: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("log.csv")
        labelsURL = dir.appendingPathComponent("labels.json")
        load()
    }

    /// Re-reads the file, e.g. after it was edited by hand.
    func load() {
        if let data = try? Data(contentsOf: labelsURL),
           let info = try? JSONDecoder().decode([String: LabelInfo].self, from: data) {
            labelInfo = info
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        entries = content.split(separator: "\n").dropFirst().compactMap { line in
            guard let comma = line.firstIndex(of: ","),
                  let date = formatter.date(from: String(line[..<comma])) else { return nil }
            var text = String(line[line.index(after: comma)...])
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
            }
            return Entry(date: date, text: text)
        }
        .sorted { $0.date < $1.date }
    }

    private func save() {
        var out = "Zeit,Tätigkeit\n"
        for e in entries {
            out += "\(formatter.string(from: e.date)),\"\(e.text.replacingOccurrences(of: "\"", with: "\"\""))\"\n"
        }
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func entries(on day: Date) -> [Entry] {
        entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    /// First absence label of the day (for the icon in the overview).
    func absence(on day: Date) -> Absence? {
        entries(on: day).lazy.compactMap(\.absence).first
    }

    /// Last real activity (no pause/feierabend/absence) on or before `date`.
    func lastWork(before date: Date) -> Entry? {
        entries.last { $0.date <= date && !$0.isStop && $0.absence == nil }
    }

    /// Labels used so far, most recently used first, then labels that were only assigned.
    var labels: [String] {
        var seen = Set<String>()
        let used = entries.reversed().map(\.label).filter { !$0.isEmpty && seen.insert($0).inserted }
        return used + labelInfo.keys.filter { !seen.contains($0) }.sorted()
    }

    /// Known accounts, for suggestions.
    var accounts: [String] {
        Array(Set(labelInfo.values.map(\.account).filter { !$0.isEmpty })).sorted()
    }

    /// Known projects; those already used with `account` come first.
    func projects(for account: String) -> [String] {
        let all = Set(labelInfo.values.map(\.project).filter { !$0.isEmpty })
        let matching = Set(labelInfo.values.filter { $0.account == account }.map(\.project).filter { !$0.isEmpty })
        return matching.sorted() + all.subtracting(matching).sorted()
    }

    func setInfo(_ info: LabelInfo, for label: String) {
        labelInfo[label] = LabelInfo(account: info.account.trimmingCharacters(in: .whitespaces),
                                     project: info.project.trimmingCharacters(in: .whitespaces))
        saveLabels()
    }

    /// Adds a label to the registry (also without entries). Returns the normalized name.
    @discardableResult
    func addLabel(_ name: String) -> String {
        let label = Rules.tag(name)
        guard !label.isEmpty, labelInfo[label] == nil else { return label }
        labelInfo[label] = LabelInfo()
        saveLabels()
        return label
    }

    func removeLabelInfo(_ label: String) {
        labelInfo[label] = nil
        saveLabels()
    }

    func isUsed(_ label: String) -> Int {
        entries.filter { $0.label == label }.count
    }

    /// Renames a label in all entries. If the new name exists, both are merged;
    /// the existing assignment is kept unless it is incomplete. Returns the new name.
    @discardableResult
    func renameLabel(_ old: String, to raw: String) -> String {
        let new = Rules.tag(raw)
        guard !new.isEmpty, new != old else { return old }
        let info = labelInfo.removeValue(forKey: old) ?? LabelInfo()
        if let existing = labelInfo[new], !existing.account.isEmpty, !existing.project.isEmpty {
            // keep existing
        } else {
            labelInfo[new] = info
        }
        entries = entries.map { e in
            guard e.label == old else { return e }
            return Entry(id: e.id, date: e.date, text: Entry.compose(label: new, description: e.title))
        }
        save()
        saveLabels()
        return new
    }

    /// Label statistics (order of first use) and the color slot of each label.
    var labelStats: [Rules.LabelStat] { Rules.labelStats(entries, registry: labelInfo) }

    func colorIndex(_ label: String) -> Int? {
        labelStats.firstIndex { $0.label == label }.map { $0 % Rules.paletteSize }
    }

    /// Labels that are used or registered but lack account or project.
    var unassignedCount: Int {
        labelStats.filter { s in
            guard let i = labelInfo[s.label] else { return Absence(rawValue: s.label) == nil }
            return i.account.isEmpty || i.project.isEmpty
        }.count
    }

    /// Reads the label lines of zeyt files: `#label  ACCOUNT  PROJECT ' 12h`. Returns the number of labels imported.
    @discardableResult
    func importZeyt(_ urls: [URL]) -> Int {
        var count = 0
        for url in urls {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                let fields = line.split(separator: "'")[0].split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 3, fields[0].hasPrefix("#"), fields[0].count > 1 else { continue }
                labelInfo[String(fields[0].dropFirst())] = LabelInfo(account: String(fields[1]), project: String(fields[2]))
                count += 1
            }
        }
        saveLabels()
        return count
    }

    private func saveLabels() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(labelInfo).write(to: labelsURL, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Worked time per label ("" = without label) in the given days.
    func worked(from: Date, to: Date, now: Date) -> [String: TimeInterval] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        let byDay = Dictionary(grouping: entries.filter { $0.date >= start && cal.startOfDay(for: $0.date) <= to }) {
            cal.startOfDay(for: $0.date)
        }
        var result: [String: TimeInterval] = [:]
        for (_, dayEntries) in byDay {
            for block in Block.compute(dayEntries, now: now) where block.kind == .task {
                result[block.entry.label, default: 0] += block.duration
            }
        }
        return result
    }

    /// When each label was last used.
    var lastUsed: [String: Date] {
        var result: [String: Date] = [:]
        for e in entries where !e.label.isEmpty { result[e.label] = e.date }
        return result
    }

    /// Adds an entry; an empty text is an unlabeled task ("unverplant").
    /// With `dedupe`, a repeat of the activity that is already running is ignored.
    @discardableResult
    func add(date: Date, text: String, dedupe: Bool = true) -> Entry? {
        let clean = Self.clean(text)
        if dedupe {
            guard !clean.isEmpty else { return nil }
            let running = entries(on: date).last { $0.date <= date }
            if running?.text == clean { return nil }
        }
        let entry = Entry(date: Self.minute(date), text: clean)
        entries.append(entry)
        entries.sort { $0.date < $1.date }
        save()
        return entry
    }

    func update(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let clean = Self.clean(entry.text)
        entries[i] = Entry(id: entry.id, date: Self.minute(entry.date), text: clean)
        entries.sort { $0.date < $1.date }
        save()
    }

    /// Puts a deleted entry back (undo).
    func restore(_ entry: Entry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        entries.sort { $0.date < $1.date }
        save()
    }

    /// What a paste changed, to undo it.
    struct PasteResult {
        var removed: [Entry] = []
        var added: [Entry] = []
    }

    enum PasteMode { case replace, append, emptyOnly }

    /// Puts the items on each day with their times. `replace` clears the day first,
    /// `emptyOnly` skips days that already have entries.
    @discardableResult
    func paste(_ items: [DayText.Item], on days: [Date], mode: PasteMode) -> PasteResult {
        let cal = Calendar.current
        var result = PasteResult()
        for day in days {
            let existing = entries(on: day)
            if mode == .emptyOnly, !existing.isEmpty { continue }
            if mode == .replace {
                result.removed += existing
                let ids = Set(existing.map(\.id))
                entries.removeAll { ids.contains($0.id) }
            }
            for item in items {
                let date = cal.date(bySettingHour: item.hour, minute: item.minute, second: 0, of: day)!
                let e = Entry(date: date, text: Self.clean(item.text))
                entries.append(e)
                result.added.append(e)
            }
        }
        entries.sort { $0.date < $1.date }
        save()
        return result
    }

    func undo(_ paste: PasteResult) {
        let ids = Set(paste.added.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        entries += paste.removed.filter { r in !entries.contains { $0.id == r.id } }
        entries.sort { $0.date < $1.date }
        save()
    }

    /// Last day before `day` (up to 60 days back) with real work, as template for an empty day.
    func lastWorkDay(before day: Date) -> Date? {
        let cal = Calendar.current
        for back in 1...60 {
            let d = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: day))!
            if entries(on: d).contains(where: { !$0.isStop && $0.absence == nil }) { return d }
        }
        return nil
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func minute(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .minute, for: date)!.start
    }
}
