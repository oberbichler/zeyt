import SwiftUI

/// The popover: one day as a list of start points, editable in place (see docs of the UI concept).
struct DayView: View {
    @ObservedObject var store: EntryStore
    @ObservedObject var state: AppState

    @State private var day = Calendar.current.startOfDay(for: Date()) {
        didSet { followsToday = Calendar.current.isDateInToday(day) }
    }
    /// Today was shown last: reopening shows today again, even on the next day.
    @State private var followsToday = true
    /// Input time; nil = follows "now" (rounded to 5 minutes).
    @State private var draftTime: Date?
    @State private var draftLabel = ""
    @State private var draftComment = ""
    /// Which part of the input capsule has focus (time, label, comment) – one ring for all.
    @State private var inputFocus: Set<String> = []
    @State private var ac: Ac?
    @State private var focusedKey: Key?
    @State private var focusTarget: FocusTarget?
    @State private var focusSeq = 0
    @State private var pendingCaret: FocusRequest.Caret = .end
    /// Programmatic focus (popover opened, entry started) doesn't pop up the label list.
    @State private var quietFocus = false
    @State private var toast: Toast?
    @State private var pendingPaste: PendingPaste?
    @State private var pastingRange = false
    /// Bumped to make fields re-read their (unchanged) value, e.g. after a rejected character.
    @State private var refresh = 0

    /// Open autocomplete list: which field, selected index, filtered by typed text or not.
    struct Ac: Equatable {
        var key: Key
        var index: Int
        var typed: Bool
    }

    enum Key: Hashable { case draft, row(UUID) }
    enum FocusTarget: Hashable { case draftTime, draftLabel, draftComment, rowTime(UUID), rowLabel(UUID), rowComment(UUID) }
    typealias Column = LineNav.Column

    struct Toast: Equatable {
        let text: String
        var undo: (() -> Void)?
        let id = UUID()
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    /// A paste that waits for "Ersetzen / Ergänzen" because target days already have entries.
    struct PendingPaste {
        let items: [DayText.Item]
        let days: [Date]
        let filled: Int
    }

    /// Everything derived for one render.
    struct Ctx {
        let now: Date
        let entries: [Entry]
        let blocks: [Block]
        let colors: [String: Color]
        let stats: [Rules.LabelStat]
        let draftDate: Date
        let resume: Entry?
        let conflicts: Set<Date>
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let ctx = makeCtx(now: context.date)
            let _ = refresh
            VStack(spacing: 0) {
                header(ctx)
                Divider().opacity(0.6)
                if ctx.blocks.contains(where: { $0.duration > 0 }) { dayBar(ctx) }
                list(ctx)
                if let toast { toastView(toast) }
                if let p = pendingPaste {
                    PasteConfirmBar(pending: p, describe: shortDay) { mode in
                        pendingPaste = nil
                        if let mode { performPaste(p.items, on: p.days, mode: mode) }
                        focus(.draftLabel, quiet: true)
                    }
                    .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
                } else if pastingRange {
                    PasteRangeForm(start: Calendar.current.date(byAdding: .day, value: 1, to: day)!) { days in
                        pastingRange = false
                        if let days { paste(on: days) }
                        if pendingPaste == nil { focus(.draftLabel, quiet: true) }
                    }
                    .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
                } else {
                    inputBar(ctx)
                }
            }
            .frame(width: 360, height: 620)
            .background(Look.panel)
            .overlayPreferenceValue(AnchorKey.self) { anchor in suggestions(anchor, ctx) }
            .background(shortcuts)
        }
        .onAppear {
            focus(.draftLabel, quiet: true)
        }
        .onChange(of: state.openCount) {
            // A day picked by hand stays picked; "today" follows the date (also past midnight).
            if followsToday { day = Calendar.current.startOfDay(for: Date()) }
            draftTime = nil
            ac = nil
            pendingPaste = nil
            pastingRange = false
            focus(.draftLabel, quiet: true)
        }
    }

    private func makeCtx(now: Date) -> Ctx {
        let entries = store.entries(on: day)
        let stats = store.labelStats
        var colors: [String: Color] = [:]
        for (i, s) in stats.enumerated() { colors[s.label] = Look.palette[i % Rules.paletteSize] }
        let draftDate = draftTime ?? Rules.roundedNow(now, on: day)
        let starts = entries.map(\.date)
        return Ctx(
            now: now, entries: entries, blocks: Block.compute(entries, now: now), colors: colors, stats: stats,
            draftDate: draftDate, resume: Rules.resume(entries, at: draftDate, now: now),
            conflicts: Set(starts.filter { d in starts.filter { $0 == d }.count > 1 }))
    }

    /// Labels left out of hours and BT, while that setting is on.
    private var uncounted: Set<String> { state.uncountedEnabled ? Set(store.uncounted) : [] }

    private func color(_ label: String, _ ctx: Ctx) -> Color {
        let kind = LabelKind.of(label)
        if kind.isAbsence { return kind.color }
        return label.isEmpty ? Color.primary.opacity(0.18) : ctx.colors[label] ?? Look.palette[5]
    }

    // MARK: Header

    private func header(_ ctx: Ctx) -> some View {
        let strip = stripDays(ctx.now)
        let week = weekDays(ctx.now)
        let weekTotal = week.reduce(0) { $0 + $1.worked }
        let dayTotal = Block.worked(ctx.blocks, uncounted: uncounted)
        return VStack(spacing: 10) {
            // Title centered; "Heute" and the gear in equally wide side slots.
            ZStack {
                Text(Fmt.longDay.string(from: day))
                    .font(.system(size: 14, weight: .semibold))
                HStack {
                    if !isToday {
                        Button { goToday() } label: {
                            Text(L("Heute"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L("Zu heute springen"))
                    }
                    Spacer()
                    GearButton(unassigned: store.unassignedCount) { showMenu() }
                }
            }
            HStack(spacing: 0) {
                IconButton(systemImage: "chevron.left", help: L("Vortag (⌘[)")) { shiftDay(-1) }
                ForEach(Array(strip.enumerated()), id: \.element.id) { i, d in
                    let newWeek = i > 0 && Calendar.current.component(.weekday, from: d.date) == 2
                    if newWeek {
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 30)
                    }
                    WeekDayCell(day: d, selected: i == 3) { selectDay(d.date) }
                        .contextMenu {
                            Button(L("Tag kopieren")) { copyDay(d.date) }
                            Button(L("Einfügen")) { paste(on: [d.date]) }
                            Button(L("In mehrere Tage einfügen …")) { selectDay(d.date); pastingRange = true }
                        }
                }
                IconButton(systemImage: "chevron.right", help: L("Folgetag (⌘])")) { shiftDay(1) }
            }
            HStack(spacing: 0) {
                StatView(caption: isToday ? L("Heute") : L("Tag"), value: dayTotal)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 28)
                StatView(caption: L("KW %@", "\(Rules.isoWeek(day))"), value: weekTotal)
                    .help(weekAbsences(week))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .padding(.horizontal, 8)
    }

    struct WeekDay: Identifiable {
        let date: Date
        let worked: TimeInterval
        let absence: Absence?
        /// Only absence entries that day: the icon replaces the hours.
        let onlyAbsence: Bool
        var id: Date { date }
    }

    private func dayInfo(_ d: Date, _ now: Date) -> WeekDay {
        let entries = store.entries(on: d)
        let tasks = entries.filter { !$0.isStop }
        let absence = tasks.lazy.compactMap(\.absence).first
        return WeekDay(date: d, worked: Block.worked(Block.compute(entries, now: now), uncounted: uncounted),
                       absence: absence,
                       onlyAbsence: absence != nil && tasks.allSatisfy { $0.absence != nil })
    }

    /// Seven days with the selected one in the middle.
    private func stripDays(_ now: Date) -> [WeekDay] {
        (-3...3).map { dayInfo(Calendar.current.date(byAdding: .day, value: $0, to: day)!, now) }
    }

    /// Monday to Sunday of the selected day's ISO week.
    private func weekDays(_ now: Date) -> [WeekDay] {
        let start = Calendar(identifier: .iso8601).dateInterval(of: .weekOfYear, for: day)!.start
        return (0..<7).map { dayInfo(Calendar.current.date(byAdding: .day, value: $0, to: start)!, now) }
    }

    private func weekAbsences(_ week: [WeekDay]) -> String {
        var counts: [Absence: Int] = [:]
        for d in week { if let a = d.absence { counts[a, default: 0] += 1 } }
        let parts = Absence.allCases.compactMap { a in counts[a].map { L("%1$@× %2$@", "\($0)", a.title) } }
        return parts.isEmpty ? L("Keine Abwesenheiten in dieser Woche") : parts.joined(separator: " · ")
    }

    // MARK: Day bar

    private func dayBar(_ ctx: Ctx) -> some View {
        DayBar(blocks: ctx.blocks) { color($0, ctx) }
    }

    // MARK: List

    private func list(_ ctx: Ctx) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
                if !state.notificationsAllowed, state.reminder.enabled {
                    NotificationsBanner()
                        .padding(.vertical, 4)
                }
                if ctx.blocks.isEmpty {
                    VStack(spacing: 10) {
                        Text(L("Noch keine Einträge.\nLabel eingeben und Enter drücken."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                        let source = store.lastWorkDay(before: day)
                        let sourceItems = source.flatMap { DayText.parse(DayText.make(store.entries(on: $0))) }
                        if let source, let sourceItems {
                            emptyDayButton(L("Wie %@ übernehmen", shortDay(source)), systemImage: "doc.on.doc",
                                           help: L("Alle Einträge von %@ mit gleichen Zeiten übernehmen", shortDay(source))) {
                                performPaste(sourceItems, on: [day], mode: .append)
                            }
                        }
                        // Skipped when it would do the same as the button above.
                        if let clip = DayClipboard.day, clip != sourceItems {
                            emptyDayButton(L("Kopierten Tag einfügen"), systemImage: "doc.on.clipboard",
                                           help: L("%@ Einträge aus der Zwischenablage einfügen (⌥⌘V)", "\(clip.count)")) {
                                performPaste(clip, on: [day], mode: .append)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
                ForEach(ctx.blocks) { b in row(b, ctx).id(b.id) }
                if !ctx.conflicts.isEmpty {
                    Text(L("Markierte Zeiten prüfen."))
                        .font(.system(size: 12))
                        .foregroundStyle(Look.warningText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: focusSeq) {
            // A row reached with the arrow keys may be scrolled out of sight.
            switch focusTarget {
            case .rowTime(let id), .rowLabel(let id), .rowComment(let id): withAnimation { proxy.scrollTo(id) }
            default: break
            }
        }
        }
    }

    private func row(_ b: Block, _ ctx: Ctx) -> some View {
        let e = b.entry
        let conflict = ctx.conflicts.contains(e.date)
        let isLast = ctx.blocks.last?.id == b.id
        let key = Key.row(e.id)
        let items = suggestions(for: key, ctx)
        let labelColor = color(e.label, ctx)
        let durText: String = b.kind == .end ? "" : b.isOpen ? L("offen") : Fmt.duration(max(0, b.duration))
        let durColor: Color = conflict ? Look.warningText
            : b.running || (isLast && b.kind == .task) ? .accentColor : b.kind == .pause ? .secondary : .primary

        return HoverRow(conflict: conflict) {
            HStack(spacing: 2) {
                TimeField(date: e.date, focus: request(.rowTime(e.id)), onCommit: { new in
                    store.update(Entry(id: e.id, date: new, text: e.text))
                }, onTab: {
                    focus(.rowLabel(e.id))
                    return true
                }, onNavigate: { cmd in
                    cmd == .newLineBelow ? insertBelow(e, ctx) : navigate(from: .rowTime(e.id), cmd, ctx)
                }, onFocusChange: { if $0 { otherFieldFocused() } })
                .frame(width: RowMetrics.timeWidth)
                .padding(.trailing, 2)
                KindDot(isTask: b.kind == .task, color: labelColor)
                // One field for tasks and stops, so typing a label into a stop turns it into a task
                // without the field being replaced under the caret.
                TagField(
                    style: .cell,
                    label: Binding(get: { e.isStop ? "" : e.label }, set: { rowLabelChanged(e.id, $0, ctx) }),
                    comment: Binding(get: { e.isStop ? "" : e.title }, set: { rowCommentChanged(e.id, $0) }),
                    labelPlaceholder: b.kind == .task ? L("unverplant") : b.kind == .pause ? L("pause") : L("feierabend"),
                    showsComment: !e.isStop && (!e.label.isEmpty || !e.title.isEmpty),
                    ghost: ghost(for: key, items),
                    plainWhenEmpty: e.isStop,
                    labelFocus: request(.rowLabel(e.id)),
                    commentFocus: request(.rowComment(e.id)),
                    onLabelFocus: { focused in
                        // No label suggestions on a stop before "#" is typed.
                        if focused, e.isStop { quietFocus = true }
                        labelFocusChanged(key, focused)
                    },
                    onCommentFocus: { if $0 { otherFieldFocused() } },
                    onLabelCommand: { cmd in
                        if cmd == .newLineBelow { return insertBelow(e, ctx) }
                        if cmd == .deleteAtStart, !e.isStop { return makeStop(e, isLast: isLast) }
                        return labelCommand(key, cmd, items, onEnter: { endEditing() }, onEscape: { nil })
                            || navigate(from: .rowLabel(e.id), cmd, ctx)
                    },
                    onCommentCommand: { cmd in
                        switch cmd {
                        case .deleteAtStart: focus(.rowLabel(e.id)); return true
                        case .enter: endEditing(); return true
                        case .newLineBelow: return insertBelow(e, ctx)
                        default: return navigate(from: .rowComment(e.id), cmd, ctx)
                        }
                    },
                    onBackgroundTap: { focus(e.label.isEmpty ? .rowLabel(e.id) : .rowComment(e.id)) })
                .anchorPreference(key: AnchorKey.self, value: .bounds) { ac?.key == key && !items.isEmpty ? $0 : nil }
                .help(e.isStop ? L("# tippen macht daraus eine Tätigkeit")
                      : (e.label.isEmpty ? L("unverplant") : "#" + e.label) + (e.title.isEmpty ? "" : " " + e.title))
                Text(durText)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(durColor)
                    .frame(width: RowMetrics.durationWidth, alignment: .trailing)
                    .padding(.trailing, 2)
            }
        } actions: {
            if b.kind == .task {
                RowAction(systemImage: "plus.square.on.square", tint: .accentColor,
                          help: L("Duplizieren – startet zur Eingabezeit")) {
                    store.add(date: ctx.draftDate, text: e.text, dedupe: false)
                }
            }
            RowAction(systemImage: "trash", tint: Look.warningText, help: L("Eintrag löschen")) { delete(b) }
        }
    }

    // MARK: Input bar

    private func inputBar(_ ctx: Ctx) -> some View {
        let key = Key.draft
        let items = suggestions(for: key, ctx)
        let stopTitle = Rules.stopIsEndOfDay(ctx.entries, at: ctx.draftDate) ? L("Feierabend") : L("Pause")
        return VStack(spacing: 0) {
            Divider()
            // One capsule: time │ #label comment  ▶ ■ – one frame, one focus ring, concentric radii.
            HStack(spacing: 0) {
                TimeField(date: ctx.draftDate, bare: true, focus: request(.draftTime),
                          onCommit: { draftTime = $0 },
                          onEnter: { submit(viaEnter: true, ctx) },
                          onTab: { focus(.draftLabel); return true },
                          onNavigate: { navigate(from: .draftTime, $0, ctx) },
                          onFocusChange: { focused in
                              setInputFocus("time", focused)
                              if focused { otherFieldFocused() }
                          })
                    .frame(width: 50)
                    .padding(.leading, 8)
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 16)
                    .padding(.horizontal, 4)
                TagField(
                    style: .input,
                    label: Binding(get: { draftLabel }, set: { draftLabelChanged($0, ctx) }),
                    comment: $draftComment,
                    labelPlaceholder: ctx.resume?.label ?? "label",
                    commentPlaceholder: draftLabel.isEmpty && ctx.resume != nil ? L("Enter = fortsetzen") : L("Kommentar"),
                    commentDimmed: draftLabel.isEmpty && ctx.resume == nil,
                    ghost: ghost(for: key, items),
                    labelFocus: request(.draftLabel),
                    commentFocus: request(.draftComment),
                    onLabelFocus: { labelFocusChanged(key, $0); setInputFocus("label", $0) },
                    onCommentFocus: { focused in
                        setInputFocus("comment", focused)
                        if focused { otherFieldFocused() }
                        // Without a label there is no comment: jump back into the label.
                        if focused, draftLabel.isEmpty, ctx.resume == nil { focus(.draftLabel) }
                    },
                    onLabelCommand: { cmd in
                        // The input bar is the new line already: Shift+Enter is Enter there.
                        let cmd = cmd == .newLineBelow ? FieldCommand.enter : cmd
                        return labelCommand(key, cmd, items, onEnter: { submit(viaEnter: true, ctx) }, onEscape: {
                            guard !draftLabel.isEmpty || !draftComment.isEmpty else { return nil }
                            return { draftLabel = ""; draftComment = "" }
                        }) || navigate(from: .draftLabel, cmd, ctx)
                    },
                    onCommentCommand: { cmd in
                        switch cmd {
                        case .deleteAtStart: focus(.draftLabel); return true
                        case .enter, .newLineBelow: submit(viaEnter: true, ctx); return true
                        default: return navigate(from: .draftComment, cmd, ctx)
                        }
                    },
                    onBackgroundTap: { focus(draftLabel.isEmpty ? .draftLabel : .draftComment) })
                .anchorPreference(key: AnchorKey.self, value: .bounds) { ac?.key == key && !items.isEmpty ? $0 : nil }
                CircleButton(systemImage: "play.fill", size: 10, tint: .white, fill: .accentColor) {
                    submit(viaEnter: false, ctx)
                }
                .help(draftLabel.isEmpty ? L("Unverplant starten") : L("Starten: #%@", draftLabel))
                .padding(.leading, 4)
                CircleButton(systemImage: "stop.fill", size: 9, tint: .primary, fill: Color.primary.opacity(0.08)) { stop(ctx) }
                    .help(stopTitle)
                    .padding(.leading, 4)
                    .padding(.trailing, 4)
            }
            .frame(height: 34)
            // Border and focus ring as stacked fills: strokes on a capsule leave artifacts at the ends.
            .background {
                let focused = inputEngaged
                ZStack {
                    if focused { Capsule().fill(Color.accentColor.opacity(0.3)).padding(-3) }
                    Capsule().fill(focused ? Color.accentColor : Color.primary.opacity(0.12))
                    Capsule().fill(Color(nsColor: .controlBackgroundColor)).padding(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        // Same as the panel, so the white/dark fields stand out like in the template.
        .background(Look.panel)
    }

    /// Focus ring only while working with the input: the label field is focused whenever the popover
    /// opens, so a resting, empty label field keeps the plain border.
    private var inputEngaged: Bool {
        guard !inputFocus.isEmpty else { return false }
        return inputFocus != ["label"] || !draftLabel.isEmpty || !draftComment.isEmpty
            || ac?.key == .draft || draftTime != nil
    }

    private func setInputFocus(_ part: String, _ focused: Bool) {
        if focused { inputFocus.insert(part) } else { inputFocus.remove(part) }
    }

    // MARK: Autocomplete

    private func currentLabel(_ key: Key) -> String {
        switch key {
        case .draft: return draftLabel
        case .row(let id): return store.entries.first { $0.id == id }?.label ?? ""
        }
    }

    private func suggestions(for key: Key, _ ctx: Ctx) -> [Rules.Suggestion] {
        guard let ac, ac.key == key else { return [] }
        return Rules.suggest(ac.typed ? currentLabel(key) : "", stats: ctx.stats, registry: store.labelInfo)
    }

    private func selectedIndex(_ key: Key, _ items: [Rules.Suggestion]) -> Int {
        guard let ac, ac.key == key, !items.isEmpty else { return -1 }
        return min(ac.index, items.count - 1)
    }

    /// Rest of the selected suggestion, shown grey after the typed text.
    private func ghost(for key: Key, _ items: [Rules.Suggestion]) -> String {
        let q = currentLabel(key)
        let i = selectedIndex(key, items)
        guard ac?.typed == true, !q.isEmpty, i >= 0 else { return "" }
        let s = items[i].label
        return s.lowercased().hasPrefix(q.lowercased()) ? String(s.dropFirst(q.count)) : ""
    }

    @ViewBuilder
    private func suggestions(_ anchor: Anchor<CGRect>?, _ ctx: Ctx) -> some View {
        if let anchor, let ac {
            let items = suggestions(for: ac.key, ctx)
            let selected = selectedIndex(ac.key, items)
            GeometryReader { geo in
                let r = geo[anchor]
                let width: CGFloat = ac.key == .draft ? max(r.width, 236) : 236
                let x = min(max(8, r.minX), geo.size.width - 8 - width)
                let height = CGFloat(items.count) * 41 + 66
                let below = ac.key != .draft && r.maxY + 4 + height <= geo.size.height - 8
                ZStack(alignment: .topLeading) {
                    Color.clear
                    SuggestionList(
                        heading: ac.typed && !currentLabel(ac.key).isEmpty ? L("Passende Labels") : L("Zuletzt verwendet"),
                        items: items.map {
                            .init(id: $0.id, title: "#" + $0.label, meta: $0.meta,
                                  color: $0.isNew ? nil : color($0.label, ctx), isNew: $0.isNew,
                                  icon: LabelKind.of($0.label).isAbsence ? LabelKind.of($0.label).icon : nil)
                        },
                        selected: selected,
                        onPick: { pick(ac.key, items[$0], focusComment: true) },
                        footer: (L("Labels verwalten …"), { state.openLabels() }))
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.leading) { _ in -x }
                        .alignmentGuide(.top) { d in below ? -(r.maxY + 4) : d.height - (r.minY - 4) }
                }
            }
        }
    }

    /// A time or comment field took the focus: the label list goes at once (it lingers briefly
    /// after a label loses focus only so that a click into the list still lands).
    private func otherFieldFocused() {
        focusedKey = nil
        ac = nil
    }

    private func labelFocusChanged(_ key: Key, _ focused: Bool) {
        if focused {
            focusedKey = key
            if quietFocus { quietFocus = false } else { ac = Ac(key: key, index: -1, typed: false) }
        } else {
            if focusedKey == key { focusedKey = nil }
            // Close a bit later, so that a click into the list still lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if focusedKey != key, ac?.key == key { ac = nil }
            }
        }
    }

    /// Shared key handling of label fields. Returns whether the key was handled.
    private func labelCommand(_ key: Key, _ cmd: FieldCommand, _ items: [Rules.Suggestion],
                              onEnter: () -> Void, onEscape: () -> (() -> Void)?) -> Bool {
        let open = ac?.key == key && !items.isEmpty
        let idx = selectedIndex(key, items)
        switch cmd {
        case .down:
            // A closed list leaves ↓ to the line navigation.
            guard open else { return false }
            ac?.index = (idx + 1) % items.count
            return true
        case .up:
            guard open else { return false }
            ac?.index = idx <= 0 ? items.count - 1 : idx - 1
            return true
        case .enter:
            if open, idx >= 0 { pick(key, items[idx], focusComment: true) } else { ac = nil; onEnter() }
            return true
        case .escape:
            if open { ac = nil; return true }
            if let clear = onEscape() { clear(); return true }
            return false
        case .tab:
            if open, idx >= 0 { pick(key, items[idx], focusComment: true); return true }
            return false
        case .rightAtEnd:
            guard !ghost(for: key, items).isEmpty else { return false }
            pick(key, items[idx], focusComment: true)
            return true
        case .deleteAtStart, .leftAtStart, .newLineBelow:
            return false
        }
    }

    /// Backspace on the "#": the task becomes a break (the last line of the day: end of day).
    /// Label and comment go, so the toast offers to undo it; the field keeps the focus.
    private func makeStop(_ e: Entry, isLast: Bool) -> Bool {
        let stop = isLast ? "feierabend" : "pause"
        ac = nil
        store.update(Entry(id: e.id, date: e.date, text: stop))
        let was = e.label.isEmpty ? L("unverplant") : "#" + e.label
        let time = Fmt.time.string(from: e.date)
        showToast(isLast ? L("%1$@ %2$@ → Feierabend", was, time) : L("%1$@ %2$@ → Pause", was, time)) {
            store.update(e)
        }
        return true
    }

    /// Shift+Enter in a row: a new, empty line below it with its hour selected, ready for the time.
    private func insertBelow(_ e: Entry, _ ctx: Ctx) -> Bool {
        let next = ctx.entries.first { $0.date > e.date }?.date
        let date = Rules.insertTime(after: e.date, next: next, now: ctx.now)
        guard let added = store.add(date: date, text: "", dedupe: false) else { return false }
        ac = nil
        focus(.rowTime(added.id), caret: .start)
        return true
    }

    private func pick(_ key: Key, _ s: Rules.Suggestion, focusComment: Bool) {
        let label = Rules.tag(s.label)
        switch key {
        case .draft:
            draftLabel = label
            if focusComment { focus(.draftComment, caret: .start) }
        case .row(let id):
            if let e = store.entries.first(where: { $0.id == id }) {
                store.update(Entry(id: id, date: e.date, text: Entry.compose(label: label, description: e.isStop ? "" : e.title)))
            }
            if focusComment { focus(.rowComment(id), caret: .start) }
        }
        ac = nil
    }

    // MARK: Editing

    private func draftLabelChanged(_ raw: String, _ ctx: Ctx) {
        if let split = Rules.splitLabel(raw) {
            // Space accepts the selected suggestion and jumps into the comment; pasted "label comment" is split.
            var label = split.label
            let items = suggestions(for: .draft, ctx)
            let i = selectedIndex(.draft, items)
            if split.comment.isEmpty, ac?.typed == true, i >= 0 { label = Rules.tag(items[i].label) }
            guard !label.isEmpty else { refresh += 1; return }
            draftLabel = label
            draftComment = (split.comment + " " + draftComment).trimmingCharacters(in: .whitespaces)
            ac = nil
            focus(.draftComment, caret: split.comment.isEmpty ? .start : .end)
            return
        }
        draftLabel = Rules.tag(raw)
        refresh += 1
        ac = Ac(key: .draft, index: raw.isEmpty ? -1 : 0, typed: true)
    }

    private func rowLabelChanged(_ id: UUID, _ raw: String, _ ctx: Ctx) {
        guard let e = store.entries.first(where: { $0.id == id }) else { return }
        // A stop only turns into a task with "#" (then the label follows); other keys are refused.
        if e.isStop, !raw.hasPrefix("#") {
            NSSound.beep()
            refresh += 1
            return
        }
        let key = Key.row(id)
        if let split = Rules.splitLabel(raw) {
            var label = split.label
            let items = suggestions(for: key, ctx)
            let i = selectedIndex(key, items)
            if split.comment.isEmpty, ac?.typed == true, i >= 0 { label = Rules.tag(items[i].label) }
            guard !label.isEmpty else { refresh += 1; return }
            let comment = (split.comment + " " + (e.isStop ? "" : e.title)).trimmingCharacters(in: .whitespaces)
            store.update(Entry(id: id, date: e.date, text: Entry.compose(label: label, description: comment)))
            ac = nil
            focus(.rowComment(id), caret: split.comment.isEmpty ? .start : .end)
            return
        }
        // In a stop the text is "pause"/"feierabend", not a comment: a label makes it a task.
        store.update(Entry(id: id, date: e.date, text: Entry.compose(label: Rules.tag(raw), description: e.isStop ? "" : e.title)))
        refresh += 1
        ac = Ac(key: key, index: raw.isEmpty ? -1 : 0, typed: true)
    }

    private func rowCommentChanged(_ id: UUID, _ comment: String) {
        guard let e = store.entries.first(where: { $0.id == id }) else { return }
        store.update(Entry(id: id, date: e.date, text: Entry.compose(label: e.label, description: comment)))
    }

    /// ▶ starts exactly what was typed (no label = unplanned); Enter on an empty label continues.
    private func submit(viaEnter: Bool, _ ctx: Ctx) {
        if viaEnter, draftLabel.isEmpty, let r = ctx.resume {
            store.add(date: ctx.draftDate,
                      text: Entry.compose(label: r.label, description: draftComment.isEmpty ? r.title : draftComment),
                      dedupe: false)
        } else {
            store.add(date: ctx.draftDate,
                      text: draftLabel.isEmpty ? "" : Entry.compose(label: draftLabel, description: draftComment),
                      dedupe: false)
        }
        draftLabel = ""
        draftComment = ""
        draftTime = nil
        ac = nil
        // Enter: straight on with the time of the next entry (its hour); ▶ leaves the label ready.
        if viaEnter { focus(.draftTime, caret: .start) } else { focus(.draftLabel, quiet: true) }
    }

    private func stop(_ ctx: Ctx) {
        let end = Rules.stopIsEndOfDay(ctx.entries, at: ctx.draftDate)
        store.add(date: ctx.draftDate, text: end ? "feierabend" : "pause", dedupe: false)
        draftTime = nil
    }

    private func delete(_ b: Block) {
        let e = b.entry
        let time = Fmt.time.string(from: e.date)
        let text = switch b.kind {
        case .task: L("%1$@ %2$@ gelöscht", e.label.isEmpty ? L("unverplant") : "#" + e.label, time)
        case .pause: L("Pause %@ gelöscht", time)
        case .end: L("Feierabend %@ gelöscht", time)
        }
        store.delete(e)
        showToast(text) { store.restore(e) }
    }

    private func showToast(_ text: String, undo: (() -> Void)? = nil) {
        let t = Toast(text: text, undo: undo)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if toast == t { toast = nil } }
    }

    // MARK: Copy & paste days

    /// "Mo 12.10."
    private func shortDay(_ d: Date) -> String {
        DayNames.short(d)
    }

    private func copyDay(_ d: Date) {
        let entries = store.entries(on: d)
        guard !entries.isEmpty else { return showToast(L("%@ hat keine Einträge", shortDay(d))) }
        DayClipboard.copy(entries)
        showToast(L("%1$@ kopiert · %2$@ Einträge", shortDay(d), "\(entries.count)"))
    }

    /// Pastes the clipboard; asks first if a target day already has entries.
    private func paste(on days: [Date]) {
        guard let items = DayClipboard.items else {
            return showToast(L("Zwischenablage enthält keinen Tag (Zeilen wie „08:00 #label“)"))
        }
        guard !days.isEmpty else { return showToast(L("Keine Tage im Zeitraum")) }
        let filled = days.filter { !store.entries(on: $0).isEmpty }.count
        if filled == 0 {
            performPaste(items, on: days, mode: .append)
        } else {
            ac = nil
            pendingPaste = PendingPaste(items: items, days: days, filled: filled)
        }
    }

    private func performPaste(_ items: [DayText.Item], on days: [Date], mode: EntryStore.PasteMode) {
        let result = store.paste(items, on: days, mode: mode)
        guard !result.added.isEmpty else { return showToast(L("Nichts eingefügt – alle Tage hatten schon Einträge")) }
        if days.count == 1 { selectDay(days[0]) }
        let pasted = Set(result.added.map { Calendar.current.startOfDay(for: $0.date) }).count
        showToast(pasted == 1 ? L("%@ eingefügt", shortDay(result.added[0].date)) : L("In %@ Tage eingefügt", "\(pasted)")) {
            store.undo(result)
        }
    }

    /// For an empty day: take over the last day with work.
    private func emptyDayButton(_ title: String, systemImage: String, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toastView(_ t: Toast) -> some View {
        HStack(spacing: 8) {
            Text(t.text).lineLimit(1).truncationMode(.tail)
            Spacer()
            if let undo = t.undo {
                Button(L("Rückgängig")) {
                    undo()
                    toast = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.39, green: 0.82, blue: 1))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            } else {
                Color.clear.frame(width: 1, height: 26)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16).opacity(0.92)))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: Focus & navigation

    private func focus(_ target: FocusTarget, caret: FocusRequest.Caret = .end, quiet: Bool = false) {
        quietFocus = quiet
        focusSeq += 1
        focusTarget = target
        pendingCaret = caret
    }

    /// Arrow keys across the fields as if the day were lines of text: ← and → at the edge of a field
    /// go to the neighbouring field of the line, ↑ and ↓ to the same field of the line above or below
    /// (the input bar is the last line). Returns whether the key moved the focus.
    private func navigate(from target: FocusTarget, _ cmd: FieldCommand, _ ctx: Ctx) -> Bool {
        enum Line: Equatable { case entry(UUID), draft }
        let lines: [Line] = ctx.blocks.map { .entry($0.entry.id) } + [.draft]
        func columns(_ line: Line) -> [Column] {
            guard case .entry(let id) = line else { return [.time, .label, .comment] }
            guard let e = ctx.entries.first(where: { $0.id == id }) else { return [.time] }
            if e.isStop { return [.time, .label] }
            // A row without label and comment shows no comment field.
            return e.label.isEmpty && e.title.isEmpty ? [.time, .label] : [.time, .label, .comment]
        }
        func field(_ line: Line, _ column: Column) -> FocusTarget {
            switch (line, column) {
            case (.draft, .time): return .draftTime
            case (.draft, .label): return .draftLabel
            case (.draft, .comment): return .draftComment
            case (.entry(let id), .time): return .rowTime(id)
            case (.entry(let id), .label): return .rowLabel(id)
            case (.entry(let id), .comment): return .rowComment(id)
            }
        }
        let (line, column): (Line, Column) = switch target {
        case .draftTime: (.draft, .time)
        case .draftLabel: (.draft, .label)
        case .draftComment: (.draft, .comment)
        case .rowTime(let id): (.entry(id), .time)
        case .rowLabel(let id): (.entry(id), .label)
        case .rowComment(let id): (.entry(id), .comment)
        }
        guard let i = lines.firstIndex(of: line) else { return false }
        let vertical = cmd == .up || cmd == .down
        guard let to = LineNav.move(cmd, line: i, column: column, columns: lines.map(columns)) else { return false }
        let next = field(lines[to.line], to.column)
        // Into the label without popping up its suggestions; ← lands at the end, → at the start.
        let caret: FocusRequest.Caret = vertical ? (to.column == .time ? .start : .end) : (cmd == .leftAtStart ? .end : .start)
        focus(next, caret: caret, quiet: to.column == .label)
        return true
    }

    private func request(_ target: FocusTarget) -> FocusRequest? {
        focusTarget == target ? FocusRequest(id: focusSeq, caret: pendingCaret) : nil
    }

    private func endEditing() {
        ac = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func shiftDay(_ delta: Int) {
        ac = nil
        draftTime = nil
        pendingPaste = nil
        day = Calendar.current.date(byAdding: .day, value: delta, to: day)!
    }

    private func selectDay(_ date: Date) {
        ac = nil
        draftTime = nil
        day = Calendar.current.startOfDay(for: date)
    }

    private func goToday() {
        ac = nil
        draftTime = nil
        day = Calendar.current.startOfDay(for: Date())
    }

    private func copyAgentPrompt() {
        let prompt = state.agentPrompt()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        showToast(L("Prompt kopiert – in deinen Agent einfügen"))
    }

    // MARK: Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let unassigned = store.unassignedCount
        let labels = MenuItem.make(L("Labels verwalten …"), key: "l") { state.openLabels() }
        if unassigned > 0 {
            let title = NSMutableAttributedString(string: L("Labels verwalten …") + "  ")
            title.append(NSAttributedString(string: L("%@ offen", "\(unassigned)"), attributes: [
                .foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ]))
            labels.attributedTitle = title
        }
        menu.addItem(labels)
        menu.addItem(.separator())
        let copy = MenuItem.make(L("Tag kopieren"), key: "c") { copyDay(day) }
        copy.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(copy)
        let pasteItem = MenuItem.make(L("Einfügen"), key: "v") { paste(on: [day]) }
        pasteItem.keyEquivalentModifierMask = [.command, .option]
        pasteItem.isEnabled = DayClipboard.items != nil
        menu.addItem(pasteItem)
        menu.addItem(MenuItem.make(L("In mehrere Tage einfügen …")) { pastingRange = true })

        menu.addItem(.separator())
        let agent = MenuItem.make(L("Prompt für Agent kopieren")) { copyAgentPrompt() }
        agent.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        agent.toolTip = L("In Claude Code o. Ä. einfügen – der Agent kann dann Einträge lesen und bearbeiten.")
        menu.addItem(agent)
        menu.addItem(MenuItem.make(L("Einstellungen …"), key: ",") { state.openSettings() })
        menu.addItem(MenuItem.make(L("%@ exportieren …", Fmt.monthTitle.string(from: day)), key: "e") { state.export(day) })
        menu.addItem(.separator())
        menu.addItem(MenuItem.make(L("Über zeyt")) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        menu.addItem(MenuItem.make(L("Beenden"), key: "q") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Keyboard shortcuts of the menu, active while the popover is key.
    private var shortcuts: some View {
        Group {
            Button("") { state.openLabels() }.keyboardShortcut("l")
            Button("") { state.openSettings() }.keyboardShortcut(",")
            Button("") { state.export(day) }.keyboardShortcut("e")
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q")
            Button("") { shiftDay(-1) }.keyboardShortcut("[")
            Button("") { shiftDay(1) }.keyboardShortcut("]")
            Button("") { copyDay(day) }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("") { paste(on: [day]) }.keyboardShortcut("v", modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}
