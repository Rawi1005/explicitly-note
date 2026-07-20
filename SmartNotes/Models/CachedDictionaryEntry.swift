import Foundation
import SwiftData

/// A cached DictionaryAPI.dev response, stored as the JSON-encoded
/// `[DictionaryEntry]` array so the sheet can re-render it offline.
@Model
final class CachedDictionaryEntry {
    @Attribute(.unique) var normalizedWord: String
    var id: UUID
    var responseData: Data
    var fetchedAt: Date
    var lastAccessedAt: Date

    init(
        id: UUID = UUID(),
        normalizedWord: String,
        responseData: Data,
        fetchedAt: Date = .now,
        lastAccessedAt: Date = .now
    ) {
        self.id = id
        self.normalizedWord = normalizedWord
        self.responseData = responseData
        self.fetchedAt = fetchedAt
        self.lastAccessedAt = lastAccessedAt
    }
}
