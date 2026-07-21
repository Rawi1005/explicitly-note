import Foundation
import SwiftData

/// A word the user saved from the definition sheet.
/// `normalizedWord` is unique so the same word is never saved twice.
@Model
final class VocabularyItem {
    @Attribute(.unique) var normalizedWord: String
    var id: UUID
    var word: String
    var shortDefinition: String
    var partOfSpeech: String?
    var sourceNoteTitle: String?
    var createdAt: Date
    // Newer optional fields (safe lightweight migration).
    var phonetic: String?
    var exampleSentence: String?
    var translation: String?
    var sourceNotebookID: UUID?
    var sourcePageID: UUID?
    var pageNumber: Int?
    var underlineColorHex: String?
    /// Custom study list (e.g. "SAT", "Biology"); nil = unfiled.
    var listName: String?

    init(
        id: UUID = UUID(),
        word: String,
        normalizedWord: String,
        shortDefinition: String,
        partOfSpeech: String? = nil,
        sourceNoteTitle: String? = nil,
        createdAt: Date = .now,
        phonetic: String? = nil,
        exampleSentence: String? = nil,
        translation: String? = nil,
        sourceNotebookID: UUID? = nil,
        sourcePageID: UUID? = nil,
        pageNumber: Int? = nil,
        underlineColorHex: String? = nil,
        listName: String? = nil
    ) {
        self.id = id
        self.word = word
        self.normalizedWord = normalizedWord
        self.shortDefinition = shortDefinition
        self.partOfSpeech = partOfSpeech
        self.sourceNoteTitle = sourceNoteTitle
        self.createdAt = createdAt
        self.phonetic = phonetic
        self.exampleSentence = exampleSentence
        self.translation = translation
        self.sourceNotebookID = sourceNotebookID
        self.sourcePageID = sourcePageID
        self.pageNumber = pageNumber
        self.underlineColorHex = underlineColorHex
        self.listName = listName
    }
}
