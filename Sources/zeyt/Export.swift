import AppKit

/// Exports one month with the export script from the settings.
@MainActor
enum Export {
    static func run(month day: Date, store: EntryStore) -> Result<ExportScript.Output, ExportScript.Failure> {
        let start = Calendar.current.dateInterval(of: .month, for: day)!.start
        let input = ExportScript.input(month: start, entries: store.entries(on:), labels: store.labelInfo, now: Date())
        return ExportScript.run(ExportScript.current, input: input)
    }

    static func month(containing day: Date, store: EntryStore) {
        NSApp.activate(ignoringOtherApps: true)
        let output: ExportScript.Output
        switch run(month: day, store: store) {
        case .failure(let failure):
            let alert = NSAlert()
            alert.messageText = L("Export-Skript fehlgeschlagen")
            alert.informativeText = failure.message + "\n\n" + L("Das Skript lässt sich in den Einstellungen bearbeiten.")
            alert.addButton(withTitle: L("OK"))
            alert.addButton(withTitle: L("Einstellungen …"))
            if alert.runModal() == .alertSecondButtonReturn {
                UserDefaults.standard.set("export", forKey: "settingsTab")
                openSettings()
            }
            return
        case .success(let o): output = o
        }

        let panel = NSSavePanel()
        let name = output.fileName ?? "zeyt-\(monthName.string(from: day))"
        panel.nameFieldStringValue = name + (output.fileExtension.isEmpty ? "" : ".\(output.fileExtension)")
        panel.message = L("%@ exportieren", Fmt.monthTitle.string(from: day))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        if !output.warnings.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Exportiert, mit Hinweisen")
            alert.informativeText = output.warnings.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// Set by the app delegate.
    static var openSettings: () -> Void = {}

    private static let monthName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()
}
