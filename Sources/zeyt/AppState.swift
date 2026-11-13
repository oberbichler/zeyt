import SwiftUI
import ServiceManagement

/// State shared between the app delegate, the popover and the settings.
@MainActor
final class AppState: ObservableObject {
    /// Reminder when no label is assigned to the current time (settings).
    @Published var reminder = AppState.loadReminder() {
        didSet { AppState.save(reminder) }
    }
    /// What the reminder does right now; updated by the app delegate.
    @Published var reminderStatus = Reminder.Status.off
    /// Hours and BT leave out the labels that don't count (per label, `EntryStore.counts`), while switched on.
    @Published var uncountedEnabled = AppState.uncountedEnabledSetting {
        didSet { UserDefaults.standard.set(uncountedEnabled, forKey: "uncountedEnabled") }
    }

    /// Off by default; before, a switch "countAbsence" (default on) left out the absences when off.
    nonisolated static var uncountedEnabledSetting: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "uncountedEnabled") as? Bool ?? !(d.object(forKey: "countAbsence") as? Bool ?? true)
    }
    /// Prompts are macOS notifications; false if zeyt may not post them.
    @Published var notificationsAllowed = true
    /// Incremented each time the popover opens.
    @Published var openCount = 0
    @Published var showInMenuBar = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }
    /// Presence detection (`PresenceTracker`): proposals for start, breaks and end of day; reminders only while present.
    @Published var presenceEnabled = UserDefaults.standard.object(forKey: "presenceEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(presenceEnabled, forKey: "presenceEnabled") }
    }
    /// Away at least this long during a task: propose a break.
    @Published var breakMinutes = UserDefaults.standard.object(forKey: "breakMinutes") as? Int ?? 15 {
        didSet { UserDefaults.standard.set(breakMinutes, forKey: "breakMinutes") }
    }
    @Published var microphoneCounts = UserDefaults.standard.object(forKey: "microphoneCounts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(microphoneCounts, forKey: "microphoneCounts") }
    }
    /// Breaks are recorded right away (with undo in the notification) instead of proposed.
    @Published var autoBreaks = UserDefaults.standard.bool(forKey: "autoBreaks") {
        didSet { UserDefaults.standard.set(autoBreaks, forKey: "autoBreaks") }
    }
    static let breakChoices = [10, 15, 20, 30, 45, 60]
    /// Without input this long: away.
    @Published var awayMinutes = UserDefaults.standard.object(forKey: "awayMinutes") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(awayMinutes, forKey: "awayMinutes") }
    }
    @Published var proposeStart = UserDefaults.standard.object(forKey: "proposeStart") as? Bool ?? true {
        didSet { UserDefaults.standard.set(proposeStart, forKey: "proposeStart") }
    }
    @Published var proposeBreaks = UserDefaults.standard.object(forKey: "proposeBreaks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(proposeBreaks, forKey: "proposeBreaks") }
    }
    @Published var proposeEndOfDay = UserDefaults.standard.object(forKey: "proposeEndOfDay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(proposeEndOfDay, forKey: "proposeEndOfDay") }
    }
    /// Proposals also as a notification, not only in the popover.
    @Published var proposalNotifications = UserDefaults.standard.object(forKey: "proposalNotifications") as? Bool ?? true {
        didSet { UserDefaults.standard.set(proposalNotifications, forKey: "proposalNotifications") }
    }
    @Published var roundMinutes = UserDefaults.standard.object(forKey: "roundMinutes") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(roundMinutes, forKey: "roundMinutes") }
    }
    static let roundChoices = [1, 5, 10, 15]
    /// Reminders follow the presence: none while away, the day starts with the first presence.
    @Published var remindersFollowPresence = UserDefaults.standard.object(forKey: "remindersFollowPresence") as? Bool ?? true {
        didSet { UserDefaults.standard.set(remindersFollowPresence, forKey: "remindersFollowPresence") }
    }
    /// The day bar reaches from the first to the last presence, not only over the entries.
    @Published var timelineCoversPresence = UserDefaults.standard.object(forKey: "timelineCoversPresence") as? Bool ?? true {
        didSet { UserDefaults.standard.set(timelineCoversPresence, forKey: "timelineCoversPresence") }
    }
    /// Resolution of the day bar in minutes (hover, click to add).
    @Published var timelineMinutes = UserDefaults.standard.object(forKey: "timelineMinutes") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(timelineMinutes, forKey: "timelineMinutes") }
    }
    @Published var presenceKeepDays = UserDefaults.standard.object(forKey: "presenceKeepDays") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(presenceKeepDays, forKey: "presenceKeepDays") }
    }
    static let keepChoices = [7, 30, 60, 365]

    /// Proposal rules from the settings.
    var proposalSettings: Proposal.Settings {
        Proposal.Settings(start: proposeStart, breaks: proposeBreaks, endOfDay: proposeEndOfDay,
                          minBreak: TimeInterval(breakMinutes * 60), awayAfter: TimeInterval(awayMinutes * 60),
                          roundMinutes: roundMinutes, reminder: reminder)
    }
    var clearPresence: () -> Void = {}
    /// What the presence suggests right now (popover banner, notification).
    @Published var proposal: Proposal?
    /// Carries out a proposal; the text replaces the first entry's (a start with another label).
    var applyProposal: (Proposal, String?) -> Void = { _, _ in }
    var dismissProposal: (Proposal) -> Void = { _ in }
    /// Input time the popover should take (e.g. "other activity since 08:10"); taken by the popover.
    @Published var requestedDraftTime: Date?

    var promptNow: () -> Void = {}
    var openLabels: () -> Void = {}
    var openCalendar: () -> Void = {}
    /// Opens the popover on that day (calendar).
    var showDay: (Date) -> Void = { _ in }
    /// Day the popover should show when it opens next or now; taken (set to nil) by the popover.
    @Published var requestedDay: Date?
    /// A day in the month the calendar window shows.
    @Published var calendarDate = Calendar.current.startOfDay(for: Date())
    var openSettings: () -> Void = {}
    var export: (Date) -> Void = { _ in }
    /// Switches the agent API on and returns the connection prompt.
    var agentPrompt: () -> String = { "" }

    private static func loadReminder() -> Reminder {
        let d = UserDefaults.standard
        var r = Reminder()
        // Before: "promptsPaused" switched the half-hourly prompt off.
        r.enabled = d.object(forKey: "reminderEnabled") as? Bool ?? !d.bool(forKey: "promptsPaused")
        if let m = d.object(forKey: "reminderMinutes") as? Int { r.minutes = m }
        if let f = d.object(forKey: "reminderFrom") as? Int { r.from = f }
        if let t = d.object(forKey: "reminderTo") as? Int { r.to = t }
        if let w = d.object(forKey: "reminderWeekdaysOnly") as? Bool { r.weekdaysOnly = w }
        return r
    }

    private static func save(_ r: Reminder) {
        let d = UserDefaults.standard
        d.set(r.enabled, forKey: "reminderEnabled")
        d.set(r.minutes, forKey: "reminderMinutes")
        d.set(r.from, forKey: "reminderFrom")
        d.set(r.to, forKey: "reminderTo")
        d.set(r.weekdaysOnly, forKey: "reminderWeekdaysOnly")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
