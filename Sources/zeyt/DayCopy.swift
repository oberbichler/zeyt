import SwiftUI

/// Days on the system clipboard as text ("08:00 #alpha Sync" per line), so they can also go to
/// and come from other apps, e.g. a day in a text note.
@MainActor
enum DayClipboard {
    static func copy(_ entries: [Entry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DayText.make(entries), forType: .string)
    }

    static var items: [DayText.Item]? {
        NSPasteboard.general.string(forType: .string).flatMap { DayText.parse($0) }
    }

    /// Only text that is nothing but a day, for offering it without being asked.
    static var day: [DayText.Item]? {
        guard let text = NSPasteboard.general.string(forType: .string), text.count < 20_000 else { return nil }
        return DayText.parse(text, strict: true)
    }
}

/// Asks what to do when target days already have entries.
struct PasteConfirmBar: View {
    let pending: DayView.PendingPaste
    let describe: (Date) -> String
    let done: (EntryStore.PasteMode?) -> Void

    var body: some View {
        let single = pending.days.count == 1
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(single ? L("%@ hat schon Einträge.", describe(pending.days[0]))
                                : L("%1$@ von %2$@ Tagen haben schon Einträge.", "\(pending.filled)", "\(pending.days.count)"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(pending.items.count == 1 ? L("1 Eintrag einfügen – wie?") : L("%@ Einträge einfügen – wie?", "\(pending.items.count)"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(systemImage: "xmark", help: L("Abbrechen (Esc)")) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, -4)
                    .padding(.trailing, -4)
            }
            HStack(spacing: 6) {
                PillButton(title: L("Ersetzen"), prominent: true) { done(.replace) }
                    .help(L("Vorhandene Einträge der Tage entfernen"))
                PillButton(title: L("Ergänzen")) { done(.append) }
                    .help(L("Zu den vorhandenen Einträgen dazu"))
                if !single {
                    PillButton(title: L("Nur leere Tage")) { done(.emptyOnly) }
                        .help(L("Tage mit Einträgen auslassen"))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.panel)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Paste into a range of days.
struct PasteRangeForm: View {
    @State private var from: Date
    @State private var to: Date
    @State private var weekends = false
    let done: ([Date]?) -> Void

    init(start: Date, done: @escaping ([Date]?) -> Void) {
        _from = State(initialValue: start)
        _to = State(initialValue: Calendar.current.date(byAdding: .day, value: 4, to: start)!)
        self.done = done
    }

    var body: some View {
        let days = DayText.days(from: from, to: max(from, to), weekends: weekends)
        VStack(alignment: .leading, spacing: 10) {
            Text(L("In mehrere Tage einfügen")).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                DatePicker(L("Von"), selection: $from, displayedComponents: .date)
                DatePicker(L("bis"), selection: $to, in: from..., displayedComponents: .date)
            }
            .datePickerStyle(.field)
            .font(.system(size: 12))
            Toggle(L("Wochenenden einschließen"), isOn: $weekends)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                Text(days.count == 1 ? L("1 Tag") : L("%@ Tage", "\(days.count)"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                PillButton(title: L("Abbrechen")) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: L("Einfügen"), prominent: true) { done(days) }
                    .disabled(days.isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.panel)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: from) { _, f in if to < f { to = f } }
    }
}

/// Capsule button matching the input bar.
struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(hovering ? 0.14 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
