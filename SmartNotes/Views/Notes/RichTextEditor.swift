import SwiftUI
import UIKit

// MARK: - Formatting commands

/// Bridge between SwiftUI toolbar buttons and the underlying UITextView.
/// `RichTextEditor` connects `textView` when it creates the view; every
/// command is a safe no-op until then. Commands mutate the text storage
/// directly and then replay `textViewDidChange` so the SwiftUI binding
/// and the autosave pipeline both pick up the change.
@MainActor
final class RichTextCommands {
    weak var textView: UITextView?

    static var bodyFont: UIFont { .preferredFont(forTextStyle: .body) }

    static var headingFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .title2)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: 0)
    }

    func toggleBold() { toggleTrait(.traitBold) }
    func toggleItalic() { toggleTrait(.traitItalic) }

    /// Toggles a symbolic trait over the selection, or over the typing
    /// attributes when the selection is empty (affects text typed next).
    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let textView else { return }
        let range = textView.selectedRange

        if range.length > 0 {
            let storage = textView.textStorage
            // Add or remove based on the first run so mixed selections
            // become uniformly styled instead of flipping run by run.
            let firstFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            let shouldAdd = !(firstFont?.fontDescriptor.symbolicTraits.contains(trait) ?? false)

            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
                let base = (value as? UIFont) ?? Self.bodyFont
                var traits = base.fontDescriptor.symbolicTraits
                if shouldAdd { traits.insert(trait) } else { traits.remove(trait) }
                guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return }
                storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: subRange)
            }
            storage.endEditing()
            notifyTextChanged()
        } else {
            var attributes = textView.typingAttributes
            let base = (attributes[.font] as? UIFont) ?? Self.bodyFont
            var traits = base.fontDescriptor.symbolicTraits
            if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
            guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return }
            attributes[.font] = UIFont(descriptor: descriptor, size: 0)
            textView.typingAttributes = attributes
        }
    }

    func toggleUnderline() {
        guard let textView else { return }
        let range = textView.selectedRange

        if range.length > 0 {
            let storage = textView.textStorage
            let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int
            storage.beginEditing()
            if (current ?? 0) == 0 {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                storage.removeAttribute(.underlineStyle, range: range)
            }
            storage.endEditing()
            notifyTextChanged()
        } else {
            var attributes = textView.typingAttributes
            if ((attributes[.underlineStyle] as? Int) ?? 0) == 0 {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                attributes.removeValue(forKey: .underlineStyle)
            }
            textView.typingAttributes = attributes
        }
    }

    /// Applies or removes a heading style on the paragraph containing the
    /// selection. A paragraph counts as a heading when its first character
    /// already uses at least the heading point size.
    func toggleHeading() {
        guard let textView else { return }
        let storage = textView.textStorage
        let plain = storage.string as NSString
        let paragraph = plain.paragraphRange(for: textView.selectedRange)

        if paragraph.length > 0 {
            let firstFont = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? UIFont
            let isHeading = (firstFont?.pointSize ?? 0) >= Self.headingFont.pointSize
            storage.beginEditing()
            storage.addAttribute(.font, value: isHeading ? Self.bodyFont : Self.headingFont, range: paragraph)
            storage.endEditing()
            notifyTextChanged()
        } else {
            // Empty paragraph (or empty document): style what's typed next.
            var attributes = textView.typingAttributes
            let current = (attributes[.font] as? UIFont) ?? Self.bodyFont
            let isHeading = current.pointSize >= Self.headingFont.pointSize
            attributes[.font] = isHeading ? Self.bodyFont : Self.headingFont
            textView.typingAttributes = attributes
        }
    }

    /// Toggles simple text bullets ("• ") on every line in the selected
    /// paragraph range. If every non-empty line is already bulleted the
    /// prefixes are removed, otherwise they are added.
    func toggleBulletList() {
        guard let textView else { return }
        let storage = textView.textStorage
        let plain = storage.string as NSString
        let paragraphs = plain.paragraphRange(for: textView.selectedRange)

        var lineRanges: [NSRange] = []
        plain.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            lineRanges.append(range)
        }
        if lineRanges.isEmpty {
            // Empty document or empty trailing line.
            lineRanges = [NSRange(location: paragraphs.location, length: 0)]
        }

        let bullet = "• "
        let bulletLength = (bullet as NSString).length
        let nonEmptyLines = lineRanges.filter { $0.length > 0 }
        let allBulleted = !nonEmptyLines.isEmpty
            && nonEmptyLines.allSatisfy { plain.substring(with: $0).hasPrefix(bullet) }

        storage.beginEditing()
        // Reversed so edits don't invalidate the earlier line offsets.
        for range in lineRanges.reversed() {
            if allBulleted {
                if range.length >= bulletLength, plain.substring(with: range).hasPrefix(bullet) {
                    storage.deleteCharacters(in: NSRange(location: range.location, length: bulletLength))
                }
            } else {
                let attributes = insertionAttributes(at: range.location, in: storage, textView: textView)
                storage.insert(NSAttributedString(string: bullet, attributes: attributes), at: range.location)
            }
        }
        storage.endEditing()
        notifyTextChanged()
    }

    private func insertionAttributes(
        at location: Int,
        in storage: NSTextStorage,
        textView: UITextView
    ) -> [NSAttributedString.Key: Any] {
        guard storage.length > 0 else { return textView.typingAttributes }
        let index = min(location, storage.length - 1)
        return storage.attributes(at: index, effectiveRange: nil)
    }

    private func notifyTextChanged() {
        guard let textView else { return }
        textView.delegate?.textViewDidChange?(textView)
    }
}

// MARK: - Representable

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var selectedRange: NSRange
    let commands: RichTextCommands
    var onDefine: () -> Void = {}
    var onExplain: () -> Void = {}
    var onAddToVocabulary: () -> Void = {}

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.attributedText = attributedText
        textView.font = RichTextCommands.bodyFont
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 16, right: 12)
        textView.typingAttributes = [
            .font: RichTextCommands.bodyFont,
            .foregroundColor: UIColor.label
        ]
        commands.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        commands.textView = textView

        // Feedback-loop guard: while the user types, the coordinator has
        // already written this exact value into the binding, so the
        // comparison below fails and nothing is reset — resetting here
        // would drop the caret and any IME marked text. Only genuinely
        // external changes (e.g. inserting a definition annotation)
        // reach the assignment.
        if !textView.attributedText.isEqual(to: attributedText) {
            context.coordinator.isApplyingExternalChange = true
            textView.attributedText = attributedText
            textView.selectedRange = clamp(selectedRange, in: textView)
            context.coordinator.isApplyingExternalChange = false
        } else if textView.selectedRange != selectedRange, !textView.isFirstResponder {
            // Selection changed externally while the keyboard is down;
            // never fight the text view over selection while it is first
            // responder and the text itself is unchanged.
            context.coordinator.isApplyingExternalChange = true
            textView.selectedRange = clamp(selectedRange, in: textView)
            context.coordinator.isApplyingExternalChange = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func clamp(_ range: NSRange, in textView: UITextView) -> NSRange {
        let length = textView.attributedText.length
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        var isApplyingExternalChange = false

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalChange else { return }
            parent.attributedText = textView.attributedText
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingExternalChange else { return }
            if parent.selectedRange != textView.selectedRange {
                parent.selectedRange = textView.selectedRange
            }
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0 else {
                return UIMenu(children: suggestedActions)
            }
            let define = UIAction(
                title: "Define",
                image: UIImage(systemName: "book")
            ) { [weak self] _ in
                self?.parent.onDefine()
            }
            let explain = UIAction(
                title: "Explain with AI",
                image: UIImage(systemName: "sparkles")
            ) { [weak self] _ in
                self?.parent.onExplain()
            }
            let addToVocabulary = UIAction(
                title: "Add to Vocabulary",
                image: UIImage(systemName: "character.book.closed")
            ) { [weak self] _ in
                self?.parent.onAddToVocabulary()
            }
            return UIMenu(children: [define, explain, addToVocabulary] + suggestedActions)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    struct PreviewHost: View {
        @State private var text = NSAttributedString(
            string: "Select a word to see the Define, Explain with AI, and Add to Vocabulary menu actions.",
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label
            ]
        )
        @State private var selection = NSRange(location: 0, length: 0)
        private let commands = RichTextCommands()

        var body: some View {
            RichTextEditor(
                attributedText: $text,
                selectedRange: $selection,
                commands: commands
            )
        }
    }
    return PreviewHost()
}
#endif
