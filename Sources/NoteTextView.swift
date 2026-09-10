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
        textView.isAutomaticDataDetectionEnabled = false
        textView.displaysLinkToolTips = true
        textView.linkTextAttributes = [:]   // styling is applied per range instead
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
            styleMarkdown(in: storage, titleLength: titleLength)
            styleLinks(in: storage, string: string)
            styleCheckboxes(in: storage, string: string)
            storage.endEditing()
            textView.typingAttributes = attributes(inTitle: isInTitle(textView))
        }

        /// Markdown, styled where it sits. The syntax stays visible but dimmed:
        /// hiding it would move every character after it the moment the cursor
        /// entered the line, and these are `.md` files that other tools read.
        private func styleMarkdown(in storage: NSTextStorage, titleLength: Int) {
            for span in Markdown.spans(in: storage.string) {
                guard NSMaxRange(span.range) <= storage.length else { continue }

                switch span.style {
                case .marker, .rule:
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                         range: span.range)

                case .heading(let level):
                    // The first line is already the note's title, so a `#` on it
                    // dims to nothing rather than stacking a second size on top.
                    guard span.range.location >= titleLength else { continue }
                    let size: CGFloat = [1: 16.5, 2: 15, 3: 14][level] ?? 13.5
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                        .foregroundColor: NSColor.labelColor,
                    ], range: span.range)

                case .bold:
                    restyle(storage, span.range) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }

                case .italic:
                    restyle(storage, span.range) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }

                case .code:
                    let size = (storage.attribute(.font, at: span.range.location, effectiveRange: nil)
                                as? NSFont)?.pointSize ?? 13.5
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                        .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                    ], range: span.range)

                case .quote:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                         range: span.range)
                    restyle(storage, span.range) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
                }
            }
        }

        /// Adds a trait to whatever font is already there, so bold inside a
        /// heading stays heading-sized instead of dropping to the body size.
        private func restyle(_ storage: NSTextStorage, _ range: NSRange,
                             _ transform: (NSFont) -> NSFont) {
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13.5)
                storage.addAttribute(.font, value: transform(font), range: subrange)
            }
        }

        /// Real clickable links, so a note can hold a URL and still be plain text.
        private func styleLinks(in storage: NSTextStorage, string: NSString) {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            else { return }
            let full = NSRange(location: 0, length: string.length)
            detector.enumerateMatches(in: string as String, range: full) { match, _, _ in
                guard let match, let url = match.url else { return }
                storage.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: match.range)
            }
        }

        /// `- [ ]` and `- [x]` become clickable. The link carries the box's own
        /// location, which is the only thing that survives the text moving around.
        private func styleCheckboxes(in storage: NSTextStorage, string: NSString) {
            guard let regex = try? NSRegularExpression(pattern: "^[ \t]*[-*+] \\[([ xX])\\]",
                                                       options: [.anchorsMatchLines]) else { return }
            let full = NSRange(location: 0, length: string.length)
            regex.enumerateMatches(in: string as String, range: full) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let markRange = match.range(at: 1)
                let checked = string.substring(with: markRange).lowercased() == "x"
                guard let url = URL(string: "aside-toggle:\(markRange.location)") else { return }

                storage.addAttributes([
                    .link: url,
                    .foregroundColor: checked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                    .underlineStyle: 0,
                ], range: match.range)

                // Dim the finished item, the way every task list does.
                if checked {
                    let lineEnd = string.range(of: "\n", options: [],
                                               range: NSRange(location: match.range.upperBound,
                                                              length: string.length - match.range.upperBound))
                    let end = lineEnd.location == NSNotFound ? string.length : lineEnd.location
                    let textRange = NSRange(location: match.range.upperBound,
                                            length: end - match.range.upperBound)
                    if textRange.length > 0 {
                        storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor],
                                              range: textRange)
                    }
                }
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? URL(string: "\(link)") else { return false }
            guard url.scheme == "aside-toggle" else {
                NSWorkspace.shared.open(url)
                return true
            }
            guard let location = Int(url.absoluteString.replacingOccurrences(of: "aside-toggle:", with: "")),
                  let storage = textView.textStorage,
                  location < storage.length else { return true }

            let current = (storage.string as NSString).substring(with: NSRange(location: location, length: 1))
            let replacement = current.lowercased() == "x" ? " " : "x"
            let selection = textView.selectedRange()

            storage.replaceCharacters(in: NSRange(location: location, length: 1), with: replacement)
            parent.text = textView.string
            applyStyling()
            textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.count), length: 0))
            return true
        }
    }
}
