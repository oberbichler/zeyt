import AppKit
import ServiceManagement
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = EntryStore()
    private let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var observers: Set<AnyCancellable> = []
    /// Set by "In 10 Min." in the prompt.
    private var snoozedUntil: Date?
    /// When the last reminder was shown; the next one follows the interval from there.
    private var lastReminder: Date?
    private lazy var api = AgentAPI(store: store)
    private var settingsWindow: NSWindow?
    private let notifier = Notifier()
    private var labelsWindow: NSWindow?

    /// Opening zeyt again (Finder, Spotlight) shows the popover. Only one instance runs:
    /// LSMultipleInstancesProhibited in Info.plist, also against `open -n` and other copies.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        // A time tracker that isn't running asks nothing: start at login by default,
        // once; switching it off in the settings sticks.
        #if !ZEYT_UITEST
        if !UserDefaults.standard.bool(forKey: "loginItemDefaulted") {
            UserDefaults.standard.set(true, forKey: "loginItemDefaulted")
            if !state.launchAtLogin { try? SMAppService.mainApp.register() }
        }
        #endif
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "zeyt")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let hosting = NSHostingController(rootView: DayView(store: store, state: state))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        state.promptNow = { [weak self] in
            self?.popover.performClose(nil)
            self?.showPrompt()
        }
        state.openLabels = { [weak self] in
            self?.popover.performClose(nil)
            self?.showLabelsWindow()
        }
        state.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            self?.showSettingsWindow()
        }
        state.export = { [weak self] day in
            guard let self else { return }
            popover.performClose(nil)
            Export.month(containing: day, store: store)
        }
        state.agentPrompt = { [weak self] in
            guard let self else { return "" }
            api.ensureRunning()
            // The server reports a busy port asynchronously.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                if let error = self?.api.error { Toast.show(L("Agent-API läuft nicht: %@", "\(error)"), seconds: 8) }
            }
            return api.prompt
        }
        Export.openSettings = { [weak self] in self?.showSettingsWindow() }
        _ = api

        notifier.onAnswer = { [weak self] date, text in self?.store.add(date: date, text: text) }
        notifier.onSnooze = { [weak self] in self?.snoozedUntil = Date().addingTimeInterval(10 * 60) }
        notifier.onOpen = { [weak self] in self?.showPopover() }
        notifier.setup { [weak self] in self?.state.notificationsAllowed = $0 }

        state.$reminder.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
                self?.updateReminderStatus()
            }
        }.store(in: &observers)
        // Values are published before they change, so update on the next run loop turn.
        store.$entries.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
                self?.updateReminderStatus()
            }
        }.store(in: &observers)
        state.$showInMenuBar.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
            .store(in: &observers)

        #if ZEYT_UITEST
        UITestScript.startIfRequested(view: { [weak self] in self?.popover.contentViewController?.view },
                                      open: { [weak self] in self?.showPopoverForTest() },
                                      close: { [weak self] in self?.popover.performClose(nil) },
                                      settings: { [weak self] tab in
                                          UserDefaults.standard.set(tab, forKey: "settingsTab")
                                          self?.showSettingsWindow(activate: false)
                                          return self?.settingsWindow?.contentView
                                      },
                                      labels: { [weak self] in
                                          self?.showLabelsWindow(activate: false)
                                          return self?.labelsWindow?.contentView
                                      },
                                      notifications: { [weak self] in
                                          self?.notificationsOverride = $0
                                          self?.state.notificationsAllowed = $0
                                      })
        #endif
        Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        updateReminderStatus()
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard !popover.isShown else { return }
        if let button = statusItem.button {
            store.load()
            state.openCount += 1
            refreshNotificationsAllowed()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            makePopoverOpaque()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    #if ZEYT_UITEST
    /// Like `showPopover`, but without taking the focus from the user's apps: the test runs alongside.
    private func showPopoverForTest() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.behavior = .applicationDefined
        store.load()
        state.openCount += 1
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        makePopoverOpaque()
    }
    #endif

    /// NSPopover is translucent by default; put an opaque layer behind its content (and arrow).
    private func makePopoverOpaque() {
        guard let frame = popover.contentViewController?.view.window?.contentView?.superview else { return }
        let id = NSUserInterfaceItemIdentifier("opaqueBackground")
        let bg = frame.subviews.first { $0.identifier == id } ?? {
            let v = NSView(frame: frame.bounds)
            v.identifier = id
            v.wantsLayer = true
            v.autoresizingMask = [.width, .height]
            frame.addSubview(v, positioned: .below, relativeTo: nil)
            return v
        }()
        frame.effectiveAppearance.performAsCurrentDrawingAppearance {
            bg.layer?.backgroundColor = Look.panelNS.cgColor
        }
    }

    private func showLabelsWindow(activate: Bool = true) {
        if labelsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LabelsView(store: store)))
            w.title = L("zeyt – Labels")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 980, height: 520))
            w.setFrameAutosaveName("Labels")
            w.center()
            labelsWindow = w
        }
        store.load()
        guard activate else { labelsWindow?.orderFrontRegardless(); return }
        NSApp.activate(ignoringOtherApps: true)
        labelsWindow?.makeKeyAndOrderFront(nil)
    }

    #if ZEYT_UITEST
    /// Set by the script's `notifications` command, wins over the real permission.
    private var notificationsOverride: Bool?
    #endif

    /// The permission can change in System Settings at any time.
    private func refreshNotificationsAllowed() {
        #if ZEYT_UITEST
        if let notificationsOverride { state.notificationsAllowed = notificationsOverride; return }
        #endif
        Task { state.notificationsAllowed = await notifier.refreshAuthorization() }
    }

    private func showSettingsWindow(activate: Bool = true) {
        refreshNotificationsAllowed()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state, api: api, store: store))
            hosting.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: hosting)
            w.title = L("zeyt – Einstellungen")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        guard activate else { settingsWindow?.orderFrontRegardless(); return }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Clock icon, plus the running activity and its duration if enabled.
    /// Never shown (zeyt has no menu bar of its own), but ⌘X/C/V/A/Z reach text fields only
    /// through the key equivalents of an Edit menu.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        // No ⌘Q here: in the settings it would quit zeyt instead of closing the window (the popover has its own).
        app.addItem(withTitle: L("zeyt beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        main.addItem(withTitle: "zeyt", action: nil, keyEquivalent: "").submenu = app

        let edit = NSMenu(title: L("Bearbeiten"))
        edit.addItem(withTitle: L("Widerrufen"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Wiederholen"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Einsetzen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Löschen"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: L("Bearbeiten"), action: nil, keyEquivalent: "").submenu = edit
        return main
    }

    /// The popover hangs off the status item: changing its width while open would move the popover
    /// (e.g. a stop turned into a running task). It is brought up to date when the popover closes.
    func popoverDidClose(_ notification: Notification) {
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button, !popover.isShown else { return }
        button.image = NSImage(systemSymbolName: state.reminder.enabled ? "clock" : "pause.circle", accessibilityDescription: "zeyt")
        let now = Date()
        let running = Block.compute(store.entries(on: now), now: now).last { $0.running }
        button.imagePosition = .imageLeading
        guard state.showInMenuBar, let running else {
            button.title = ""
            return
        }
        let e = running.entry
        var name = e.label.isEmpty ? (e.title.isEmpty ? L("unverplant") : e.title) : e.label
        if name.count > 20 { name = String(name.prefix(19)) + "…" }
        button.title = " \(name) · \(Fmt.duration(running.duration))"
    }

    @objc private func tick() {
        let now = Date()
        updateStatusItem()
        let status = updateReminderStatus(now)
        guard case .due(let since, let due) = status else { return }
        if let until = snoozedUntil {
            // "In 10 Min. erinnern" wins over the interval.
            guard now >= until else { return }
            snoozedUntil = nil
        } else if now < due {
            return
        }
        lastReminder = now
        showPrompt(since: since)
    }

    /// Reminder when no label is assigned to the current time (see `Reminder`). After a sleep a due
    /// reminder comes at once.
    @discardableResult
    private func updateReminderStatus(_ now: Date = Date()) -> Reminder.Status {
        let status = state.reminder.status(entries: store.entries(on: now), now: now, last: lastReminder)
        if case .due = status {} else { snoozedUntil = nil }
        if state.reminderStatus != status { state.reminderStatus = status }
        return status
    }

    private func showPrompt(since: Date? = nil) {
        Task {
            let allowed = await notifier.refreshAuthorization()
            state.notificationsAllowed = allowed
            guard allowed else { return }
            let now = Date()
            let current = store.entries(on: now).last { $0.date <= now }
            notifier.post(date: now, last: store.lastWork(before: now),
                          pauseSince: current?.isStop == true ? current?.date : nil, unlabeledSince: since)
        }
    }
}
