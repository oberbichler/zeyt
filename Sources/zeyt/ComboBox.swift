import AppKit
import SwiftUI

/// Editable NSComboBox: free text with suggestions.
struct ComboBox: NSViewRepresentable {
    @Binding var text: String
    let items: [String]
    var placeholder = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = true
        box.numberOfVisibleItems = 12
        box.placeholderString = placeholder
        box.delegate = context.coordinator
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if box.stringValue != text { box.stringValue = text }
        if context.coordinator.items != items {
            context.coordinator.items = items
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboBox
        var items: [String] = []

        init(_ parent: ComboBox) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let box = note.object as? NSComboBox else { return }
            parent.text = box.stringValue
        }

        func comboBoxSelectionDidChange(_ note: Notification) {
            guard let box = note.object as? NSComboBox,
                  let value = box.objectValueOfSelectedItem as? String else { return }
            parent.text = value
        }
    }
}
