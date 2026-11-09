import AppKit
import CoreAudio

/// Records when the user is at the Mac (see `Presence`): input, screen lock, sleep and, if allowed, a
/// running microphone (calls). Kept in `activity.csv` next to the log (`keepDays`).
@MainActor
final class PresenceTracker: NSObject, ObservableObject {
    @Published private(set) var spans: [DateInterval] = []
    /// A running microphone counts as presence (calls without typing).
    var microphoneCounts = true
    /// Without input this long the user is away (settings).
    var awayAfter = Presence.awayAfter
    /// Spans older than this are dropped.
    var keepDays = 60

    private let url = EntryStore.directory.appendingPathComponent("activity.csv")
    private var locked = false
    private var asleep = false
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        load()
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (PresenceTracker) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }
        // Distributed notifications wait while the app is inactive (zeyt nearly always is) unless asked
        // to be delivered at once.
        distributed.addObserver(self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
        on(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true; $0.save() }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true; $0.save() }
        on(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.asleep = false }
    }

    @objc private func screenLocked() { locked = true; save() }
    @objc private func screenUnlocked() { locked = false }

    /// Takes one sample; called from the app's timer.
    func sample(now: Date = Date()) {
        #if ZEYT_UITEST
        // Tests show the presence from the test data only.
        return
        #else
        guard !locked, !asleep else { return }
        let lastInput = microphoneCounts && Self.microphoneRunning() ? now : now.addingTimeInterval(-Self.secondsSinceInput())
        let before = spans.count
        Presence.record(&spans, lastInput: lastInput, awayAfter: awayAfter)
        if spans.count != before || now.timeIntervalSince(lastSave) > 5 * 60 { save() }
        #endif
    }

    /// Spans of the day of `day`.
    func spans(on day: Date) -> [DateInterval] { Presence.spans(spans, on: day) }

    /// The span the user is in right now, nil while away.
    func current(now: Date = Date()) -> DateInterval? {
        Presence.isPresent(spans, now: now, awayAfter: awayAfter) ? spans.last : nil
    }

    // MARK: Signals

    private static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Whether some app uses the default input device (CoreAudio; no permission, nothing is recorded).
    private static func microphoneRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: File

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// "Von,Bis" with one line per span.
    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        spans = text.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: ",")
            guard parts.count == 2, let a = Self.formatter.date(from: String(parts[0])),
                  let b = Self.formatter.date(from: String(parts[1])), a <= b else { return nil }
            return DateInterval(start: a, end: b)
        }.sorted { $0.start < $1.start }
    }

    /// Forgets all recorded presence.
    func clear() {
        spans = []
        try? FileManager.default.removeItem(at: url)
        save()
    }

    /// Present today in total.
    func total(on day: Date) -> TimeInterval {
        spans(on: day).reduce(0) { $0 + $1.duration }
    }

    func save() {
        #if !ZEYT_UITEST
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        spans.removeAll { $0.end < cutoff }
        let text = "Von,Bis\n" + spans.map { "\(Self.formatter.string(from: $0.start)),\(Self.formatter.string(from: $0.end))\n" }.joined()
        try? text.write(to: url, atomically: true, encoding: .utf8)
        lastSave = Date()
        #endif
    }
}
