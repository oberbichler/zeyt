import Foundation

/// The language zeyt shows: the best match of the user's languages among `Resources/*.lproj`
/// (copied into the app by build.sh). Outside the app bundle (tests) it is German, the source language.
enum AppLanguage {
    static let code: String = {
        guard Bundle.main.localizations.contains("de") else { return "de" }
        return Bundle.main.preferredLocalizations.first ?? "de"
    }()

    /// For date formatters: day and month names in the app's language, the region from the system.
    static let locale: Locale = {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: code)
        return Locale(components: components)
    }()
}

/// Translated user-visible text. The key is the German text; `args` fill `%@` (or `%1$@`, `%2$@` …
/// when there are several, so translations can reorder them). Pass every argument as a String.
func L(_ key: String, _ args: String...) -> String {
    let text = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return text }
    return String(format: text, arguments: args.map { $0 as CVarArg })
}
