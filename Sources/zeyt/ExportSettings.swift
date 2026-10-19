import AppKit
import SwiftUI

/// Settings section for the export script: editor, templates, test run.
struct ExportSettings: View {
    @ObservedObject var store: EntryStore
    @AppStorage(ExportScript.key) private var stored = ""
    @State private var script = ExportScript.current
    @State private var previousMonth = true
    @State private var preview: Result<ExportScript.Output, ExportScript.Failure>?
    @State private var pendingTemplate: ExportScript.Template?

    var body: some View {
        Section {
            ScriptEditor(text: $script)
                .frame(height: 260)
                .onChange(of: script) {
                    // The Chronos template is the default, so it isn't stored.
                    stored = script == ExportScript.Template.chronos.script ? "" : script
                    preview = nil
                }
            HStack {
                Menu(L("Vorlage")) {
                    ForEach(ExportScript.Template.allCases) { t in
                        Button(t.title) {
                            if ExportScript.Template.allCases.contains(where: { $0.script == script }) {
                                script = t.script
                            } else {
                                pendingTemplate = t
                            }
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Picker("", selection: $previousMonth) {
                    Text(Fmt.monthTitle.string(from: month(previous: true))).tag(true)
                    Text(Fmt.monthTitle.string(from: month(previous: false))).tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Button(L("Testen")) { preview = Export.run(month: month(previous: previousMonth), store: store) }
            }
            if let preview { previewView(preview) }
        } header: {
            Text(L("Export"))
        } footer: {
            Text(L("Das Skript bekommt einen Monat und definiert transform(input). Es entscheidet selbst, was exportiert wird und in welchem Format: json(), csv(), tsv() oder text() – siehe Kommentar oben im Skript. Exportiert wird über das Zahnrad-Menü."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(L("Skript durch Vorlage ersetzen?"), isPresented: Binding(
            get: { pendingTemplate != nil }, set: { if !$0 { pendingTemplate = nil } }
        )) {
            Button(L("Ersetzen"), role: .destructive) {
                if let t = pendingTemplate { script = t.script }
                pendingTemplate = nil
            }
        } message: {
            Text(L("Deine Änderungen am Skript gehen verloren."))
        }
    }

    private func month(previous: Bool) -> Date {
        let start = Calendar.current.dateInterval(of: .month, for: Date())!.start
        return previous ? Calendar.current.date(byAdding: .month, value: -1, to: start)! : start
    }

    @ViewBuilder
    private func previewView(_ result: Result<ExportScript.Output, ExportScript.Failure>) -> some View {
        switch result {
        case .failure(let f):
            Label(f.message, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
        case .success(let o):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(o.warnings.enumerated()), id: \.offset) { _, w in
                    Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Text(L("%1$@ · %2$@ Zeichen", "\(o.fileName ?? "zeyt-…").\(o.fileExtension)", "\(o.text.count)")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(o.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
        }
    }
}

/// Plain code editor: monospaced, no smart quotes or other substitutions.
struct ScriptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        // Code doesn't wrap.
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        tv.delegate = context.coordinator
        tv.string = text
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ScriptEditor
        init(_ parent: ScriptEditor) { self.parent = parent }
        func textDidChange(_ n: Notification) {
            parent.text = (n.object as! NSTextView).string
        }
    }
}
