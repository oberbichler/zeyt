import AppKit
import UserNotifications

/// The regular prompt as a native notification: reply with "#label Kommentar",
/// continue, pause, end of day or snooze right from the notification.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let id = "prompt"
    private let center = UNUserNotificationCenter.current()

    /// Text to record at the prompt time (may be "pause"/"feierabend").
    var onAnswer: (Date, String) -> Void = { _, _ in }
    var onSnooze: () -> Void = {}
    var onOpen: () -> Void = {}
    private(set) var authorized = false

    /// Asks once; `done` gets whether zeyt may post notifications.
    func setup(done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                done(granted)
            }
        }
    }

    /// Notification settings of zeyt in System Settings.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
    }

    func refreshAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        return authorized
    }

    /// `last` is the activity to offer for continuing, `pauseSince` is set during a break.
    /// `unlabeledSince`: the reminder found no label since then.
    func post(date: Date, last: Entry?, pauseSince: Date?, unlabeledSince: Date? = nil) {
        var actions: [UNNotificationAction] = [
            UNTextInputNotificationAction(identifier: "reply", title: L("Eintragen …"), options: [],
                                          textInputButtonTitle: L("Eintragen"), textInputPlaceholder: L("#label Kommentar")),
        ]
        if let last {
            actions.append(UNNotificationAction(identifier: "continue", title: L("Weiter: %@", Self.describe(last))))
        }
        if pauseSince == nil { actions.append(UNNotificationAction(identifier: "pause", title: L("Pause"))) }
        actions.append(UNNotificationAction(identifier: "end", title: L("Feierabend")))
        actions.append(UNNotificationAction(identifier: "snooze", title: L("In 10 Min. erinnern")))
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.id, actions: actions, intentIdentifiers: [])])

        let content = UNMutableNotificationContent()
        if let pauseSince {
            content.title = L("Pause seit %@ – wieder zurück?", Fmt.time.string(from: pauseSince))
        } else {
            content.title = L("Woran arbeitest du gerade?")
        }
        let since = unlabeledSince.map { Fmt.time.string(from: $0) }
        let previous = last.map { Self.describe($0) }
        switch (since, previous) {
        case let (since?, previous?):
            content.body = L("Seit %1$@ ohne Label · Zuletzt: %2$@ · Antworten mit #label Kommentar", since, previous)
        case let (since?, nil):
            content.body = L("Seit %@ ohne Label · Antworten mit #label Kommentar", since)
        case let (nil, previous?):
            content.body = L("Zuletzt: %@ · Antworten mit #label Kommentar", previous)
        case (nil, nil):
            content.body = L("Antworten mit #label Kommentar")
        }
        content.categoryIdentifier = Self.id
        content.interruptionLevel = .active
        content.userInfo = ["date": date.timeIntervalSince1970, "continue": last?.text ?? ""]

        center.removeDeliveredNotifications(withIdentifiers: [Self.id])
        center.add(UNNotificationRequest(identifier: Self.id, content: content, trigger: nil))
    }

    private static func describe(_ e: Entry) -> String {
        let s = e.label.isEmpty ? e.title : "#\(e.label)" + (e.title.isEmpty ? "" : " \(e.title)")
        return Rules.mid(s, 40)
    }

    /// "#alpha Sync Team" / "alpha Sync Team" → label + comment; "pause"/"feierabend" are kept as they are.
    static func parse(_ reply: String) -> String {
        let raw = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = raw.lowercased()
        if word == "pause" || word == "feierabend" { return word }
        if let split = Rules.splitLabel(raw) { return Entry.compose(label: split.label, description: split.comment) }
        return Entry.compose(label: raw, description: "")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        let date = (info["date"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let continueText = info["continue"] as? String ?? ""
        await MainActor.run {
            switch action {
            case "reply":
                if let reply, !reply.trimmingCharacters(in: .whitespaces).isEmpty { onAnswer(date, Self.parse(reply)) }
            case "continue": onAnswer(date, continueText)
            case "pause": onAnswer(date, "pause")
            case "end": onAnswer(date, "feierabend")
            case "snooze": onSnooze()
            case UNNotificationDefaultActionIdentifier: onOpen()
            default: break
            }
        }
    }
}
