import Foundation
import SwiftData
import UIKit
import Observation

/// Sheet-presentation item for `AIExplanationSheet`.
struct AIExplanationRequest: Identifiable {
    let id = UUID()
    let selectedText: String
    let context: String
}

@MainActor
@Observable
final class NoteEditorViewModel {

    enum SaveStatus: Equatable {
        case idle
        case saving
        case saved(Date)
    }

    var title: String
    var attributedText: NSAttributedString
    var selectedRange = NSRange(location: 0, length: 0)
    var saveStatus: SaveStatus = .idle

    /// Non-nil values drive the Define / Explain sheets via `.sheet(item:)`.
    var definitionRequest: DefinitionLookupRequest?
    var aiExplanationRequest: AIExplanationRequest?

    /// Bridge for the formatting toolbar; wired to the UITextView by
    /// `RichTextEditor` when it creates the view.
    @ObservationIgnored let commands = RichTextCommands()

    @ObservationIgnored private let note: Note
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    init(note: Note, modelContext: ModelContext) {
        self.note = note
        self.modelContext = modelContext
        self.title = note.title
        self.attributedText = Self.loadAttributedText(from: note)
    }

    // MARK: - Loading

    private static func loadAttributedText(from note: Note) -> NSAttributedString {
        guard let data = note.contentData,
              let decoded = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.rtf],
                  documentAttributes: nil
              )
        else {
            return NSAttributedString(string: "", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label
            ])
        }
        return normalizingColors(of: decoded)
    }

    /// RTF flattens dynamic colors into fixed RGB, which would freeze text
    /// in whichever appearance it was saved under. The editor only ever
    /// writes two colors — `.label` for body text and `.secondaryLabel`
    /// for definition annotations — so remap each run back to a semantic
    /// color: translucent or mid-gray runs become secondaryLabel,
    /// everything else label. This keeps notes legible in dark mode.
    private static func normalizingColors(of source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            var semantic = UIColor.label
            if let color = value as? UIColor {
                var white: CGFloat = 0
                var alpha: CGFloat = 1
                if color.getWhite(&white, alpha: &alpha),
                   alpha < 0.95 || (0.2...0.8).contains(white) {
                    semantic = .secondaryLabel
                }
            }
            result.addAttribute(.foregroundColor, value: semantic, range: range)
        }
        return result
    }

    // MARK: - Saving

    /// Debounces saves so a burst of typing produces one write about a
    /// second after the last edit.
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves immediately; called when the editor disappears.
    func saveNow() {
        autosaveTask?.cancel()
        autosaveTask = nil
        save()
    }

    private func save() {
        // The note may have been deleted from the library while the
        // editor was still on screen (iPad split view).
        guard !note.isDeleted else { return }

        saveStatus = .saving
        let fullRange = NSRange(location: 0, length: attributedText.length)
        note.contentData = try? attributedText.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = trimmedTitle.isEmpty ? "Untitled Note" : trimmedTitle
        note.plainTextPreview = String(attributedText.string.prefix(200))
        note.updatedAt = .now
        try? modelContext.save()
        saveStatus = .saved(.now)
    }

    // MARK: - Selection

    var selectedText: String {
        let plain = attributedText.string as NSString
        let range = clamped(selectedRange, limit: plain.length)
        guard range.length > 0 else { return "" }
        return plain.substring(with: range)
    }

    var hasSelection: Bool {
        !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clamped(_ range: NSRange, limit: Int) -> NSRange {
        let location = min(max(0, range.location), limit)
        let length = min(max(0, range.length), limit - location)
        return NSRange(location: location, length: length)
    }

    // MARK: - Selected-word actions

    /// Raw selection is passed through unchanged; `WordNormalizer` runs
    /// inside the definition sheet so its validation errors surface there.
    func defineSelection() {
        guard hasSelection else { return }
        definitionRequest = DefinitionLookupRequest(
            rawSelection: selectedText,
            context: contextAroundSelection(),
            sourceNoteTitle: currentNoteTitle
        )
    }

    func explainSelection() {
        guard hasSelection else { return }
        aiExplanationRequest = AIExplanationRequest(
            selectedText: selectedText,
            context: contextAroundSelection()
        )
    }

    /// Routed through the Define flow on purpose: the definition sheet
    /// lets the user save the word with a real definition instead of
    /// silently storing a blank placeholder.
    func addSelectionToVocabulary() {
        defineSelection()
    }

    private var currentNoteTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? note.title : trimmed
    }

    /// The sentence containing the selection plus one neighboring
    /// sentence, extracted from plain text. Falls back to a fixed-size
    /// window around the selection when sentence enumeration finds
    /// nothing (e.g. text without sentence terminators).
    private func contextAroundSelection() -> String {
        let plain = attributedText.string
        let nsPlain = plain as NSString
        let nsRange = clamped(selectedRange, limit: nsPlain.length)
        guard let selection = Range(nsRange, in: plain) else { return "" }

        var sentences: [Range<String.Index>] = []
        plain.enumerateSubstrings(
            in: plain.startIndex..<plain.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            sentences.append(range)
        }

        guard let index = sentences.firstIndex(where: {
            $0.overlaps(selection) || $0.contains(selection.lowerBound)
        }) else {
            return windowFallback(around: nsRange, in: nsPlain)
        }

        var picked = [String(plain[sentences[index]])]
        if index + 1 < sentences.count {
            picked.append(String(plain[sentences[index + 1]]))
        } else if index > 0 {
            picked.insert(String(plain[sentences[index - 1]]), at: 0)
        }
        return picked
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func windowFallback(around range: NSRange, in plain: NSString) -> String {
        let start = max(0, range.location - 100)
        let end = min(plain.length, range.location + range.length + 100)
        guard end > start else { return "" }
        // Expand to composed character boundaries so the window never
        // splits an emoji or other multi-unit character.
        let window = plain.rangeOfComposedCharacterSequences(
            for: NSRange(location: start, length: end - start)
        )
        return plain.substring(with: window)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Insert definition into the note

    /// Inserts a preformatted definition on its own line immediately
    /// after the paragraph containing the current selection, styled as an
    /// annotation (footnote-size italic, secondary color, book prefix).
    func insertDefinition(_ definition: String) {
        let trimmed = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let plain = mutable.string as NSString
        let selection = clamped(selectedRange, limit: plain.length)
        let paragraph = plain.paragraphRange(for: selection)
        let insertLocation = paragraph.location + paragraph.length

        // paragraphRange includes the trailing newline when there is one;
        // only the final paragraph of the document lacks it.
        let endsWithNewline: Bool
        if paragraph.length > 0 {
            let lastCharacter = plain.substring(
                with: NSRange(location: insertLocation - 1, length: 1)
            )
            endsWithNewline = lastCharacter.rangeOfCharacter(from: .newlines) != nil
        } else {
            endsWithNewline = false
        }

        let annotation = "📖 " + trimmed
        let insertText = endsWithNewline ? annotation + "\n" : "\n" + annotation
        mutable.insert(
            NSAttributedString(string: insertText, attributes: Self.annotationAttributes),
            at: insertLocation
        )
        attributedText = mutable

        // Collapse the caret to the end of the annotation so the old
        // selection isn't left highlighted over stale offsets.
        let annotationLength = (annotation as NSString).length
        let caret = endsWithNewline
            ? insertLocation + annotationLength
            : insertLocation + 1 + annotationLength
        selectedRange = NSRange(location: min(caret, mutable.length), length: 0)

        scheduleAutosave()
    }

    private static var annotationAttributes: [NSAttributedString.Key: Any] {
        let base = UIFont.preferredFont(forTextStyle: .footnote)
        let font: UIFont
        if let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: 0)
        } else {
            font = base
        }
        return [.font: font, .foregroundColor: UIColor.secondaryLabel]
    }
}
