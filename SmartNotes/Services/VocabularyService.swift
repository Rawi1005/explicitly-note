import Foundation
import SwiftData

/// Optional provenance and study metadata captured with a vocabulary word.
struct VocabularySaveDetails {
    var phonetic: String?
    var exampleSentence: String?
    var translation: String?
    var sourceNotebookID: UUID?
    var sourcePageID: UUID?
    var pageNumber: Int?
    var underlineColorHex: String?
    var listName: String?
}

/// Saving and deleting vocabulary words, with duplicate prevention
/// on the normalized form of the word.
@MainActor
final class VocabularyService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Saves a word to the vocabulary list. If the normalized word is
    /// already saved, returns the existing item with `isNew == false`
    /// instead of creating a duplicate.
    @discardableResult
    func saveWord(
        word: String,
        shortDefinition: String,
        partOfSpeech: String?,
        sourceNoteTitle: String?,
        details: VocabularySaveDetails = VocabularySaveDetails()
    ) throws -> (item: VocabularyItem, isNew: Bool) {
        let normalized = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let existing = fetchItem(normalizedWord: normalized) {
            return (existing, false)
        }

        let item = VocabularyItem(
            word: word.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedWord: normalized,
            shortDefinition: shortDefinition,
            partOfSpeech: partOfSpeech,
            sourceNoteTitle: sourceNoteTitle,
            phonetic: details.phonetic,
            exampleSentence: details.exampleSentence,
            translation: details.translation,
            sourceNotebookID: details.sourceNotebookID,
            sourcePageID: details.sourcePageID,
            pageNumber: details.pageNumber,
            underlineColorHex: details.underlineColorHex,
            listName: details.listName
        )
        modelContext.insert(item)
        try modelContext.save()
        return (item, true)
    }

    func isSaved(normalizedWord: String) -> Bool {
        fetchItem(normalizedWord: normalizedWord) != nil
    }

    func delete(_ item: VocabularyItem) throws {
        modelContext.delete(item)
        try modelContext.save()
    }

    private func fetchItem(normalizedWord: String) -> VocabularyItem? {
        var descriptor = FetchDescriptor<VocabularyItem>(
            predicate: #Predicate { $0.normalizedWord == normalizedWord }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
