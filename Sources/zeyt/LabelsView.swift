import SwiftUI

/// Label editor: search or create, rename in place, assign account, project and kind, choose whether it
/// counts for the hours, hours per period.
struct LabelsView: View {
    @ObservedObject var store: EntryStore
    @State private var query = ""
    @State private var period = Period.thisMonth
    @State private var editingName: String?
    @State private var nameDraft = ""
    @State private var skipCommit = false
    @State private var combo: Combo?
    @State private var focusTarget: Target?
    @State private var focusSeq = 0
    @State private var toast: Toast?

    enum Period: String, CaseIterable, Identifiable {
        case thisWeek = "Diese Woche"
        case lastWeek = "Letzte Woche"
        case thisMonth = "Dieser Monat"
        case lastMonth = "Letzter Monat"
        case all = "Gesamt"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .thisWeek: return L("Diese Woche")
            case .lastWeek: return L("Letzte Woche")
            case .thisMonth: return L("Dieser Monat")
            case .lastMonth: return L("Letzter Monat")
            case .all: return L("Gesamt")
            }
        }

        func range(now: Date, first: Date?) -> (from: Date, to: Date) {
            let cal = Calendar(identifier: .iso8601)
            switch self {
            case .thisWeek, .lastWeek:
                var start = cal.dateInterval(of: .weekOfYear, for: now)!.start
                if self == .lastWeek { start = cal.date(byAdding: .day, value: -7, to: start)! }
                return (start, cal.date(byAdding: .day, value: 6, to: start)!)
            case .thisMonth, .lastMonth:
                var start = cal.dateInterval(of: .month, for: now)!.start
                if self == .lastMonth { start = cal.date(byAdding: .month, value: -1, to: start)! }
                let end = cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: .month, value: 1, to: start)!)!
                return (start, end)
            case .all:
                return (first ?? now, now)
            }
        }
    }

    /// Open combobox list: which label, which field, selected index, filtered or not.
    struct Combo: Equatable {
        var label: String
        var field: Rules.Field
        var index: Int
        var typed: Bool
    }

    enum Target: Hashable { case account(String), project(String) }

    struct Toast: Equatable {
        let message: String
        let undo: () -> Void
        let id = UUID()

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let stats = store.labelStats
            let range = period.range(now: context.date, first: store.entries.first?.date)
            let worked = store.worked(from: range.from, to: range.to, now: context.date)
            let rows = filtered(stats)
            VStack(spacing: 0) {
                header(stats.count, total: worked.values.reduce(0, +))
                Divider()
                columnHeader
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.label) { s in row(s, index: stats.firstIndex { $0.label == s.label } ?? 0, hours: worked[s.label] ?? 0) }
                        if let unlabeled = worked[""], unlabeled > 0, query.isEmpty {
                            unlabeledRow(unlabeled)
                        }
                        if rows.isEmpty {
                            Text(L("Kein Label gefunden."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: .infinity)
                if let toast { toastView(toast) }
                accountSummary(worked)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlayPreferenceValue(AnchorKey.self) { anchor in options(anchor) }
        }
        .frame(minWidth: 940, minHeight: 460)
    }

    // MARK: Header

    private var canCreate: Bool {
        let t = Rules.tag(query)
        return !t.isEmpty && !store.labelStats.contains { $0.label == t }
    }

    private func header(_ count: Int, total: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Text("#").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 8)
                    KeyTextField(
                        text: $query, placeholder: L("suchen oder neu anlegen"), font: Look.semibold13,
                        placeholderColor: .tertiaryLabelColor,
                        onCommand: { cmd in
                            switch cmd {
                            case .enter where canCreate: createLabel(); return true
                            case .escape: query = ""; return true
                            default: return false
                            }
                        })
                        .frame(height: 20)
                }
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .frame(maxWidth: 320)
                if canCreate {
                    Button(action: createLabel) {
                        Label(L("#%@ anlegen", Rules.tag(query)), systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(count == 1 ? L("1 Label") : L("%@ Labels", "\(count)")).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Picker("", selection: $period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("\(Fmt.duration(total)) h · \(Fmt.bt(total))")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
        }
        .padding(12)
    }

    private var columnHeader: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 8, height: 1)
            Text(L("Label")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
            Text(L("Account")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 5)
            Text(L("Projekt")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 5)
            Text(L("Art")).frame(width: 150, alignment: .leading).padding(.leading, 5)
            Text(L("Zählt")).frame(width: 44)
            Text(L("Stunden")).frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 24, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func filtered(_ stats: [Rules.LabelStat]) -> [Rules.LabelStat] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let qTag = Rules.tag(q)
        return stats
            .filter { s in
                guard !q.isEmpty else { return true }
                let i = store.labelInfo[s.label]
                let hay = "\(s.label) \(i?.account ?? "") \(i?.project ?? "")".lowercased()
                return hay.contains(q) || (!qTag.isEmpty && s.label.contains(qTag))
            }
            .sorted { $0.label < $1.label }
    }

    // MARK: Rows

    private func row(_ s: Rules.LabelStat, index: Int, hours: TimeInterval) -> some View {
        let l = s.label
        let info = store.labelInfo[l] ?? LabelInfo()
        let registered = store.labelInfo[l] != nil
        return HoverRow(conflict: false) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Look.palette[index % Rules.paletteSize]).frame(width: 8, height: 8)
                CellBox {
                    HStack(spacing: 0) {
                        Text("#").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                        KeyTextField(
                            text: Binding(get: { editingName == l ? nameDraft : l },
                                          set: { editingName = l; nameDraft = Rules.tag($0) }),
                            font: Look.semibold13,
                            onFocusChange: { focused in
                                if focused {
                                    editingName = l
                                    nameDraft = l
                                    combo = nil
                                } else {
                                    commitName(l)
                                }
                            },
                            onCommand: { cmd in
                                switch cmd {
                                case .enter: NSApp.keyWindow?.makeFirstResponder(nil); return true
                                case .escape:
                                    skipCommit = true
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    return true
                                default: return false
                                }
                            })
                    }
                }
                .help("#\(l)")
                comboField(l, .account, value: info.account, account: info.account)
                comboField(l, .project, value: info.project, account: info.account)
                kindMenu(l)
                Toggle("", isOn: Binding(get: { store.counts(l) }, set: { store.setCounts($0, for: l) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 44)
                    .help(L("Zählt zu Stunden und BT"))
                Text(hours > 0 ? Fmt.duration(hours) : "–")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(hours > 0 ? .primary : .secondary)
                    .frame(width: 64, alignment: .trailing)
                if registered {
                    RowAction(systemImage: "trash", tint: .secondary,
                              help: s.count > 0 ? L("Zuordnung entfernen (%@× verwendet)", "\(s.count)") : L("Label löschen")) {
                        deleteLabel(l, used: s.count > 0)
                    }
                } else {
                    Color.clear.frame(width: 24)
                }
            }
            .padding(.leading, 4)
        } actions: {
            EmptyView()
        }
    }

    private func unlabeledRow(_ hours: TimeInterval) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.18)).frame(width: 8, height: 8)
            Text(L("unverplant")).foregroundStyle(.secondary).padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            Color.clear.frame(width: 194, height: 1)
            Text(Fmt.duration(hours)).font(.system(size: 13).monospacedDigit()).frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 24, height: 1)
        }
        .frame(height: 28)
        .padding(.horizontal, 8)
    }

    private func comboField(_ l: String, _ field: Rules.Field, value: String, account: String) -> some View {
        let target: Target = field == .account ? .account(l) : .project(l)
        let open = combo?.label == l && combo?.field == field
        let items = open ? currentOptions() : []
        return CellBox {
            KeyTextField(
                text: Binding(get: { value }, set: { v in
                    set(l, field, v)
                    combo = Combo(label: l, field: field, index: v.isEmpty ? -1 : 0, typed: true)
                }),
                placeholder: field == .account ? L("Account") : L("Projekt"),
                font: Look.regular13,
                textColor: field == .account ? .labelColor : .secondaryLabelColor,
                // Missing booking target is a problem for work, not for absences.
                placeholderColor: store.kind(l).isAbsence ? .tertiaryLabelColor : NSColor(Look.warningText),
                focus: focusTarget == target ? FocusRequest(id: focusSeq) : nil,
                onFocusChange: { focused in
                    if focused {
                        combo = Combo(label: l, field: field, index: -1, typed: false)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            if combo?.label == l, combo?.field == field, NSApp.keyWindow?.firstResponder is NSTextView == false {
                                combo = nil
                            }
                        }
                    }
                },
                onCommand: { cmd in comboCommand(l, field, cmd, items) })
                .padding(.horizontal, 4)
        }
        .anchorPreference(key: AnchorKey.self, value: .bounds) { open && !items.isEmpty ? $0 : nil }
    }

    /// Kind of the label: work or one of the absences (icon and color in the overview, no reminder).
    private func kindMenu(_ l: String) -> some View {
        let kind = store.kind(l)
        return Menu {
            ForEach(LabelKind.allCases) { k in
                Button { store.setKind(k, for: l) } label: { Label(k.title, systemImage: k.icon) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: kind.icon).foregroundStyle(kind.isAbsence ? kind.color : .secondary)
                Text(kind.title).foregroundStyle(kind.isAbsence ? .primary : .secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .font(.system(size: 13))
        .frame(width: 150, alignment: .leading)
        .padding(.leading, 5)
    }

    private func currentOptions() -> [Rules.Option] {
        guard let combo else { return [] }
        let info = store.labelInfo[combo.label] ?? LabelInfo()
        let value = combo.field == .account ? info.account : info.project
        return Rules.options(combo.field, query: combo.typed ? value : "", account: info.account,
                             excluding: combo.label, registry: store.labelInfo)
    }

    private func comboCommand(_ l: String, _ field: Rules.Field, _ cmd: FieldCommand, _ items: [Rules.Option]) -> Bool {
        let open = combo?.label == l && combo?.field == field
        let idx = open && !items.isEmpty ? min(combo!.index, items.count - 1) : -1
        switch cmd {
        case .down:
            if !open { combo = Combo(label: l, field: field, index: 0, typed: false) }
            else if !items.isEmpty { combo?.index = (idx + 1) % items.count }
            return true
        case .up:
            guard open, !items.isEmpty else { return false }
            combo?.index = idx <= 0 ? items.count - 1 : idx - 1
            return true
        case .enter:
            if open, idx >= 0 { pickOption(l, field, items[idx]) }
            else {
                combo = nil
                if field == .account { focus(.project(l)) } else { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            return true
        case .escape:
            guard open else { return false }
            combo = nil
            return true
        case .tab:
            if open, idx >= 0 { pickOption(l, field, items[idx], jump: false) }
            return false
        default:
            return false
        }
    }

    private func pickOption(_ l: String, _ field: Rules.Field, _ o: Rules.Option, jump: Bool = true) {
        var info = store.labelInfo[l] ?? LabelInfo()
        if field == .account {
            info.account = o.value
        } else {
            info.project = o.value
            // Choosing a project without an account takes its account along.
            if info.account.isEmpty, !o.account.isEmpty { info.account = o.account }
        }
        store.setInfo(info, for: l)
        combo = nil
        if field == .account, jump { focus(.project(l)) }
    }

    private func set(_ l: String, _ field: Rules.Field, _ value: String) {
        var info = store.labelInfo[l] ?? LabelInfo()
        if field == .account { info.account = value } else { info.project = value }
        store.setInfo(info, for: l)
    }

    @ViewBuilder
    private func options(_ anchor: Anchor<CGRect>?) -> some View {
        if let anchor, let combo {
            let items = currentOptions()
            let idx = items.isEmpty ? -1 : min(combo.index, items.count - 1)
            let account = store.labelInfo[combo.label]?.account ?? ""
            let heading = combo.field == .account
                ? (combo.typed ? L("Passende Accounts") : L("Accounts"))
                : (combo.typed ? L("Passende Projekte") : account.isEmpty ? L("Alle Projekte") : L("Projekte · %@", account))
            GeometryReader { geo in
                let r = geo[anchor]
                let width: CGFloat = 240
                let height = CGFloat(items.count) * 41 + 30
                let below = r.maxY + 4 + height <= geo.size.height - 8
                ZStack(alignment: .topLeading) {
                    Color.clear
                    SuggestionList(
                        heading: heading,
                        items: items.map { .init(id: $0.id, title: $0.value, meta: $0.meta, color: nil, isNew: $0.isNew) },
                        selected: idx,
                        onPick: { pickOption(combo.label, combo.field, items[$0]) })
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.leading) { _ in -min(r.minX, geo.size.width - 8 - width) }
                        .alignmentGuide(.top) { d in below ? -(r.maxY + 4) : d.height - (r.minY - 4) }
                }
            }
        }
    }

    // MARK: Actions

    private func focus(_ t: Target) {
        focusSeq += 1
        focusTarget = t
    }

    private func createLabel() {
        let l = store.addLabel(query)
        query = ""
        if !l.isEmpty { DispatchQueue.main.async { focus(.account(l)) } }
    }

    private func commitName(_ l: String) {
        defer { editingName = nil; skipCommit = false }
        guard editingName == l, !skipCommit else { return }
        let before = store.snapshot
        let new = store.renameLabel(l, to: nameDraft)
        guard new != l else { return }
        show(Toast(message: L("#%1$@ heißt jetzt #%2$@", l, new), undo: { store.restore(before) }))
    }

    private func show(_ t: Toast) {
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if toast == t { toast = nil } }
    }

    private func deleteLabel(_ l: String, used: Bool) {
        guard let info = store.labelInfo[l] else { return }
        store.removeLabelInfo(l)
        show(Toast(message: used ? L("#%@: Zuordnung entfernt", l) : L("#%@ gelöscht", l),
                   undo: { store.setInfo(info, for: l) }))
    }

    private func toastView(_ t: Toast) -> some View {
        HStack(spacing: 8) {
            Text(t.message).lineLimit(1)
            Spacer()
            Button(L("Rückgängig")) {
                t.undo()
                toast = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 0.39, green: 0.82, blue: 1))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16).opacity(0.92)))
        .frame(maxWidth: 420)
        .padding(.bottom, 8)
    }

    /// Hours per account, for booking.
    @ViewBuilder
    private func accountSummary(_ worked: [String: TimeInterval]) -> some View {
        let byAccount = Dictionary(grouping: worked.filter { $0.value > 0 }) { item in
            store.labelInfo[item.key]?.account.isEmpty == false ? store.labelInfo[item.key]!.account : L("Ohne Account")
        }
        .mapValues { $0.reduce(0) { $0 + $1.value } }
        .sorted { $0.value > $1.value }
        if !byAccount.isEmpty {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(byAccount, id: \.key) { account, hours in
                        HStack(spacing: 6) {
                            Text(account).fontWeight(.medium)
                            Text("\(Fmt.duration(hours)) h · \(Fmt.bt(hours))").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

/// Cell look of the editor: transparent, border on hover, accent border while editing.
struct CellBox<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color(nsColor: .controlBackgroundColor) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(hovering ? Color.primary.opacity(0.16) : .clear))
            .onHover { hovering = $0 }
    }
}
