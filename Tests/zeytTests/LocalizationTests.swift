import Foundation
import Testing

/// Every `L("…")` key in the sources has a translation in every language, with the same placeholders,
/// and the translation files carry no keys the code no longer uses.
@Suite struct LocalizationTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/zeyt")
    static let languages = ["en", "fr", "es", "it", "pl", "nl", "pt"]

    /// Keys as the compiler sees them: Swift escapes resolved.
    static let keys: Set<String> = {
        let files = (try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)) ?? []
        let pattern = try! NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for file in files where file.pathExtension == "swift" {
            let text = try! String(contentsOf: file, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(m.range(at: 1), in: text)!])
                keys.insert(raw.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n")
                    .replacingOccurrences(of: #"\\"#, with: "\\"))
            }
        }
        return keys
    }()

    static func table(_ language: String) -> [String: String] {
        let url = sources.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        return NSDictionary(contentsOf: url) as? [String: String] ?? [:]
    }

    /// `%@`, `%1$@` … sorted, so a translation may reorder positional ones.
    static func placeholders(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"%(\d+\$)?@"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }.sorted()
    }

    @Test func keysFound() {
        #expect(Self.keys.count > 100)
    }

    @Test(arguments: languages) func complete(language: String) {
        let table = Self.table(language)
        let missing = Self.keys.subtracting(table.keys).sorted()
        #expect(missing.isEmpty, "\(language): \(missing.count) fehlen, z. B. \(missing.prefix(5))")
        let unused = Set(table.keys).subtracting(Self.keys).sorted()
        #expect(unused.isEmpty, "\(language): nicht mehr benutzt: \(unused.prefix(5))")
        for (key, value) in table where Self.keys.contains(key) {
            #expect(!value.isEmpty, "\(language): leer: \(key)")
            #expect(Self.placeholders(key) == Self.placeholders(value), "\(language): Platzhalter in \(key) → \(value)")
        }
    }
}
