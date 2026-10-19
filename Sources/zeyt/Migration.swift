import Foundation

/// zeyt was called TMR and had the bundle ID local.tmr: its settings move over once.
enum Migration {
    static let legacyID = "local.tmr"
    private static let keys = ["agentEnabled", "agentToken", "showInMenuBar", "promptsPaused", ExportScript.key, "settingsTab"]

    static func run(defaults: UserDefaults = .standard, legacy: UserDefaults? = UserDefaults(suiteName: legacyID)) {
        guard Bundle.main.bundleIdentifier != legacyID, !defaults.bool(forKey: "migratedFromTMR"), let legacy else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromTMR")
    }
}
