import SwiftUI
import AppKit

extension Notification.Name {
    static let asideFocusEditor = Notification.Name("asideFocusEditor")
}

/// Notes-style editor: the first line renders as the title, the rest as body.
/// Wraps NSTextView so the typography and text behavior are the system's own.
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false   // keeps em dashes out of the vault
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyStyling()

        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Only rewrite on an external change (switching notes), never mid-typing.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            context.coordinator.applyStyling()
            let safe = min(selection.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safe, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: NoteTextView
        weak var textView: NSTextView?

        init(_ parent: NoteTextView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusRequested),
                name: .asideFocusEditor, object: nil)
        }

        @objc private func focusRequested() {
            guard let textView else { return }
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyStyling()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.typingAttributes = attributes(inTitle: isInTitle(textView))
        }

        private func isInTitle(_ textView: NSTextView) -> Bool {
            let string = textView.string as NSString
            let firstBreak = string.range(of: "\n")
            let titleLength = firstBreak.location == NSNotFound ? string.length : firstBreak.location
            return textView.selectedRange().location <= titleLength
        }

        private func attributes(inTitle: Bool) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = inTitle ? 1 : 3
            if inTitle { paragraph.paragraphSpacing = 8 }
            return [
                .font: inTitle ? NSFont.systemFont(ofSize: 17, weight: .semibold)
                               : NSFont.systemFont(ofSize: 13.5),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        }

        func applyStyling() {
            guard let textView, let storage = textView.textStorage else { return }
            let string = storage.string as NSString
            let firstBreak = string.range(of: "\n")
            let titleLength = firstBreak.location == NSNotFound ? storage.length : firstBreak.location

            storage.beginEditing()
            storage.setAttributes(attributes(inTitle: false),
                                  range: NSRange(location: 0, length: storage.length))
            if titleLength > 0 {
                storage.setAttributes(attributes(inTitle: true),
                                      range: NSRange(location: 0, length: titleLength))
            }
            storage.endEditing()
            textView.typingAttributes = attributes(inTitle: isInTitle(textView))
        }
    }
}
