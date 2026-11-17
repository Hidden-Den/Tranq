import SwiftUI
import AppKit

struct EditableTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// Ставить ли курсор в текст при появлении.
    var autoFocus = true
    var onChange: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor(Color.uiInk)
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.unregisterDraggedTypes()
        textView.string = text
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text, !context.coordinator.isEditing {
            textView.string = text
            textView.textColor = NSColor(Color.uiInk)
        }
        textView.isEditable = isEditable
        context.coordinator.parent = self
        if autoFocus, isEditable, !context.coordinator.didFocus, let window = textView.window {
            window.makeFirstResponder(textView)
            context.coordinator.didFocus = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextView
        weak var textView: NSTextView?
        var isEditing = false
        var didFocus = false

        init(parent: EditableTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textViewDidEndEditing(_ notification: Notification) {
            isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newValue = tv.string
            DispatchQueue.main.async {
                self.parent.text = newValue
                self.parent.onChange?(newValue)
            }
        }
    }
}