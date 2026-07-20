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

    init(
        id: UUID = UUID(),
        word: String,
        normalizedWord: String,
        shortDefinition: String,
        partOfSpeech: String? = nil,
        sourceNoteTitle: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.word = word
        self.normalizedWord = normalizedWord
        self.shortDefinition = shortDefinition
        self.partOfSpeech = partOfSpeech
        self.sourceNoteTitle = sourceNoteTitle
        self.createdAt = createdAt
    }
}
