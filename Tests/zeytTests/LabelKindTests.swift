import Foundation
import Testing
@testable import zeyt

struct LabelKindTests {
    @Test func legacyNamesAreAbsencesUntilSetOtherwise() {
        #expect(LabelKind.of("urlaub", assigned: [:]) == .vacation)
        #expect(LabelKind.of("kind-krank", assigned: [:]) == .childSick)
        #expect(LabelKind.of("alpha", assigned: [:]) == .work)
        #expect(LabelKind.of("", assigned: ["": .sick]) == .work)
        #expect(LabelKind.of("urlaub", assigned: ["urlaub": .work]) == .work)
        #expect(LabelKind.of("vacation", assigned: ["vacation": .vacation]) == .vacation)
    }

    @Test func oldLabelsJSONStillLoads() throws {
        let old = #"{"alpha": {"account": "A", "project": "P"}}"#
        let info = try JSONDecoder().decode([String: LabelInfo].self, from: Data(old.utf8))
        #expect(info["alpha"] == LabelInfo(account: "A", project: "P"))
        let new = #"{"ferien": {"kind": "vacation", "counts": true}}"#
        let decoded = try JSONDecoder().decode([String: LabelInfo].self, from: Data(new.utf8))
        #expect(decoded["ferien"] == LabelInfo(kind: .vacation, counts: true))
    }

    @Test func stopWordsAreStoredInGerman() {
        // In tests the app language is German: only the stored words are stops.
        #expect(Rules.stop("Pause") == "pause")
        #expect(Rules.stop(" feierabend ") == "feierabend")
        #expect(Rules.stop("pause machen") == nil)
        #expect(Rules.stop("#pause") == nil)
    }

    @Test func labelsKeepLettersOfAnyLanguage() {
        #expect(Rules.tag("#Congés") == "congés")
        #expect(Rules.tag("Urlop dziecka") == "urlop-dziecka")
        #expect(Rules.tag("doença!") == "doença")
    }
}
