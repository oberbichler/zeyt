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
    /// Hours and BT leave out the time of these labels, while switched on (settings).
    @Published var uncountedEnabled = AppState.loadUncountedEnabled() {
        didSet { UserDefaults.standard.set(uncountedEnabled, forKey: "uncountedEnabled") }
    }
    @Published var uncountedLabels = AppState.loadUncountedLabels() {
        didSet { UserDefaults.standard.set(uncountedLabels, forKey: "uncountedLabels") }
    }
    var uncounted: Set<String> { uncountedEnabled ? Set(uncountedLabels) : [] }
    /// The same, read straight from the settings (agent API).
    nonisolated static var uncounted: Set<String> { loadUncountedEnabled() ? Set(loadUncountedLabels()) : [] }

    /// Off by default; before, a switch "countAbsence" (default on) left out the absences when off.
    nonisolated private static func loadUncountedEnabled() -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "uncountedEnabled") as? Bool ?? !(d.object(forKey: "countAbsence") as? Bool ?? true)
    }

    nonisolated private static func loadUncountedLabels() -> [String] {
        UserDefaults.standard.stringArray(forKey: "uncountedLabels") ?? Absence.allCases.map(\.rawValue)
    }
    /// Prompts are macOS notifications; false if zeyt may not post them.
    @Published var notificationsAllowed = true
    /// Incremented each time the popover opens.
    @Published var openCount = 0
    @Published var showInMenuBar = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }
    var promptNow: () -> Void = {}
    var openLabels: () -> Void = {}
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
